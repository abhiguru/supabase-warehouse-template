#!/usr/bin/env bash
# Package a v4 core backup and separately held credentials for off-host custody.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if (( $# < 4 )); then
  echo 'Usage: export-recovery-backup.sh --plain BACKUP_DIR RECOVERY_SECRETS_DIR OUTPUT_TAR' >&2
  echo '   or: export-recovery-backup.sh --gpg BACKUP_DIR RECOVERY_SECRETS_DIR OUTPUT_GPG_FILE RECIPIENT_FINGERPRINT' >&2
  exit 2
fi
mode="$1"
case "$mode" in
  --plain) (( $# == 4 )) || exit 2 ;;
  --gpg) (( $# == 5 )) || exit 2 ;;
  *) echo 'Select --plain or --gpg.' >&2; exit 2 ;;
esac
backup="${2%/}"
secrets="${3%/}"
output="$4"
if [[ "$mode" == --gpg ]]; then
  fingerprint="${5^^}"
  [[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] || { echo 'Use the verified full 40-character GPG primary-key fingerprint.' >&2; exit 2; }
fi

for dir in "$backup" "$secrets"; do
  [[ "$dir" == /* && -d "$dir" && ! -L "$dir" ]] || { echo 'Input must be an existing absolute directory without a symlink.' >&2; exit 1; }
  real="$(realpath -e "$dir")"
  [[ "$real" == "$(realpath -ms "$dir")" && "$real" != "$ROOT" && "$real" != "$ROOT"/* ]] || {
    echo 'Input must be outside the checkout and contain no symlinked path component.' >&2; exit 1;
  }
  [[ "$(stat -c %u "$dir")" == "$(id -u)" && "$(stat -c %a "$dir")" == 700 ]] || {
    echo 'Input directory must be owned by this user and mode 0700.' >&2; exit 1;
  }
  while IFS= read -r -d '' entry; do
    [[ ! -L "$entry" && "$(stat -c %u "$entry")" == "$(id -u)" ]] || { echo 'Input contains a symlink or a file owned by another user.' >&2; exit 1; }
    if [[ -d "$entry" ]]; then
      [[ "$(stat -c %a "$entry")" == 700 ]] || { echo 'Input directory is not mode 0700.' >&2; exit 1; }
    elif [[ -f "$entry" ]]; then
      [[ "$(stat -c %a "$entry")" == 600 ]] || { echo 'Input file is not mode 0600.' >&2; exit 1; }
    else
      echo 'Input contains a non-regular file.' >&2; exit 1
    fi
  done < <(find -P "$dir" -mindepth 1 -print0)
done
[[ "$(basename "$backup")" != "$(basename "$secrets")" ]] || { echo 'Backup and recovery-secret directories need distinct names.' >&2; exit 1; }
[[ -n "$(find -P "$secrets" -type f -print -quit)" ]] || { echo 'Recovery credential directory is empty.' >&2; exit 1; }
[[ -f "$backup/metadata.txt" && ! -L "$backup/metadata.txt" ]] || { echo 'Incomplete backup: missing metadata.txt' >&2; exit 1; }
[[ "$(sed -n 's/^format=//p' "$backup/metadata.txt")" == warehouse-backup-v4 ]] || {
  echo 'A v4 backup with cluster globals is required.' >&2; exit 1
}
for name in database.dump storage.tar.gz integrity.txt metadata.txt compose.env instance.json roles.txt globals.sql SHA256SUMS; do
  [[ -f "$backup/$name" && ! -L "$backup/$name" ]] || { echo "Incomplete backup: missing $name" >&2; exit 1; }
done
[[ "$(find -P "$backup" -mindepth 1 -maxdepth 1 -type f | wc -l)" == 9 &&
   "$(find -P "$backup" -mindepth 1 -maxdepth 1 | wc -l)" == 9 ]] || {
  echo 'Backup directory has unexpected entries.' >&2; exit 1
}
(cd "$backup" && sha256sum --status -c SHA256SUMS) || { echo 'Backup checksum failed.' >&2; exit 1; }
if [[ "$mode" == --gpg ]]; then
  gpg --batch --with-colons --fingerprint "$fingerprint" 2>/dev/null |
    awk -F: '$1 == "fpr" {print toupper($10)}' | grep -Fqx "$fingerprint" || {
    echo 'Recipient fingerprint is not present in the local GPG keyring.' >&2; exit 1
  }
fi

[[ "$output" == /* && ! -e "$output" && ! -L "$output" ]] || { echo 'Output must be a new absolute file.' >&2; exit 1; }
parent="$(dirname "$output")"
[[ -d "$parent" && ! -L "$parent" && "$(realpath -e "$parent")" == "$(realpath -ms "$parent")" ]] || {
  echo 'Output parent must exist and contain no symlinked path component.' >&2; exit 1
}
[[ "$(realpath -e "$parent")" != "$ROOT" && "$(realpath -e "$parent")" != "$ROOT"/* ]] || {
  echo 'Recovery export must stay outside the checkout.' >&2; exit 1
}
if [[ "$mode" == --plain ]]; then
  [[ "$(stat -c %u "$parent")" == "$(id -u)" && "$(stat -c %a "$parent")" == 700 ]] || {
    echo 'Unencrypted output parent must be owned by this user and mode 0700.' >&2; exit 1
  }
fi
stage="$(mktemp "$parent/.warehouse-export.XXXXXXXX")"
trap 'rm -f "$stage"' EXIT
if [[ "$mode" == --gpg ]]; then
  tar -C "$(dirname "$backup")" -cf - "$(basename "$backup")" \
    -C "$(dirname "$secrets")" "$(basename "$secrets")" |
    gpg --batch --no-tty --yes --trust-model always --recipient "$fingerprint" \
      --encrypt --output "$stage"
else
  [[ "$(stat -c %a "$stage")" == 600 ]] || { echo 'Unencrypted output file must be mode 0600.' >&2; exit 1; }
  tar -C "$(dirname "$backup")" -cf "$stage" "$(basename "$backup")" \
    -C "$(dirname "$secrets")" "$(basename "$secrets")"
fi
[[ -s "$stage" ]] || { echo 'Recovery export is empty.' >&2; exit 1; }
# Rename within the destination filesystem so removable filesystems without
# hard-link support work too. An existing output must never be overwritten.
mv -n "$stage" "$output"
[[ ! -e "$stage" ]] || { echo 'Output was created concurrently; refusing to overwrite it.' >&2; exit 1; }
trap - EXIT
if [[ "$mode" == --plain ]]; then
  echo "UNENCRYPTED recovery backup (contains live credentials): $output"
else
  echo "Encrypted recovery backup: $output"
fi
sha256sum "$output"
