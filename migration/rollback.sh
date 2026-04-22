#!/usr/bin/env bash
# =========================================================================
# Emergency Rollback
#   - Shows DNS rollback instructions (registrars)
#   - Brings Vultr containers back up if they were stopped
#   - Takes Hetzner stack down to avoid confusion (optional)
# =========================================================================

source "$(dirname "$0")/lib/common.sh"

banner "EMERGENCY ROLLBACK"

cat <<WARN

${C_YELLOW}This script assists with rolling back to Vultr.${C_OFF}

Rollback steps:
  1. Change DNS records back to Vultr IP (${VULTR_IP}) at your registrars
  2. Bring Vultr containers back up
  3. (Optionally) stop Hetzner stack

WARN

if ! confirm "Proceed with rollback?" n; then
  info "Aborted."
  exit 0
fi

# --- 1. DNS instructions ---
step "Step 1 — revert DNS records (MANUAL — do this first in a browser)"

cat <<DNS

  ${C_BOLD}signsimple.co.uk (Spaceship):${C_OFF}
    Login → Advanced DNS → change A record for @ and www:
    ${VULTR_IP}  (was ${HETZNER_IP})
    TTL: 300

  ${C_BOLD}careaisoftware.co.uk (Namecheap):${C_OFF}
    Login → Advanced DNS → change A record for @ and www:
    ${VULTR_IP}  (was ${HETZNER_IP})
    TTL: 5 min

  Propagation check:
    dig @1.1.1.1 +short ${SIGNSIMPLE_DOMAIN}
    dig @1.1.1.1 +short ${CAREAI_DOMAIN}

DNS

if ! confirm "Have you reverted DNS at the registrars?" n; then
  warn "Rollback incomplete — go revert DNS first, then re-run."
  exit 0
fi

# --- 2. Bring Vultr containers back up ---
step "Step 2 — bringing Vultr containers back up"
ssh_vultr "cd ~/careai && \
  docker compose -f docker-compose.yml up -d && \
  docker compose -f docker-compose.docsign.yml up -d && \
  docker ps --format 'table {{.Names}}\t{{.Status}}'"
ok "Vultr containers are up"

# --- 3. Smoke test Vultr ---
step "Verifying Vultr responds (direct IP, bypassing DNS)"
for d in "${SIGNSIMPLE_DOMAIN}" "${CAREAI_DOMAIN}"; do
  code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "${d}:443:${VULTR_IP}" \
    "https://${d}/" 2>/dev/null || echo '000')"
  if [[ "${code}" =~ ^(200|301|302|401|403)$ ]]; then
    ok "  ${d} @ Vultr → HTTP ${code}"
  else
    err "  ${d} @ Vultr → HTTP ${code}  (investigate)"
  fi
done

# --- 4. Optionally take Hetzner down ---
step "Step 3 — take Hetzner stack down? (optional)"
if confirm "Stop containers on Hetzner (keeps data, stops services)?" n; then
  ssh_hetzner "cd ${REMOTE_CAREAI_DIR} && \
    docker compose -f docker-compose.yml down 2>/dev/null; \
    docker compose -f docker-compose.docsign.yml down 2>/dev/null; \
    docker ps"
  ok "Hetzner containers stopped"
else
  info "Hetzner left running — traffic still on Vultr per DNS"
fi

banner "ROLLBACK COMPLETE"
info "DNS should propagate in 2-10 minutes. Traffic is back on Vultr."
info "Once you've identified the issue, re-run migration scripts to retry."
