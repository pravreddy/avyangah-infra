#!/usr/bin/env bash
# =========================================================================
# Phase 08: Verify DNS cutover worked, then park Vultr (don't delete yet)
#   - Checks that DNS now resolves to Hetzner
#   - Runs HTTPS smoke tests against real domains
#   - Stops Vultr containers (keeps box running as rollback target)
#   - Shows post-cutover checklist
# Idempotent.
# =========================================================================

source "$(dirname "$0")/lib/common.sh"
require_phase "06"

banner "PHASE 08 · VERIFY + PARK VULTR"

# --- 1. Check DNS is pointing at Hetzner ---
step "DNS resolution check (querying 1.1.1.1 to bypass local cache)"
all_good=true
for d in "${SIGNSIMPLE_DOMAIN}" "${CAREAI_DOMAIN}"; do
  current="$(dig @1.1.1.1 +short A "${d}" | head -1)"
  if [[ "${current}" == "${HETZNER_IP}" ]]; then
    ok "  ${d} → ${current}  (Hetzner ✓)"
  elif [[ "${current}" == "${VULTR_IP}" ]]; then
    err "  ${d} → ${current}  (still Vultr — DNS not updated, or not yet propagated)"
    all_good=false
  else
    warn "  ${d} → ${current}  (unexpected)"
    all_good=false
  fi
done

if ! ${all_good}; then
  warn "DNS has not fully cut over yet."
  warn "Wait for propagation (usually 2-10 min on a 300s TTL) and re-run."
  if ! confirm "Continue anyway (NOT recommended)?" n; then
    exit 1
  fi
fi

# --- 2. HTTPS smoke test on real domains ---
step "HTTPS smoke tests"
for d in "${SIGNSIMPLE_DOMAIN}" "${CAREAI_DOMAIN}"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${d}/" 2>/dev/null || echo '000')"
  if [[ "${code}" =~ ^(200|301|302|401|403)$ ]]; then
    ok "  https://${d}/ → HTTP ${code}"
  else
    err "  https://${d}/ → HTTP ${code}  (investigate!)"
    all_good=false
  fi
done

# --- 3. Check which server served the request (via Server header or known path) ---
step "Confirming traffic lands on Hetzner"
for d in "${SIGNSIMPLE_DOMAIN}" "${CAREAI_DOMAIN}"; do
  resolved_ip="$(curl -s -o /dev/null -w '%{remote_ip}' "https://${d}/" 2>/dev/null)"
  if [[ "${resolved_ip}" == "${HETZNER_IP}" ]]; then
    ok "  ${d} traffic landing on ${resolved_ip} (Hetzner ✓)"
  else
    warn "  ${d} traffic landing on ${resolved_ip} (expected ${HETZNER_IP})"
  fi
done

# --- 4. Vultr parking: stop containers but DO NOT delete box yet ---
step "Parking Vultr (stopping containers — NOT destroying box)"
warn "Vultr will be stopped, but kept running for ${C_BOLD}48 hours${C_OFF} as a rollback target."
if confirm "Proceed to stop containers on Vultr?" y; then
  ssh_vultr "cd ~/careai && docker compose -f docker-compose.yml down 2>/dev/null; \
             docker compose -f docker-compose.docsign.yml down 2>/dev/null; \
             docker ps"
  ok "Vultr containers stopped"
  info "Vultr VM itself is still running — decommission after 48h if Hetzner is stable"
else
  info "Vultr left running (containers still up) — you can stop them later with rollback.sh"
fi

# --- 5. Post-cutover checklist ---
banner "MIGRATION COMPLETE 🎉"
mark_done "08"

cat <<CHECKLIST

${C_BOLD}Post-cutover checklist — next 24-48 hours:${C_OFF}

  [ ] Monitor https://${SIGNSIMPLE_DOMAIN} for errors — ${C_BOLD}docker logs -f docsign-api-blue${C_OFF}
  [ ] Monitor https://${CAREAI_DOMAIN} for errors    — ${C_BOLD}docker logs -f careai-api-blue${C_OFF}
  [ ] Send a test invoice/signing through SignSimple
  [ ] Test AI Detector with the new ${C_BOLD}llama3.2:3b${C_OFF} (or whichever model you pulled)

${C_BOLD}Within 1 week:${C_OFF}
  [ ] Renew Let's Encrypt cert on Hetzner (current one expires ~May 12):
       ssh hetzner-prod 'sudo certbot --nginx -d ${SIGNSIMPLE_DOMAIN} -d www.${SIGNSIMPLE_DOMAIN}'
       ssh hetzner-prod 'sudo certbot --nginx -d ${CAREAI_DOMAIN} -d www.${CAREAI_DOMAIN}'
  [ ] Configure Stripe + TrueLayer webhooks (deferred from migration)
  [ ] Investigate the orphaned CLOUDFLARE_* env vars — delete if truly unused
  [ ] Set up automated Postgres backup → Cloudflare R2 or similar
  [ ] Raise DNS TTL back to 3600 or higher (lower TTL costs more DNS queries)

${C_BOLD}48 hours from now, if all is well:${C_OFF}
  [ ] Cancel the Vultr subscription and destroy the VM
  [ ] Remove old password from any password managers / 1Password / etc.
  [ ] Rotate any other secrets that may have been exposed in chat logs

${C_BOLD}New server details saved to ~/.ssh/config:${C_OFF}
  ssh hetzner-prod   # quick access

${C_BOLD}New Postgres password:${C_OFF}
  ${STATE_DIR}/postgres.password.new  (chmod 600, gitignored)

CHECKLIST
