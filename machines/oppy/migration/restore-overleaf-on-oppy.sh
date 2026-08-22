#!/usr/bin/env bash
# shellcheck disable=SC2016 # MongoDB JavaScript is intentionally single-quoted.
set -Eeuo pipefail
umask 077

if (( EUID != 0 )); then
  echo "Run this restore on Oppy with sudo." >&2
  exit 1
fi
if [[ $(hostname) != oppy ]]; then
  echo "Refusing to restore on $(hostname); this script is for Oppy." >&2
  exit 1
fi
if (($# != 1)); then
  echo "Usage: sudo $0 /absolute/path/to/overleaf-moby-<timestamp>.tar.gz" >&2
  exit 1
fi

archive=$1
if [[ $archive != /* || ! -r $archive ]]; then
  echo "Archive must be an absolute, readable path: $archive" >&2
  exit 1
fi

checksum_file="$archive.sha256"
manifest_file="$archive.manifest"
if [[ ! -r $checksum_file ]]; then
  echo "Missing checksum sidecar: $checksum_file" >&2
  exit 1
fi
if [[ ! -r $manifest_file ]]; then
  echo "Missing source manifest: $manifest_file" >&2
  exit 1
fi
expected_database=$(sed -n 's/^database=//p' "$manifest_file")
expected_credentials_sha256=$(sed -n 's/^credentials_sha256=//p' "$manifest_file")
expected_mongo_fcv=$(sed -n 's/^mongo_fcv=//p' "$manifest_file")
expected_replica_set=$(sed -n 's/^replica_set=//p' "$manifest_file")
expected_mongodb_exec=$(sed -n 's/^mongodb_exec=//p' "$manifest_file")
expected_redis_exec=$(sed -n 's/^redis_exec=//p' "$manifest_file")
expected_overleaf_exec=$(sed -n 's/^overleaf_exec=//p' "$manifest_file")
expected_state_sha256=$(sed -n 's/^state_sha256=//p' "$manifest_file")
for required_value in \
  expected_database expected_credentials_sha256 expected_mongo_fcv \
  expected_replica_set expected_mongodb_exec expected_redis_exec \
  expected_overleaf_exec expected_state_sha256; do
  if [[ -z ${!required_value} ]]; then
    echo "Source manifest is missing $required_value" >&2
    exit 1
  fi
done
(
  cd "$(dirname "$archive")"
  sha256sum --check "$(basename "$checksum_file")"
)

# List once to avoid tar receiving SIGPIPE from grep -q on large archives.
archive_listing=$(mktemp)
tar -tzf "$archive" >"$archive_listing"
unexpected=$(grep -Ev '^(var/lib/overleaf|var/db/mongodb|var/lib/redis-overleaf|etc/overleaf)(/|$)' \
  "$archive_listing" || true)
if [[ -n $unexpected ]]; then
  echo "Archive contains unexpected paths:" >&2
  printf '%s\n' "$unexpected" >&2
  rm -f "$archive_listing"
  exit 1
fi
for required in var/lib/overleaf var/db/mongodb var/lib/redis-overleaf; do
  if ! grep -q "^${required}/" "$archive_listing"; then
    echo "Archive is missing $required" >&2
    rm -f "$archive_listing"
    exit 1
  fi
done
rm -f "$archive_listing"

mapfile -t overleaf_units < <(
  systemctl list-unit-files 'overleaf-*.service' --no-legend \
    | awk '{ print $1 }' \
    | grep -v '^overleaf-private-origin.service$' \
    | sort -u
)
if ((${#overleaf_units[@]} == 0)); then
  echo "Oppy's Overleaf configuration has not been deployed yet." >&2
  exit 1
fi
unit_exec_path() {
  systemctl show "$1" -p ExecStart --value \
    | sed -n 's/^{ path=\([^ ;]*\).*/\1/p'
}
for comparison in \
  "mongodb.service:$expected_mongodb_exec" \
  "redis-overleaf.service:$expected_redis_exec" \
  "overleaf-web.service:$expected_overleaf_exec"; do
  unit=${comparison%%:*}
  expected=${comparison#*:}
  actual=$(unit_exec_path "$unit")
  if [[ $actual != "$expected" ]]; then
    echo "Runtime mismatch for $unit" >&2
    echo "Moby: $expected" >&2
    echo "Oppy: $actual" >&2
    exit 1
  fi
done

for account in overleaf mongodb redis-overleaf; do
  if ! getent passwd "$account" >/dev/null; then
    echo "Missing target service account: $account" >&2
    exit 1
  fi
done

backup_root="/var/backups/overleaf/pre-moby-restore-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup_root/var/lib" "$backup_root/var/db" "$backup_root/etc"
state_paths=(
  /var/lib/overleaf
  /var/db/mongodb
  /var/lib/redis-overleaf
  /etc/overleaf
)
backup_started=false
archive_extraction_started=false

restore_previous_target() {
  status=$?
  if (( status != 0 )); then
    echo "Restore failed; rolling Oppy back to its pre-restore state." >&2
    set +e
    systemctl stop overleaf-private-origin.service
    systemctl stop overleaf-private-origin.socket "${overleaf_units[@]}" \
      redis-overleaf.service mongodb.service
    if $backup_started; then
      for path in "${state_paths[@]}"; do
        saved="$backup_root$path"
        if [[ -e $saved ]]; then
          rm -rf "$path"
          mkdir -p "$(dirname "$path")"
          mv "$saved" "$path"
        elif $archive_extraction_started; then
          # This path did not exist before restore but may have been extracted.
          rm -rf "$path"
        fi
      done
    fi
    systemctl start mongodb.service redis-overleaf.service
    systemctl start "${overleaf_units[@]}"
    systemctl start overleaf-private-origin.socket
  fi
  exit "$status"
}
trap restore_previous_target EXIT

# No request can reach the destination while its state is being replaced. Stop
# both halves because preflight may already have socket-activated the service.
systemctl stop overleaf-private-origin.service
systemctl stop overleaf-private-origin.socket
systemctl stop "${overleaf_units[@]}"
systemctl stop redis-overleaf.service mongodb.service

backup_started=true
for path in "${state_paths[@]}"; do
  if [[ -e $path ]]; then
    mkdir -p "$backup_root$(dirname "$path")"
    mv "$path" "$backup_root$path"
  fi
done

archive_extraction_started=true
tar --acls --xattrs --numeric-owner -xzpf "$archive" -C /

# System-account numeric IDs can differ between hosts. Restore ownership by
# account name while preserving the data and secret contents byte-for-byte.
chown -R overleaf:overleaf /var/lib/overleaf
chown -R mongodb:root /var/db/mongodb
chown -R redis-overleaf:redis-overleaf /var/lib/redis-overleaf
chmod 0700 /var/db/mongodb /var/lib/redis-overleaf
chmod 0600 /var/lib/overleaf/secrets.env
if [[ -d /etc/overleaf ]]; then
  chown -R overleaf:overleaf /etc/overleaf
fi

restored_paths=(
  /var/lib/overleaf
  /var/db/mongodb
  /var/lib/redis-overleaf
)
[[ -e /etc/overleaf ]] && restored_paths+=(/etc/overleaf)
actual_state_sha256=$(
  find "${restored_paths[@]}" -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    | sha256sum \
    | awk '{ print $1 }'
)
if [[ $actual_state_sha256 != "$expected_state_sha256" ]]; then
  echo "Stopped-state file-content hash mismatch." >&2
  echo "Moby: $expected_state_sha256" >&2
  echo "Oppy: $actual_state_sha256" >&2
  exit 1
fi

systemctl start mongodb.service
systemctl restart overleaf-mongo-rs-init.service
systemctl start redis-overleaf.service

init_script=$(systemctl show overleaf-mongo-rs-init.service -p ExecStart --value \
  | sed -n 's/^{ path=\([^ ;]*\).*/\1/p')
mongosh=$(grep -o '/nix/store/[^ ]*/bin/mongosh' "$init_script" | head -1)
if [[ ! -x $mongosh ]]; then
  echo "Could not locate mongosh for post-restore validation." >&2
  exit 1
fi

actual_database=$(
  "$mongosh" --quiet --host 127.0.0.1:27017 --eval '
    const d = db.getSiblingDB("sharelatex");
    print(JSON.stringify({
      users: d.users.countDocuments({}),
      usersWithPasswordHash: d.users.countDocuments({hashedPassword: {$type: "string"}}),
      projects: d.projects.countDocuments({}),
      docs: d.docs.countDocuments({}),
      files: d.files.countDocuments({})
    }))
  ' | tail -1
)
actual_credentials_sha256=$(
  "$mongosh" --quiet --host 127.0.0.1:27017 --eval '
    const crypto = require("crypto");
    const d = db.getSiblingDB("sharelatex");
    const rows = d.users.find({}, {_id: 1, email: 1, hashedPassword: 1})
      .sort({_id: 1}).toArray();
    print(crypto.createHash("sha256").update(EJSON.stringify(rows)).digest("hex"));
  ' | tail -1
)
actual_mongo_fcv=$(
  "$mongosh" --quiet --host 127.0.0.1:27017 \
    --eval 'print(db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1}).featureCompatibilityVersion.version)' \
    | tail -1
)
actual_replica_set=$(
  "$mongosh" --quiet --host 127.0.0.1:27017 --eval '
    const s = rs.status();
    print(JSON.stringify({
      set: s.set,
      writablePrimary: db.hello().isWritablePrimary,
      members: s.members.map(m => m.name).sort()
    }));
  ' | tail -1
)

if [[ $actual_database != "$expected_database" ]]; then
  echo "Database count mismatch." >&2
  echo "Moby: $expected_database" >&2
  echo "Oppy: $actual_database" >&2
  exit 1
fi
if [[ $actual_credentials_sha256 != "$expected_credentials_sha256" ]]; then
  echo "User identity/password-hash digest mismatch." >&2
  exit 1
fi
if [[ $actual_mongo_fcv != "$expected_mongo_fcv" ]]; then
  echo "MongoDB FCV mismatch: Moby=$expected_mongo_fcv Oppy=$actual_mongo_fcv" >&2
  exit 1
fi
if [[ $actual_replica_set != "$expected_replica_set" ]]; then
  echo "MongoDB replica-set mismatch." >&2
  echo "Moby: $expected_replica_set" >&2
  echo "Oppy: $actual_replica_set" >&2
  exit 1
fi

systemctl restart overleaf-secrets-init.service || true
systemctl restart overleaf-migrations.service
systemctl start "${overleaf_units[@]}"
systemctl reload nginx.service

if ! curl --fail --silent --show-error --max-time 15 \
  --output /dev/null http://127.0.0.1:18080/login; then
  echo "Oppy's local Overleaf HTTP check failed." >&2
  exit 1
fi
if systemctl --failed --no-legend | grep -E 'overleaf|mongodb|redis-overleaf'; then
  echo "One or more restored services failed." >&2
  exit 1
fi

systemctl start overleaf-private-origin.socket
trap - EXIT
cat <<EOF
Restore and local validation succeeded.
Database summary: $actual_database
Pre-restore Oppy state is retained at: $backup_root

Moby must remain stopped. Rebuild Karkinos only now to move the public
Cloudflare connector, then validate a real login and project compile.
EOF
