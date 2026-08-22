# Overleaf on Oppy, with ingress on Karkinos

## Current deployment and recovery pointers

The active deployment is defined by:

- [`machines/oppy/overleaf.nix`](overleaf.nix) for Overleaf, MongoDB, Redis,
  Git Bridge, and Oppy's private origin;
- [`machines/karkinos/overleaf-ingress.nix`](../karkinos/overleaf-ingress.nix)
  for the public Cloudflare connector; and
- the encrypted tunnel token at
  `secrets/karkinos/cloudflared-overleaf.age`.

The completed source-state archive is retained on both Moby and Oppy at
`/home/amunoz/overleaf-moby-20260822T160651Z.tar.gz`, with adjacent `.sha256`
and `.manifest` sidecars. Its archive SHA-256 is
`f3db727a2ea2d8ef9b2d7f94a55863d0eb97004edfa9ac3a92f1953fa874344b`.
Moby's former declarative setup is archived, but no longer imported, in
[`afermg/nixos-config`](https://github.com/afermg/nixos-config/blob/main/machines/moby/OVERLEAF_ARCHIVE.md).

The public service is <https://overleaf.quasimorphic.com>. Moby's former
Overleaf writers and tunnel must remain inactive; after Oppy accepts writes,
the old Moby state is a recovery source, not a writable failover.

## Original migration record

This runbook preserves the native NixOS Overleaf deployment originally on Moby,
including:

- the complete MongoDB replica-set data directory (`/var/db/mongodb`), which
  contains users, password hashes, projects, documents, and migration state;
- Overleaf files and internal service secrets (`/var/lib/overleaf`);
- Redis persistence (`/var/lib/redis-overleaf`); and
- the existing `overleaf.quasimorphic.com` URL and Cloudflare tunnel.

The baseline observed on Moby before the migration was **7 users, 7 password
hashes, 10 projects, 101 documents, and 0 legacy `files` records**. The scripts
capture fresh quiescent counts and require the restored database to match them.
No password or password hash is printed or stored outside the encrypted/physical
state copy.

## Topology

```text
Cloudflare
  → cloudflared on Karkinos (127.0.0.1:18080)
  → systemd-socket-proxyd over Tailscale
  → Oppy 100.79.40.39:18080
  → systemd-socket-proxyd
  → Oppy Overleaf nginx 127.0.0.1:18080
```

MongoDB, Redis, Overleaf's Node services, and nginx remain loopback-only. The
Cloudflare tunnel token is committed only as an age-encrypted Karkinos secret.

## 1. Build and deploy the destination without cutting over

The upstream package's network-produced fixed-output dependency is no longer
reproducible from npm. Copy Moby's already-built, exact Overleaf closure into
Oppy's store before Moby goes offline. The path is pinned by the configuration:

```bash
nix copy --no-check-sigs --from ssh://moby \
  /nix/store/p15zd90s9fzcjysyb6v5rgndx8z52xrv-overleaf-0-unstable-2026-04-13 \
  /nix/store/wn8ppn5p6i5l79cr2lb0jxiw0zcmyi56-overleaf-git-bridge-0-unstable-2026-04-13
```

Then, from this repository, first clear any stale Karkinos cutover sentinel
from an earlier attempt and build using an explicit path flake (which also works
before the new files have been committed):

```bash
ssh -t karkinos 'sudo systemctl stop cloudflared-overleaf.service 2>/dev/null || true; \
  sudo rm -f /var/lib/overleaf-ingress/enabled'
nix flake check "path:$PWD" --no-build
nix build "path:$PWD#nixosConfigurations.oppy.config.system.build.toplevel"
nix build "path:$PWD#nixosConfigurations.karkinos.config.system.build.toplevel"
sudo nixos-rebuild switch --flake "path:$PWD#oppy"
ssh -t karkinos 'cd /path/to/neusis && \
  sudo nixos-rebuild switch --flake "path:$PWD#karkinos"'
```

The Karkinos connector has
`ConditionPathExists=/var/lib/overleaf-ingress/enabled`. Therefore the rebuild
installs everything but **cannot start the shared Cloudflare tunnel yet**.
Moby remains the live service during these builds.

Verify the private path before touching Moby:

```bash
curl -I --max-time 15 http://100.79.40.39:18080/login
ssh karkinos 'curl -I --max-time 15 http://127.0.0.1:18080/login'
```

This checks Oppy's temporary empty instance only; it is not public.

## 2. Quiesce Moby and create the exact state snapshot

Copy the snapshot helper to Moby and run it interactively:

```bash
scp machines/oppy/migration/snapshot-overleaf-on-moby.sh moby:/tmp/
ssh -t moby 'sudo bash /tmp/snapshot-overleaf-on-moby.sh'
```

The helper installs a persistent systemd condition drop-in that prevents Moby's
Cloudflare connector from restarting after a reboot, stops all Overleaf writers,
records database counts and a SHA-256 digest of sorted user
IDs/emails/password hashes, stops Redis and MongoDB, hashes the stopped
filesystem state, and archives the three state directories. On failure it
removes the new drop-in and restarts Moby. On success it deliberately leaves
Moby stopped and reports an archive path such as:

```text
/home/amunoz/overleaf-moby-YYYYMMDDTHHMMSSZ.tar.gz
```

Copy the archive and both sidecars to Oppy:

```bash
scp moby:/home/amunoz/overleaf-moby-YYYYMMDDTHHMMSSZ.tar.gz{,.sha256,.manifest} \
  /home/amunoz/
```

## 3. Restore and validate on Oppy

```bash
sudo bash machines/oppy/migration/restore-overleaf-on-oppy.sh \
  /home/amunoz/overleaf-moby-YYYYMMDDTHHMMSSZ.tar.gz
```

The restore helper:

1. verifies the archive hash, mandatory source manifest, and allowed paths;
2. stops and backs up Oppy's initial empty state under `/var/backups/overleaf`;
3. restores MongoDB, Redis, Overleaf files, and `secrets.env`;
4. fixes service ownership by target account name;
5. verifies the stopped filesystem-content digest before starting anything;
6. starts the exact MongoDB 8.0.28-compatible stack;
7. compares counts, the user/password-hash digest, FCV, and replica-set state;
8. checks the local HTTP endpoint and failed systemd units.

Do not proceed if any comparison fails.

## 4. Move public ingress to Karkinos

First prove the old connector is still stopped:

```bash
ssh moby 'systemctl is-active cloudflared-overleaf.service'  # must print inactive
```

Enable the persistent cutover sentinel and start Karkinos's connector:

```bash
ssh -t karkinos 'sudo install -d -m 0755 /var/lib/overleaf-ingress && \
  sudo touch /var/lib/overleaf-ingress/enabled && \
  sudo systemctl start cloudflared-overleaf.service'
```

Validate:

```bash
ssh karkinos 'systemctl status --no-pager cloudflared-overleaf.service'
curl -fsS https://overleaf.quasimorphic.com/login >/dev/null
```

Then perform the stateful checks in a browser:

1. sign in with an existing account and existing password;
2. open an existing project and verify its document contents/history;
3. compile a project and fetch the generated PDF;
4. create a small temporary project, edit it, reload, and verify persistence;
5. test Git Bridge if it is in active use.

## Rollback rule

Before Karkinos is enabled or before any write reaches Oppy, rollback is:

```bash
ssh -t karkinos 'sudo systemctl stop cloudflared-overleaf.service; \
  sudo rm -f /var/lib/overleaf-ingress/enabled'
ssh -t moby 'sudo rm -f \
  /etc/systemd/system.control/cloudflared-overleaf.service.d/99-overleaf-migration-lock.conf; \
  sudo systemctl daemon-reload; \
  sudo systemctl start mongodb redis-overleaf; \
  sudo systemctl start "overleaf-*.service" cloudflared-overleaf.service'
```

**After Oppy accepts even one write, never restart Moby as the public writable
instance from its old snapshot.** First remove the Karkinos sentinel, quiesce
Oppy, and reverse-copy its current MongoDB, Redis, and Overleaf state to Moby
using the same stopped-state method. Otherwise rollback would silently discard
user edits and can create divergent histories.
