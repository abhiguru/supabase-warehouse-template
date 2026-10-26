#!/usr/bin/env bash
# Backup key helpers. Source this file from an operator command; do not run it.
#
# The backup key is 32 random bytes (64 hexadecimal characters) in
# <state>/config/backup.key, mode 0600. It is never copied into a backup: the
# operator keeps a copy off the machine, because a lost-host restore needs it.
#   backup_key_path                   key file in use (WAREHOUSE_BACKUP_KEY_FILE, else the state's key)
#   backup_key_ensure STATE           create the state's key when it is missing
#   backup_key_load FILE              read and validate a key into BACKUP_KEY
#   backup_hmac KEY LABEL < data      HMAC-SHA256 as hexadecimal
#   backup_sign_dir DIR KEY           write SHA256SUMS.hmac for a backup directory
#   backup_authenticate DIR ALLOW     verify signature, then checksums; ALLOW=true accepts a backup only when
#                                     the backup key is lost; never a v5 or v6 backup whose signature file is
#                                     missing while the key is available. A backup whose signed list names
#                                     storage.manifest (format v6) also has its storage/ tree checked against that
#                                     manifest; BACKUP_TREE=skip checks the chain only (signature, list, manifest)
#   backup_sign_archive FILE KEY      write FILE.hmac over FILE.sha256
#   backup_check_archive FILE KEY     verify FILE.hmac
#   backup_encrypt KEY / backup_decrypt KEY   stdin to stdout, AES-256-CTR
#   backup_key_fingerprint KEY        first 16 hexadecimal characters of an HMAC of the key (it does not reveal the key)
#   backup_escrow_ok STATE            0 when <state>/config/backup-key.escrow records that the operator confirmed a copy
#                                     of the key now in <state>/config/backup.key (scripts/backup-key-escrow.sh)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo 'scripts/backup-key.sh is a sourced helper, not a command.' >&2
  exit 1
fi

BACKUP_KEY=''
BACKUP_SIGNED=false
BACKUP_SIGNATURE_FILE=SHA256SUMS.hmac

