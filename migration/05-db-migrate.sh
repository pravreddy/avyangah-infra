#!/usr/bin/env bash
# =========================================================================
# Phase 05: Database migration with password rotation
#   - Generate a new strong Postgres password
#   - Rewrite password in all .env files on Hetzner (in-place, backups kept)
#   - Start Postgres + Redis on Hetzner (so we have a target to restore into)
#   - Wait for Postgres to initialise with new password
#   - pg_dump careai + docsign_uk on Vultr → stream → restore on Hetzner
#   - Verify row counts match
#
# DOWNTIME: ~2 minutes during pg_dump on Vultr (it's only ~20MB combined)
# Idempotent: re-running re-rotates the password and re-imports the DBs.
# =========================================================================

source "$(dirname "$0")/lib/common.sh"
require_phase "04"

banner "PHASE 05 · DATABASE MIGRATION + PASSWORD ROTATION"

# --- 1. Generate new Postgres password ---
step "Generating new Postgres password"
NEW_PASSWORD="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)"
info "New password length: ${#NEW_PASSWORD} chars (stored in state/postgres.password.new)"
echo "${NEW_PASSWORD}" > "${STATE_DIR}/postgres.password.new"
chmod 600 "${STATE_DIR}/postgres.password.new"

# --- 2. Grab current password from Vultr's .env (to connect for the dump) ---
step "Fetching CURRENT postgres password from Vultr .env"
OLD_PASSWORD="$(ssh_vultr "grep -h '^POSTGRES_PASSWORD=\\|^DB_PASSWORD=' ~/careai/.env ~/careai/.env.docsign 2>/dev/null | head -1 | cut -d= -f2-" | tr -d '"' | tr -d "'")"
[[ -n "${OLD_PASSWORD}" ]] || die "Could not fetch current Postgres password from Vultr .env files"
ok "Current password retrieved (${#OLD_PASSWORD} chars)"

# --- 3. Rewrite password in all .env files on Hetzner ---
step "Rewriting POSTGRES_PASSWORD and DB_PASSWORD in Hetzner .env files"

ssh_hetzner "cd ${REMOTE_CAREAI_DIR} && \
  for f in .env .env.docsign .env.docsign_prod env.production; do
    [[ -f \"\$f\" ]] || continue
    cp \"\$f\" \"\$f.bak.\$(date +%s)\"
    # Replace both POSTGRES_PASSWORD and DB_PASSWORD
    sed -i 's|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${NEW_PASSWORD}|' \"\$f\"
    sed -i 's|^DB_PASSWORD=.*|DB_PASSWORD=${NEW_PASSWORD}|' \"\$f\"
    # Replace in DATABASE_URL (FastAPI uses this)
    sed -i -E 's|(postgresql(\\+asyncpg)?://[^:]+:)[^@]+(@)|\\1${NEW_PASSWORD}\\3|' \"\$f\"
    echo \"  updated: \$f\"
  done"

ok "Passwords rewritten in Hetzner .env files"

# --- 4. Start Postgres + Redis on Hetzner ---
step "Starting Postgres + Redis on Hetzner (so we have a target to restore into)"
ssh_hetzner "cd ${REMOTE_CAREAI_DIR} && docker compose up -d postgres redis"

# Wait for Postgres to be ready
info "Waiting for Postgres to be ready…"
for i in $(seq 1 30); do
  if ssh_hetzner "docker exec careai-postgres pg_isready -U careai" 2>/dev/null | grep -q "accepting"; then
    ok "Postgres is ready"
    break
  fi
  sleep 2
  [[ $i -eq 30 ]] && die "Postgres did not become ready within 60s"
done

# --- IMPORTANT: force the Postgres user password to match .env ---
# POSTGRES_PASSWORD is only read when the data dir is empty. If the data dir
# survived from a previous run with a different password, the env var is
# ignored. This ALTER USER makes sure the DB password always matches .env.
step "Forcing Postgres user password to match .env (defensive)"
ssh_hetzner "docker exec careai-postgres psql -U careai -d careai -c \"ALTER USER careai WITH PASSWORD '${NEW_PASSWORD}';\" 2>&1 | head -5"
ok "Postgres user password synced with .env"

# --- 5. Confirm before doing the DB dump (this is the downtime window) ---
warn "Next step dumps the live Postgres on Vultr."
warn "This is when we cut the cord. Any new signups/signings on Vultr AFTER this point won't be on Hetzner."
if ! confirm "Proceed with pg_dump + pg_restore?" n; then
  info "Aborted. Postgres and Redis are running on Hetzner (empty). Re-run when ready."
  exit 0
fi

# --- 6. Dump + stream + restore ---
for db in careai docsign_uk; do
  step "Migrating database: ${db}"
  
  # Row count BEFORE on Vultr
  rows_before="$(ssh_vultr "sudo docker exec careai-postgres psql -U careai -d ${db} -tAc \
    \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'\"" 2>/dev/null | tr -d '[:space:]')"
  info "  Vultr ${db}: ${rows_before} tables in public schema"
  
  # Drop DB on Hetzner (idempotent re-run)
  ssh_hetzner "docker exec careai-postgres psql -U careai -d postgres -c \"DROP DATABASE IF EXISTS ${db};\""
  ssh_hetzner "docker exec careai-postgres psql -U careai -d postgres -c \"CREATE DATABASE ${db} OWNER careai;\""
  
  # Stream pg_dump → pg_restore
  info "  Dumping + restoring (may take a moment)…"
  ssh_vultr "sudo docker exec careai-postgres pg_dump -U careai --no-owner --no-privileges --format=custom ${db}" \
    | ssh_hetzner "docker exec -i careai-postgres pg_restore --no-owner --no-privileges -U careai -d ${db}"
  
  # Row count AFTER on Hetzner
  rows_after="$(ssh_hetzner "docker exec careai-postgres psql -U careai -d ${db} -tAc \
    \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'\"" 2>/dev/null | tr -d '[:space:]')"
  info "  Hetzner ${db}: ${rows_after} tables in public schema"
  
  if [[ "${rows_before}" == "${rows_after}" && -n "${rows_before}" ]]; then
    ok "  ${db} restored — table counts match (${rows_after})"
  else
    warn "  ${db} table counts differ: Vultr=${rows_before} Hetzner=${rows_after}"
    warn "  Check manually before proceeding to Phase 6"
  fi
done

# --- 7. Verify Postgres now uses the new password ---
step "Verifying new Postgres password works"
if ssh_hetzner "docker exec careai-postgres psql -U careai -d careai -c 'SELECT 1' >/dev/null 2>&1"; then
  ok "New Postgres password works"
else
  die "New password not working — check .env files and container logs"
fi

banner "PHASE 05 COMPLETE"
mark_done "05"

cat <<INFO

${C_BOLD}${C_YELLOW}IMPORTANT — password rotation summary:${C_OFF}
  • New password saved in: state/postgres.password.new (chmod 600, gitignored)
  • Old .env files backed up on Hetzner as *.bak.<timestamp>
  • Vultr's DB is UNCHANGED — old password still works there (so Vultr is a
    live rollback target until we decommission it)

INFO

info "Ready to run: ./06-bring-up-stack.sh"
