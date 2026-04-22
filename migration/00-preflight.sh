#!/usr/bin/env bash
# =========================================================================
# Phase 00: Preflight — verify the Mac is ready to run the migration
# Idempotent. Safe to run multiple times.
# =========================================================================

source "$(dirname "$0")/lib/common.sh"

banner "PHASE 00 · PREFLIGHT"

# --- 1. Required tools ---
step "Checking required tools on this Mac"
require_tools ssh scp rsync ssh-keygen awk grep tar gzip curl dig openssl
ok "All required tools present"

# --- 2. SSH keys ---
step "Checking SSH keys"
[[ -f "${LOCAL_SSH_KEY}"     ]] || die "Private key not found: ${LOCAL_SSH_KEY}"
[[ -f "${LOCAL_PUB_KEY}"     ]] || die "Public key not found:  ${LOCAL_PUB_KEY}"

# Permissions
priv_perm="$(stat -f '%Lp' "${LOCAL_SSH_KEY}" 2>/dev/null || stat -c '%a' "${LOCAL_SSH_KEY}")"
if [[ "${priv_perm}" != "600" ]]; then
  warn "Private key ${LOCAL_SSH_KEY} has permissions ${priv_perm}, should be 600"
  chmod 600 "${LOCAL_SSH_KEY}"
  ok "Fixed: chmod 600 ${LOCAL_SSH_KEY}"
fi
ok "Private key: ${LOCAL_SSH_KEY}"
ok "Public key : ${LOCAL_PUB_KEY}"

# --- 3. Config sanity ---
step "Checking .env.migration values"
for var in HETZNER_IP HETZNER_USER VULTR_IP VULTR_USER GHCR_USER \
           SIGNSIMPLE_DOMAIN CAREAI_DOMAIN; do
  if [[ -z "${!var:-}" ]]; then
    die "Missing config: ${var} (edit .env.migration)"
  fi
done
ok "Config values look good"

# --- 4. Can we reach Hetzner via SSH? (may fail until Phase 01 is done) ---
step "Testing Hetzner SSH (may fail until Phase 01 is complete)"
if ssh_hetzner -o BatchMode=yes -o ConnectTimeout=5 "echo ok" 2>/dev/null | grep -q ok; then
  ok "Hetzner SSH works as deploy@${HETZNER_IP}"
else
  warn "Hetzner SSH not yet working — run ./01-harden-hetzner.sh to set it up"
fi

# --- 5. Can we reach Vultr via SSH? ---
step "Testing Vultr SSH"
if ssh_vultr -o BatchMode=yes -o ConnectTimeout=5 "echo ok" 2>/dev/null | grep -q ok; then
  ok "Vultr SSH works as deploy@${VULTR_IP}"
else
  err "Vultr SSH not working. Check ${LOCAL_SSH_KEY} and ${VULTR_IP}."
  exit 1
fi

# --- 6. DNS current state (informational) ---
step "Current DNS A records (informational)"
for d in "${SIGNSIMPLE_DOMAIN}" "${CAREAI_DOMAIN}"; do
  current="$(dig +short A "${d}" | head -1)"
  if [[ "${current}" == "${VULTR_IP}" ]]; then
    dim "  ${d} → ${current}  (currently pointing at Vultr — expected)"
  elif [[ "${current}" == "${HETZNER_IP}" ]]; then
    ok "  ${d} → ${current}  (already on Hetzner)"
  else
    warn "  ${d} → ${current}  (unexpected — check Spaceship/Namecheap)"
  fi
done

# --- 7. DNS TTL check ---
step "Checking DNS TTLs (low TTL = faster cutover)"
for d in "${SIGNSIMPLE_DOMAIN}" "${CAREAI_DOMAIN}"; do
  ttl="$(dig +noall +answer A "${d}" | awk 'NR==1 {print $2}')"
  if [[ -z "${ttl}" ]]; then
    warn "  ${d}: no A record resolved"
  elif (( ttl > 600 )); then
    warn "  ${d}: TTL=${ttl}s — consider lowering to 300s before DNS cutover"
  else
    ok "  ${d}: TTL=${ttl}s  (low enough for fast cutover)"
  fi
done

banner "PREFLIGHT COMPLETE"
mark_done "00"
info "Ready to run: ./01-harden-hetzner.sh"