backup_key_path() {
  if [[ -n "${WAREHOUSE_BACKUP_KEY_FILE:-}" ]]; then printf '%s\n' "$WAREHOUSE_BACKUP_KEY_FILE"; return 0; fi
  [[ "${WAREHOUSE_STATE_DIR:-}" == /* ]] || return 1
  printf '%s\n' "$WAREHOUSE_STATE_DIR/config/backup.key"
}

backup_key_load() {
  local file="$1" key=''
  BACKUP_KEY=''
  if [[ ! -f "$file" || -L "$file" ]]; then echo "Backup key file not found: $file" >&2; return 1; fi
  IFS= read -r key < "$file" || true
  key="${key%$'\r'}"
  if [[ ! "$key" =~ ^[0-9a-f]{64}$ ]]; then echo "$file does not hold a backup key (64 hexadecimal characters on one line)." >&2; return 1; fi
  BACKUP_KEY="$key"
}

# Installations made before signed backups have no key; the first backup creates it.
backup_key_ensure() {
  local state="$1" file tmp
  file="$state/config/backup.key"
  if [[ ! -e "$file" && ! -L "$file" ]]; then
    tmp="$(umask 077; mktemp "$state/config/.backup.key.XXXXXX")"
    openssl rand -hex 32 > "$tmp"
    chmod 600 "$tmp"
    mv -n -- "$tmp" "$file"
    rm -f -- "$tmp"
    cat >&2 <<MSG
Created the backup key $file.
Backups are signed with it, and a lost-host restore refuses a backup without it.
Copy this file to a safe place away from this machine and away from the backup drive.
MSG
  fi
  if [[ ! -f "$file" || -L "$file" || "$(stat -c %u -- "$file")" != "$(id -u)" || "$(stat -c %a -- "$file")" != 600 ]]; then
    echo "The backup key $file must be a regular file owned by this user with mode 0600." >&2; return 1
  fi
}

# HMAC-SHA256 of "LABEL\n" followed by standard input. The key only passes
# through shell builtins, so it never appears in a process argument list.
backup_hmac() {
  local key="$1" label="$2" i byte piece ipad='' opad='' inner outer=''
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] || { echo 'backup_hmac needs a 64-character hexadecimal key.' >&2; return 1; }
  for ((i = 0; i < 64; i++)); do
    byte=0
    if ((i < 32)); then byte=$((16#${key:i * 2:2})); fi
    printf -v piece '\\x%02x' $((byte ^ 0x36)); ipad+="$piece"
    printf -v piece '\\x%02x' $((byte ^ 0x5c)); opad+="$piece"
  done
  inner="$({ printf '%b' "$ipad"; printf '%s\n' "$label"; cat; } | sha256sum | cut -d' ' -f1)"
  [[ "$inner" =~ ^[0-9a-f]{64}$ ]] || return 1
  for ((i = 0; i < 64; i += 2)); do outer+="\\x${inner:i:2}"; done
  { printf '%b' "$opad"; printf '%b' "$outer"; } | sha256sum | cut -d' ' -f1
}

backup_sign_dir() {
  local dir="$1" key="$2" mac
  mac="$(backup_hmac "$key" warehouse-backup-manifest-v1 < "$dir/SHA256SUMS")" || return 1
  printf 'warehouse-backup-hmac-v1 %s\n' "$mac" > "$dir/$BACKUP_SIGNATURE_FILE"
  chmod 600 "$dir/$BACKUP_SIGNATURE_FILE"
}

backup_unsigned_warning() {
  cat >&2 <<MSG
************************************************************************
WARNING: $1
--allow-unsigned was given, so the backup is used WITHOUT proof that it was
written by this installation. Anyone who could write to the backup medium
could have changed the database dump and the configuration in it.
Continue only if the medium never left your custody.
************************************************************************
MSG
}

# Runs SHA256SUMS over a backup directory. The list is made to name only files
# inside the backup first: `sha256sum -c` opens whatever path a line gives it.
# A backup whose list names storage.manifest (format v6, the object storage as a tree) also has that tree
# checked against the manifest, unless BACKUP_TREE=skip (the chain only: signature, list, manifest).
backup_checksums() {
  local dir="$1"
  if grep -Evq '^[0-9a-f]{64}  [^/]' "$dir/SHA256SUMS" || grep -Eq '^[0-9a-f]{64}  (.*/)?\.\.(/|$)' "$dir/SHA256SUMS"; then
    echo 'Refusing: SHA256SUMS names a path outside the backup, or has a line that is not a checksum.' >&2; return 1
  fi
  if [[ -n "$(cd "$dir" && find . -mindepth 1 ! -type f ! -type d -print -quit)" ]]; then
    echo 'Refusing: the backup contains a link or special file.' >&2; return 1
  fi
  (cd "$dir" && sha256sum -c --quiet SHA256SUMS) || { echo 'Refusing: the backup does not match its SHA256SUMS.' >&2; return 1; }
  if grep -Eq '^[0-9a-f]{64}  storage\.manifest$' "$dir/SHA256SUMS" && [[ "${BACKUP_TREE:-check}" != skip ]]; then
    backup_check_tree "$dir" || return 1
  fi
}

# The storage/ tree of a v6 backup against storage.manifest (a line "<sha256>  <path relative to storage/>" per file,
# which the signature already vouches for through SHA256SUMS). The manifest is made to name only paths inside the
# tree first, as for SHA256SUMS; the tree must hold exactly the files it names (an extra or a missing file is a
# fault, the same rule as for the top-level files); then every file is hashed.
backup_check_tree() {
  local dir="$1" listed present
  if [[ ! -d "$dir/storage" || -L "$dir/storage" || ! -f "$dir/storage.manifest" || -L "$dir/storage.manifest" ]]; then
    echo 'Refusing: the backup has no storage/ tree or no storage.manifest.' >&2; return 1
  fi
  if grep -Evq '^[0-9a-f]{64}  [^/]' "$dir/storage.manifest" || grep -Eq '^[0-9a-f]{64}  (.*/)?\.\.(/|$)' "$dir/storage.manifest"; then
    echo 'Refusing: storage.manifest names a path outside the storage tree, or has a line that is not a checksum.' >&2; return 1
  fi
  listed="$(sed -n 's/^[0-9a-f]\{64\}  //p' "$dir/storage.manifest" | LC_ALL=C sort)"
  present="$(cd "$dir/storage" && find . -type f -printf '%P\n' | LC_ALL=C sort)"
  if [[ "$listed" != "$present" || "$(wc -l < "$dir/storage.manifest")" != "$(grep -c . <<<"$listed" || true)" ]]; then
    echo 'Refusing: the files in the backup storage/ tree are not exactly the files its signed storage.manifest lists.' >&2; return 1
  fi
  # An empty manifest (a storage tree with no files) has nothing to hash; sha256sum -c refuses an empty list.
  if [[ -s "$dir/storage.manifest" ]]; then
    (cd "$dir/storage" && sha256sum -c --quiet ../storage.manifest) || { echo 'Refusing: a file of the backup storage/ tree does not match storage.manifest.' >&2; return 1; }
  fi
}

# Checks the signature made with the backup key over SHA256SUMS, then that the
# backup contains exactly the files that list names, then the checksums. The
# signature comes first: SHA256SUMS is not used, and nothing in the backup is
# parsed, loaded or executed by the callers, before it passes. Only a backup
# accepted without a signature (ALLOW=true) has its checksums run unauthenticated.
# ALLOW=true is for a lost key (the signature cannot be checked). It does not accept a v5 or v6 backup whose signature
# file is gone while the key is available: that signature was taken away.
backup_authenticate() {
  local dir="$1" allow="${2:-false}" keyfile recorded expected listed present
  BACKUP_SIGNED=false
  [[ -f "$dir/SHA256SUMS" && ! -L "$dir/SHA256SUMS" ]] || { echo 'Incomplete backup: missing SHA256SUMS' >&2; return 1; }
  if [[ ! -e "$dir/$BACKUP_SIGNATURE_FILE" && ! -L "$dir/$BACKUP_SIGNATURE_FILE" ]]; then
    # Before any checksum is run: the answer does not depend on the contents, and a large backup takes long to hash.
    if keyfile="$(backup_key_path)" && [[ -e "$keyfile" ]]; then
      cat >&2 <<MSG
Refusing: this backup carries no signature ($BACKUP_SIGNATURE_FILE), and a v5 or v6 backup must be signed; its signature file was removed.
--allow-unsigned is only for when the backup key is lost.
The backup key $keyfile is available here. Use another copy of this backup.
MSG
      return 1
    fi
    if [[ "$allow" == true ]]; then
      backup_checksums "$dir" || return 1
      local note="this backup carries no signature ($BACKUP_SIGNATURE_FILE). It is a signed format and the backup key was missing, so the signature could not be required."
      backup_unsigned_warning "$note"; return 0
    fi
    cat >&2 <<MSG
Refusing: this backup carries no signature ($BACKUP_SIGNATURE_FILE).
Every accepted backup is signed, so this one lost its signature file. If it never left your
custody and the backup key is lost, repeat the command with --allow-unsigned; otherwise use a signed backup.
(--allow-unsigned is only for when the backup key is lost.)
MSG
    return 1
  fi
  [[ -f "$dir/$BACKUP_SIGNATURE_FILE" && ! -L "$dir/$BACKUP_SIGNATURE_FILE" ]] || { echo "Refusing: $BACKUP_SIGNATURE_FILE is not a regular file." >&2; return 1; }
  if ! keyfile="$(backup_key_path)" || [[ ! -e "$keyfile" ]]; then
    if [[ "$allow" == true ]]; then
      backup_checksums "$dir" || return 1
      backup_unsigned_warning 'no backup key is available, so the signature of this backup was NOT checked.'; return 0
    fi
    cat >&2 <<MSG
Refusing: no backup key is available to check the signature of this backup.
Set WAREHOUSE_STATE_DIR to the installation that wrote it, or WAREHOUSE_BACKUP_KEY_FILE to your copy of its
config/backup.key. Without the key (lost) the backup can only be used with --allow-unsigned.
MSG
    return 1
  fi
  backup_key_load "$keyfile" || return 1
  IFS= read -r recorded < "$dir/$BACKUP_SIGNATURE_FILE" || true
  expected="warehouse-backup-hmac-v1 $(backup_hmac "$BACKUP_KEY" warehouse-backup-manifest-v1 < "$dir/SHA256SUMS")"
  if [[ "$recorded" != "$expected" ]]; then
    cat >&2 <<MSG
Refusing: the signature of this backup does not match the backup key $keyfile.
Either the backup was changed after it was written, or it was signed with a different key
(another installation, or a key that was replaced since). Nothing was restored.
MSG
    return 1
  fi
  if [[ -n "$(cd "$dir" && find . -mindepth 1 ! -type f ! -type d -print -quit)" ]]; then
    echo 'Refusing: the backup contains a link or special file.' >&2; return 1
  fi
  listed="$(sed -n 's/^[0-9a-f]\{64\}  //p' "$dir/SHA256SUMS" | LC_ALL=C sort)"
  # A v6 backup (the list names storage.manifest) keeps the object storage as a storage/ tree: the files in it are
  # covered by the manifest, not by this list, so the comparison leaves ./storage/ out.
  if grep -Eq '^[0-9a-f]{64}  storage\.manifest$' "$dir/SHA256SUMS"; then
    present="$(cd "$dir" && find . -type f ! -path ./SHA256SUMS ! -path "./$BACKUP_SIGNATURE_FILE" ! -path './storage/*' -printf '%P\n' | LC_ALL=C sort)"
  else
    present="$(cd "$dir" && find . -type f ! -path ./SHA256SUMS ! -path "./$BACKUP_SIGNATURE_FILE" -printf '%P\n' | LC_ALL=C sort)"
  fi
  if [[ "$listed" != "$present" || "$(wc -l < "$dir/SHA256SUMS")" != "$(grep -c . <<<"$listed")" ]]; then
    echo 'Refusing: the files in the backup are not exactly the files its signed SHA256SUMS lists.' >&2; return 1
  fi
  backup_checksums "$dir" || return 1
  BACKUP_SIGNED=true
}

# A backup archive on a drive is covered by signing its one-line .sha256 file.
backup_sign_archive() {
  local file="$1" key="$2" mac
  mac="$(backup_hmac "$key" warehouse-backup-archive-v1 < "$file.sha256")" || return 1
  printf 'warehouse-backup-hmac-v1 %s\n' "$mac" > "$file.hmac"
}
backup_check_archive() {
  local file="$1" key="$2" recorded=''
  [[ -f "$file.hmac" && ! -L "$file.hmac" && -f "$file.sha256" && ! -L "$file.sha256" ]] || return 1
  IFS= read -r recorded < "$file.hmac" || true
  [[ "$recorded" == "warehouse-backup-hmac-v1 $(backup_hmac "$key" warehouse-backup-archive-v1 < "$file.sha256")" ]]
}

# AES-256-CTR with a passphrase derived from the backup key; integrity comes from
# backup_sign_archive over the ciphertext checksum (encrypt, then authenticate).
backup_cipher() {
  local direction="$1" key="$2" pass
  pass="$(backup_hmac "$key" warehouse-backup-encryption-v1 < /dev/null)" || return 1
  openssl enc "$direction" -aes-256-ctr -pbkdf2 -iter 100000 -md sha256 -salt -pass fd:3 3<<<"$pass"
}
backup_encrypt() { backup_cipher -e "$1"; }
backup_decrypt() { backup_cipher -d "$1"; }

# The key escrow record: the operator has seen the key once and typed back its last characters, so a copy exists away from
# this machine and the drive. An encrypted archive cannot be opened without the key, so a USB drive is not enrolled and an
# encrypted archive is not written until the record matches the key now in use (a replaced key needs a new confirmation).
# scripts/backup-key-escrow.sh writes it; the fingerprint is not the key and cannot be turned back into it.
BACKUP_ESCROW_HEADER=warehouse-backup-key-escrow-v1
backup_key_fingerprint() {
  local mac
  mac="$(backup_hmac "$1" warehouse-backup-key-fingerprint-v1 < /dev/null)" || return 1
  printf '%s\n' "${mac:0:16}"
}
# backup_escrow_check RECORD KEY: 0 when the record is well formed and its fingerprint is that of KEY; otherwise 1 with the
# reason in BACKUP_ESCROW_PROBLEM.
BACKUP_ESCROW_PROBLEM=''
backup_escrow_check() {
  local record="$1" key="$2" header recorded expected
  BACKUP_ESCROW_PROBLEM=''
  if [[ ! -f "$record" || -L "$record" ]]; then BACKUP_ESCROW_PROBLEM="there is no key escrow record"; return 1; fi
  IFS= read -r header < "$record" || true
  if [[ "$header" != "$BACKUP_ESCROW_HEADER" ]]; then BACKUP_ESCROW_PROBLEM="the key escrow record is not valid"; return 1; fi
  recorded="$(sed -n 's/^key_fingerprint=//p' "$record" | head -n 1)"
  if [[ ! "$recorded" =~ ^[0-9a-f]{16}$ ]]; then BACKUP_ESCROW_PROBLEM="the key escrow record has no key fingerprint"; return 1; fi
  expected="$(backup_key_fingerprint "$key")" || { BACKUP_ESCROW_PROBLEM='the backup key is not usable'; return 1; }
  if [[ "$recorded" != "$expected" ]]; then BACKUP_ESCROW_PROBLEM="the key escrow record is for another backup key (the key was replaced since the copy was confirmed)"; return 1; fi
}
backup_escrow_ok() {
  local state="$1" key
  [[ -f "$state/config/backup.key" && ! -L "$state/config/backup.key" ]] || { BACKUP_ESCROW_PROBLEM="the backup key $state/config/backup.key does not exist"; return 1; }
  IFS= read -r key < "$state/config/backup.key" || true
  key="${key%$'\r'}"
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] || { BACKUP_ESCROW_PROBLEM="$state/config/backup.key does not hold a backup key"; return 1; }
  backup_escrow_check "$state/config/backup-key.escrow" "$key"
}
