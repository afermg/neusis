#!/usr/bin/env bash
# shellcheck disable=SC2016 # MongoDB JavaScript is intentionally single-quoted.
set -Eeuo pipefail
umask 077

if (( EUID != 0 )); then
  echo "Run this snapshot on Moby with sudo." >&2
  exit 1
fi

invoking_user=${SUDO_USER:-root}
invoking_home=$(getent passwd "$invoking_user" | cut -d: -f6)
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
archive=${1:-"$invoking_home/overleaf-moby-$timestamp.tar.gz"}

if [[ $archive != /* ]]; then
  echo "Archive path must be absolute: $archive" >&2
  exit 1
fi
mkdir -p "$(dirname "$archive")"

mapfile -t overleaf_units < <(
  systemctl list-unit-files 'overleaf-*.service' --no-legend \
    | awk '{ print $1 }' \
    | sort -u
)
if ((${#overleaf_units[@]} == 0)); then
  echo "No Overleaf service units found; this does not look like Moby." >&2
  exit 1
fi

connector_was_active=false
if systemctl is-active --quiet cloudflared-overleaf.service; then
  connector_was_active=true
fi
# NixOS makes /etc/systemd/system a symlink into the immutable store. Use
# systemd's higher-priority persistent system.control load path instead; unlike
# a /run drop-in, this guard survives a reboot during the migration.
migration_lock_dir=/etc/systemd/system.control/cloudflared-overleaf.service.d
migration_lock=$migration_lock_dir/99-overleaf-migration-lock.conf
allow_marker=/var/lib/overleaf-migration/allow-moby-ingress
lock_was_present=false
[[ -e $migration_lock ]] && lock_was_present=true
allow_marker_was_present=false
[[ -e $allow_marker ]] && allow_marker_was_present=true
lock_created=false

restart_source_on_error() {
  status=$?
  if (( status != 0 )); then
    echo "Snapshot failed; restarting Moby's original stack." >&2
    systemctl start mongodb.service redis-overleaf.service || true
    systemctl start "${overleaf_units[@]}" || true
    if $lock_created; then
      rm -f "$migration_lock"
      rmdir "$migration_lock_dir" 2>/dev/null || true
    fi
    if $allow_marker_was_present; then
      mkdir -p "$(dirname "$allow_marker")"
      touch "$allow_marker"
    fi
    systemctl daemon-reload || true
    if $connector_was_active; then
      systemctl start cloudflared-overleaf.service || true
    fi
  fi
  exit "$status"
}
trap restart_source_on_error EXIT

# Stop public traffic and writers first, then record counts from the quiescent
# database before stopping MongoDB itself. A persistent systemd condition
# drop-in prevents a Moby reboot from reconnecting the stale writable copy.
if ! $lock_was_present; then
  mkdir -p "$migration_lock_dir"
  cat >"$migration_lock" <<'EOF'
[Unit]
ConditionPathExists=/var/lib/overleaf-migration/allow-moby-ingress
EOF
  chmod 0644 "$migration_lock"
  lock_created=true
fi
rm -f "$allow_marker"
systemctl daemon-reload
systemctl stop cloudflared-overleaf.service
systemctl stop "${overleaf_units[@]}"

init_script=$(systemctl show overleaf-mongo-rs-init.service -p ExecStart --value \
  | sed -n 's/^{ path=\([^ ;]*\).*/\1/p')
mongosh=$(grep -o '/nix/store/[^ ]*/bin/mongosh' "$init_script" | head -1)
if [[ ! -x $mongosh ]]; then
  echo "Could not locate the running deployment's mongosh binary." >&2
  exit 1
fi

database_summary=$(
  "$mongosh" --quiet --host 127.0.0.1:27017 --eval '
    const d = db.getSiblingDB("sharelatex");
    const summary = {
      users: d.users.countDocuments({}),
      usersWithPasswordHash: d.users.countDocuments({hashedPassword: {$type: "string"}}),
      projects: d.projects.countDocuments({}),
      docs: d.docs.countDocuments({}),
      files: d.files.countDocuments({})
    };
    if (summary.users < 7 || summary.usersWithPasswordHash < 7 ||
        summary.projects < 10 || summary.docs < 101) {
      throw new Error("Moby database is below the known-good baseline: " + EJSON.stringify(summary));
    }
    print(JSON.stringify(summary));
  ' | tail -1
)
credentials_sha256=$(
  "$mongosh" --quiet --host 127.0.0.1:27017 --eval '
    const crypto = require("crypto");
    const d = db.getSiblingDB("sharelatex");
    const rows = d.users.find({}, {_id: 1, email: 1, hashedPassword: 1})
      .sort({_id: 1}).toArray();
    print(crypto.createHash("sha256").update(EJSON.stringify(rows)).digest("hex"));
  ' | tail -1
)
mongo_fcv=$(
  "$mongosh" --quiet --host 127.0.0.1:27017 \
    --eval 'print(db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1}).featureCompatibilityVersion.version)' \
    | tail -1
)
replica_set=$(
  "$mongosh" --quiet --host 127.0.0.1:27017 --eval '
    const s = rs.status();
    print(JSON.stringify({
      set: s.set,
      writablePrimary: db.hello().isWritablePrimary,
      members: s.members.map(m => m.name).sort()
    }));
  ' | tail -1
)
unit_exec_path() {
  systemctl show "$1" -p ExecStart --value \
    | sed -n 's/^{ path=\([^ ;]*\).*/\1/p'
}
mongodb_exec=$(unit_exec_path mongodb.service)
redis_exec=$(unit_exec_path redis-overleaf.service)
overleaf_exec=$(unit_exec_path overleaf-web.service)

cat >"$archive.manifest" <<EOF
created_utc=$timestamp
source_host=$(hostname)
database=$database_summary
credentials_sha256=$credentials_sha256
mongo_fcv=$mongo_fcv
replica_set=$replica_set
mongodb_exec=$mongodb_exec
redis_exec=$redis_exec
overleaf_exec=$overleaf_exec
overleaf_units=${overleaf_units[*]}
EOF

# The successful path intentionally leaves Moby stopped so two writable copies
# can never receive traffic at once.
systemctl stop redis-overleaf.service mongodb.service
sync

paths=(
  var/lib/overleaf
  var/db/mongodb
  var/lib/redis-overleaf
)
[[ -e /etc/overleaf ]] && paths+=(etc/overleaf)

absolute_paths=("${paths[@]/#//}")
state_sha256=$(
  find "${absolute_paths[@]}" -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    | sha256sum \
    | awk '{ print $1 }'
)
printf 'state_sha256=%s\n' "$state_sha256" >>"$archive.manifest"

# A stopped physical MongoDB copy preserves the sharelatex database, its seven
# user records/password hashes, replica-set metadata, and every other database.
tar --acls --xattrs --numeric-owner -czpf "$archive" -C / "${paths[@]}"
(
  cd "$(dirname "$archive")"
  sha256sum "$(basename "$archive")" >"$(basename "$archive").sha256"
)
chown "$invoking_user" "$archive" "$archive.sha256" "$archive.manifest"
chmod 0600 "$archive" "$archive.sha256" "$archive.manifest"

trap - EXIT
cat <<EOF
Snapshot complete: $archive
Database summary: $database_summary

Moby's Overleaf, MongoDB, and Redis remain STOPPED, and its Cloudflare
connector has a persistent migration-lock condition against accidental restart
or reboot. Copy the archive plus .sha256 and .manifest sidecars to Oppy, then
run the restore script there. To abort, remove the condition drop-in first.
EOF
