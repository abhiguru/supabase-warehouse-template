#!/usr/bin/env bash
# The USB archive of one backup: a single tar of the backup folder, self-contained and plain on the outside (no gzip: the
# photos are already compressed), optionally passed through the backup key's AES. Source this file; do not run it.
# Needs scripts/backup-key.sh sourced first (backup_encrypt, backup_decrypt) and BACKUP_KEY set for an encrypted archive.
#   backup_archive_write DIR OUT [encrypt]    archive the backup DIR to the file OUT (written as it is made) and print the SHA-256
#                                             of the bytes written; returns non-zero if any stage failed. A second argument
#                                             `encrypt` passes the stream through backup_encrypt.
#   backup_archive_extract ARCHIVE DEST [--no-tree]
#                                             unpack ARCHIVE (.tar or .tar.enc) into the existing folder DEST; --no-tree leaves
#                                             the storage/ tree out, so the photos of a v6 backup are never written (what the
#                                             restore check of the drive needs: the small files, which the signature and
#                                             storage.manifest vouch for)
#   backup_archive_small_bytes ARCHIVE        the bytes of the members that come before the storage/ tree: the room that an
#                                             extraction with --no-tree needs (reads only the start of the archive)
# The members are the files SHA256SUMS lists, the small ones first, then storage.manifest, then the storage/ tree last
# (or, for a v5 backup, storage.tar.gz last). Files that earlier backups share as hard links are archived as ordinary files
# (--hard-dereference): an archive holds everything it needs, and nothing on the drive depends on another archive. Extended
# attributes (the content type and cache control of each stored file) are kept in pax headers, so an exFAT drive, which has
# none, still carries them.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo 'scripts/backup-archive.sh is a sourced helper, not a command.' >&2
  exit 1
fi

backup_archive_write() {
  local dir="${1%/}" out="${2:-}" encrypt="${3:-}" parent name path dirpath tree
  local -a listed members=() dirs=() status
  local -A seen=()
  [[ -n "$dir" && -d "$dir" && -n "$out" ]] || { echo 'backup_archive_write needs the backup folder and the output file.' >&2; return 1; }
  [[ -z "$encrypt" || "$encrypt" == encrypt ]] || { echo 'backup_archive_write: the third argument is `encrypt` or nothing.' >&2; return 1; }
  parent="$(dirname -- "$dir")"; name="$(basename -- "$dir")"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "backup_archive_write: not a usable backup folder name: $name" >&2; return 1; }
  [[ -f "$dir/SHA256SUMS" && ! -L "$dir/SHA256SUMS" ]] || { echo "backup_archive_write: $dir has no SHA256SUMS." >&2; return 1; }
  mapfile -t listed < <(sed -n 's/^[0-9a-f]\{64\}  //p' "$dir/SHA256SUMS")
  ((${#listed[@]})) || { echo "backup_archive_write: $dir/SHA256SUMS lists no file." >&2; return 1; }
  members+=("$name")
  # Folders inside the backup (tunnel/) first, then the signed list and its signature, then every other file the list names,
  # the manifest after them and the tree last.
  for path in "${listed[@]}"; do
    [[ "$path" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ && "$path" != *..* && "$path" != */ ]] || { echo "backup_archive_write: SHA256SUMS names an unusable path: $path" >&2; return 1; }
    if [[ "$path" == */* ]]; then
      dirpath="${path%/*}"
      if [[ -z "${seen[$dirpath]:-}" ]]; then seen[$dirpath]=1; dirs+=("$name/$dirpath"); fi
    fi
  done
  members+=("${dirs[@]}" "$name/SHA256SUMS")
  [[ ! -e "$dir/SHA256SUMS.hmac" ]] || members+=("$name/SHA256SUMS.hmac")
  for path in "${listed[@]}"; do
    [[ "$path" == storage.manifest || "$path" == storage.tar.gz ]] || members+=("$name/$path")
  done
  tree=false
  for path in "${listed[@]}"; do [[ "$path" != storage.manifest ]] || tree=true; done
  if [[ "$tree" == true ]]; then
    [[ -d "$dir/storage" && ! -L "$dir/storage" ]] || { echo "backup_archive_write: $dir lists storage.manifest but has no storage/ tree." >&2; return 1; }
    members+=("$name/storage.manifest" --recursion "$name/storage")
  else
    for path in "${listed[@]}"; do [[ "$path" != storage.tar.gz ]] || members+=("$name/storage.tar.gz"); done
  fi
  tar --xattrs --xattrs-include='user.*' --format=posix --hard-dereference --no-recursion -C "$parent" -cf - "${members[@]}" |
    { if [[ -n "$encrypt" ]]; then backup_encrypt "$BACKUP_KEY"; else cat; fi; } |
    tee -- "$out" | sha256sum | cut -d' ' -f1
  status=("${PIPESTATUS[@]}")
  ((status[0] == 0 && status[1] == 0 && status[2] == 0 && status[3] == 0 && status[4] == 0)) || return 1
}

# The folder name inside an archive is the archive's own name: warehouse-<utc>.tar or .tar.enc.
backup_archive_name() { local base; base="$(basename -- "$1")"; base="${base%.enc}"; printf '%s\n' "${base%.tar}"; }

# The archive as a plain tar stream on standard output.
backup_archive_stream() {
  if [[ "$1" == *.enc ]]; then backup_decrypt "$BACKUP_KEY" < "$1"; else cat -- "$1"; fi
}

backup_archive_extract() {
  local archive="$1" dest="$2" mode="${3:-}" name
  local -a exclude=()
  [[ -f "$archive" && -d "$dest" ]] || { echo 'backup_archive_extract needs an archive and an existing folder.' >&2; return 1; }
  [[ -z "$mode" || "$mode" == --no-tree ]] || { echo 'backup_archive_extract: the third argument is --no-tree or nothing.' >&2; return 1; }
  name="$(backup_archive_name "$archive")"
  [[ "$mode" != --no-tree ]] || exclude=("--exclude=$name/storage")
  # -p keeps the modes of the stored files against the umask of the caller (restore.sh copies them on); the owner is the caller's.
  if [[ "$archive" == *.enc ]]; then
    backup_decrypt "$BACKUP_KEY" < "$archive" | tar --no-same-owner -p --xattrs --xattrs-include='user.*' "${exclude[@]}" -C "$dest" -xf -
  else
    tar --no-same-owner -p --xattrs --xattrs-include='user.*' "${exclude[@]}" -C "$dest" -xf "$archive"
  fi
}

backup_archive_small_bytes() {
  local archive="$1" name bytes
  name="$(backup_archive_name "$archive")"
  # tar lists the members in archive order; the tree comes last, so the listing stops at its first member and the rest of the
  # archive is never read (the broken pipe that ends the stream is expected).
  bytes="$({ backup_archive_stream "$archive" | tar -tvf -; } 2>/dev/null | awk -v tree="$name/storage/" '
    { path = $0; sub(/^[^ ]+ +[^ ]+ +[0-9]+ +[0-9-]+ +[0-9:]+ /, "", path) }
    index(path, tree) == 1 { exit }
    substr($1, 1, 1) == "-" { total += $3 }
    END { print total + 0 }' || true)"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$bytes"
}
