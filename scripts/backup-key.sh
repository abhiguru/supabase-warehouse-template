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
#   backup_authenticate DIR ALLOW     verify checksums and signature; ALLOW=true accepts an unsigned backup
#   backup_sign_archive FILE KEY      write FILE.hmac over FILE.sha256
#   backup_check_archive FILE KEY     verify FILE.hmac
#   backup_encrypt KEY / backup_decrypt KEY   stdin to stdout, AES-256-CTR
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

# Checks SHA256SUMS, then the signature made with the backup key. A signed
# backup must also contain exactly the files its SHA256SUMS lists. Nothing in
# the backup is parsed, loaded or executed by the callers before this passes.
backup_authenticate() {
  local dir="$1" allow="${2:-false}" keyfile recorded expected listed present
  BACKUP_SIGNED=false
  [[ -f "$dir/SHA256SUMS" && ! -L "$dir/SHA256SUMS" ]] || { echo 'Incomplete backup: missing SHA256SUMS' >&2; return 1; }
  (cd "$dir" && sha256sum -c --quiet SHA256SUMS) || { echo 'Refusing: the backup does not match its SHA256SUMS.' >&2; return 1; }
  if [[ ! -e "$dir/$BACKUP_SIGNATURE_FILE" && ! -L "$dir/$BACKUP_SIGNATURE_FILE" ]]; then
    if [[ "$allow" == true ]]; then backup_unsigned_warning "this backup carries no signature ($BACKUP_SIGNATURE_FILE)."; return 0; fi
    cat >&2 <<MSG
Refusing: this backup carries no signature ($BACKUP_SIGNATURE_FILE).
Backups written before format warehouse-backup-v5 are unsigned. If this one never left your
custody, repeat the command with --allow-unsigned; otherwise use a signed backup.
MSG
    return 1
  fi
  [[ -f "$dir/$BACKUP_SIGNATURE_FILE" && ! -L "$dir/$BACKUP_SIGNATURE_FILE" ]] || { echo "Refusing: $BACKUP_SIGNATURE_FILE is not a regular file." >&2; return 1; }
  if ! keyfile="$(backup_key_path)" || [[ ! -e "$keyfile" ]]; then
    if [[ "$allow" == true ]]; then backup_unsigned_warning 'no backup key is available, so the signature of this backup was NOT checked.'; return 0; fi
    cat >&2 <<MSG
Refusing: no backup key is available to check the signature of this backup.
Set WAREHOUSE_STATE_DIR to the installation that wrote it, or WAREHOUSE_BACKUP_KEY_FILE to your copy of its
config/backup.key. Without the key the backup can only be used with --allow-unsigned.
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
  present="$(cd "$dir" && find . -type f ! -path ./SHA256SUMS ! -path "./$BACKUP_SIGNATURE_FILE" -printf '%P\n' | LC_ALL=C sort)"
  if [[ "$listed" != "$present" || "$(wc -l < "$dir/SHA256SUMS")" != "$(grep -c . <<<"$listed")" ]]; then
    echo 'Refusing: the files in the backup are not exactly the files its signed SHA256SUMS lists.' >&2; return 1
  fi
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
