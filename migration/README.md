# Vultr → Hetzner Migration Toolkit

Scripted migration of **SignSimple** + **Care AI** from Vultr London (45.32.177.231) to Hetzner Falkenstein (88.99.167.49).

Commit this `migration/` directory to the `care-ai` repo once migration is complete — it's your documented disaster recovery / reproducibility runbook.

## Design principles

- **Idempotent** — every script is safe to re-run; partial failures resume cleanly.
- **Fail-fast** — `set -euo pipefail` everywhere; no silent errors.
- **Human-in-the-loop** — destructive steps (DB restore, Vultr shutdown) prompt for confirmation.
- **No secrets in source** — real config lives in `.env.migration` (gitignored).
- **Auditable** — everything logs to `state/migration.log` with timestamps.
- **Rollback-ready** — `rollback.sh` walks you back to Vultr.

## Quick start

```bash
# 1. One-time setup
cp .env.migration.example .env.migration
# edit .env.migration — fill in Hetzner IP, paths, key locations

chmod +x *.sh

# 2. Run preflight to make sure Mac has everything
./00-preflight.sh

# 3. Either run all phases in sequence…
./run-all.sh

# …or run each phase individually for more control:
./01-harden-hetzner.sh    # needs Hetzner root password (one-time)
./02-install-docker.sh
./03-ghcr-pull.sh         # needs GHCR token (read:packages)
./04-transfer-configs.sh
./05-db-migrate.sh        # ~2 min downtime window
./06-bring-up-stack.sh

# 4. DNS cutover — MANUAL
cat 07-dns-cutover.md     # follow steps at Spaceship + Namecheap

# 5. Post-cutover verification + park Vultr
./08-verify-and-park.sh
```

## Phase map

| # | Script | What it does | Blocking prompts |
|---|---|---|---|
| 00 | `00-preflight.sh` | Checks Mac has ssh/scp/rsync, config is set, keys exist | none |
| 01 | `01-harden-hetzner.sh` | Creates `deploy` user, loads SSH key, disables root SSH + password auth, installs ufw+fail2ban+unattended-upgrades | Hetzner root password (1x) |
| 02 | `02-install-docker.sh` | Installs Docker CE + compose, creates `/mnt/nvme_data/*`, adds `deploy` to docker group | none |
| 03 | `03-ghcr-pull.sh` | `docker login ghcr.io`, pulls all 8 images (care-ai × 2, docsign × 2, postgres, redis, nginx, ollama) | GHCR PAT (`read:packages`) |
| 04 | `04-transfer-configs.sh` | Streams `~/careai/` (configs, compose, scripts, .env) + `/mnt/nvme_data/{careai,docsign,ssl}` from Vultr to Hetzner via piped tar | none |
| 05 | `05-db-migrate.sh` | Generates new Postgres password, rewrites `.env` on Hetzner, starts postgres+redis, `pg_dump` Vultr → `pg_restore` Hetzner for both `careai` and `docsign_uk` | confirmation before DB dump |
| 06 | `06-bring-up-stack.sh` | `docker compose up -d` for both stacks, pulls new Ollama model (`llama3.2:3b` by default), runs HTTP smoke tests on IP | none |
| 07 | `07-dns-cutover.md` | Manual: change A records at Spaceship + Namecheap from Vultr IP to Hetzner IP | — |
| 08 | `08-verify-and-park.sh` | Verifies DNS cut over, HTTPS works via real domains, stops Vultr containers (keeps VM running as rollback) | confirm before stopping Vultr |
| ⚠ | `rollback.sh` | Brings Vultr back up, walks you through DNS revert | multiple confirmations |

## Directory layout

```
migration/
├── .env.migration.example    # Template (committed)
├── .env.migration            # Real config (gitignored)
├── .gitignore
├── README.md                 # this file
├── lib/
│   └── common.sh             # shared helpers (logging, confirm, ssh helpers)
├── 00-preflight.sh
├── 01-harden-hetzner.sh
├── 02-install-docker.sh
├── 03-ghcr-pull.sh
├── 04-transfer-configs.sh
├── 05-db-migrate.sh
├── 06-bring-up-stack.sh
├── 07-dns-cutover.md
├── 08-verify-and-park.sh
├── rollback.sh
├── run-all.sh
└── state/                    # runtime artefacts (gitignored)
    ├── migration.log         # timestamped log of everything
    ├── phase-*.done          # idempotency markers
    └── postgres.password.new # new DB password (chmod 600)
```

## Safety features

### Idempotency

Each script writes a `state/phase-XX.done` marker when it completes. Scripts that depend on a prior phase check for the marker (`require_phase`) and abort with a helpful error if prerequisites aren't met.

You can safely re-run any script — for example, re-running `05-db-migrate.sh` will drop and re-import the DBs (after confirmation), which is useful if you need to re-sync after a Vultr update.

### Data safety

- The old `.env` files are backed up on Hetzner as `.env.bak.<timestamp>` before password rewrite
- The new Postgres password is saved to `state/postgres.password.new` (chmod 600, gitignored)
- Vultr's data is never touched — it remains your rollback target
- Phase 08 only **stops** Vultr containers; it does **not** delete the VM

### Blast-radius containment

- Hetzner gets a fresh GHCR PAT — if leaked, revoke without affecting CI
- Hetzner's SSH authorized_keys matches Vultr's (same Mac key) — if Mac key rotates, both servers update together
- Postgres password is rotated (any old password that may have leaked is now invalid on Hetzner; Vultr still uses the old one until decommissioned)

## Troubleshooting

### Phase 01 fails with "Permission denied"

The Hetzner root password from the provisioning email may have been entered incorrectly, or the provisioning might not be complete yet. Wait 5 min, try again, or check Hetzner Robot panel.

### Phase 03 fails with "denied: denied"

Your GHCR PAT doesn't have `read:packages` scope. Create a new one at GitHub → Settings → Developer settings → Personal access tokens (classic).

### Phase 05: pg_restore fails

Check that the postgres container on Hetzner is actually up: `ssh hetzner-prod 'docker ps | grep postgres'`. If the password rotation in `.env` didn't propagate, `docker compose restart postgres` and retry.

### DNS hasn't propagated after 30 minutes

Check the TTL that was set BEFORE you changed the record — if it was 3600s (1h) and you changed it at the same time as the IP, propagation takes up to 1h. Use `https://www.whatsmydns.net/` to see propagation by region.

### I need to roll back

```bash
./rollback.sh
```

## After a successful migration

1. Commit this directory to the `care-ai` repo:
   ```bash
   cd /Users/praveen.r/Desktop/guhya_ai/
   git add migration/
   git commit -m "Add Vultr→Hetzner migration toolkit"
   git push
   ```
2. Renew Let's Encrypt certs on Hetzner (they expire ~May 12 2026):
   ```bash
   ssh hetzner-prod 'sudo certbot --nginx'
   ```
3. Raise DNS TTL back to 3600 at both registrars (low TTLs cost more queries)
4. After 48h of stable operation on Hetzner, cancel the Vultr subscription
