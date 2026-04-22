#!/usr/bin/env bash
# =========================================================================
# Phase 04: Transfer configs + media + SSL from Vultr to Hetzner
#   - Streams data Vultr → Mac → Hetzner via piped tar (no intermediate disk)
#   - Copies: ~/careai/ config files, /mnt/nvme_data/{careai,docsign,ssl}
#   - Excludes: logs, postgres_data (handled in Phase 5), redis_data (ephemeral),
#               hdd_storage/ollama/models (re-pull on Hetzner), backups
# Idempotent: overwrites files, safe to re-run before DB migration.
# =========================================================================

source "$(dirname "$0")/lib/common.sh"
require_phase "03"

banner "PHASE 04 · TRANSFER CONFIGS, MEDIA, SSL"

# --- 1. Transfer ~/careai/ (configs, compose files, scripts, .env) ---
step "Streaming ~/careai/ configs from Vultr to Hetzner"
info "Excluding: hdd_storage, logs, postgres_data, redis_data, *.bak"

ssh_vultr "cd ~/careai && tar czf - \
            --exclude='hdd_storage' \
            --exclude='*.log' \
            --exclude='*.bak' \
            --exclude='__pycache__' \
            --exclude='.git' \
            ." \
  | ssh_hetzner "cd ${REMOTE_CAREAI_DIR} && tar xzf - --no-same-owner"

ok "~/careai/ configs transferred"

# --- 2. Transfer /mnt/nvme_data (selective) ---
step "Streaming /mnt/nvme_data/{careai,docsign,ssl} from Vultr to Hetzner"
info "Excluding: postgres_data (DB dump handled in Phase 5), redis_data, logs, backups"

ssh_vultr "cd /mnt/nvme_data && sudo tar czf - \
            careai docsign ssl 2>/dev/null || true" \
  | ssh_hetzner "cd ${REMOTE_NVME_DIR} && tar xzf - --no-same-owner"

# Fix ownership
ssh_hetzner "sudo chown -R deploy:deploy ${REMOTE_NVME_DIR}/{careai,docsign,ssl} 2>/dev/null || true"

ok "/mnt/nvme_data payload transferred"

# --- 3. Show what arrived ---
step "Hetzner file layout after transfer"
ssh_hetzner "echo '~/careai/:' && ls -la ${REMOTE_CAREAI_DIR} && echo && \
             echo '~/careai/ssl/:' && ls -la ${REMOTE_CAREAI_DIR}/ssl 2>/dev/null && echo && \
             echo '/mnt/nvme_data/:' && du -sh ${REMOTE_NVME_DIR}/*"

# --- 4. Sanity checks ---
step "Sanity checks"

# .env files present?
for f in .env .env.docsign .env.docsign_prod env.production; do
  if ssh_hetzner "test -f ${REMOTE_CAREAI_DIR}/${f}"; then
    ok "  ${f} present"
  else
    warn "  ${f} MISSING on Hetzner"
  fi
done

# Compose files present?
for f in docker-compose.yml docker-compose.docsign.yml; do
  if ssh_hetzner "test -f ${REMOTE_CAREAI_DIR}/${f}"; then
    ok "  ${f} present"
  else
    err "  ${f} MISSING on Hetzner — critical!"
  fi
done

# SSL certs present?
if ssh_hetzner "test -f ${REMOTE_CAREAI_DIR}/ssl/fullchain.pem && test -f ${REMOTE_CAREAI_DIR}/ssl/privkey.pem"; then
  ok "  SSL certs present (reminder: LE certs from Feb 11, renew with certbot after cutover)"
else
  warn "  SSL certs not found — stack may not start HTTPS successfully"
fi

banner "PHASE 04 COMPLETE"
mark_done "04"
info "Ready to run: ./05-db-migrate.sh"
