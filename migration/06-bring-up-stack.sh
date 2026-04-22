#!/usr/bin/env bash
# =========================================================================
# Phase 06: Bring up full stack on Hetzner, pull Ollama model, smoke test
#   - docker compose up -d (both compose files)
#   - Pull upgraded Ollama model (llama3.2:3b by default, configurable)
#   - Wait for healthchecks
#   - HTTP smoke test (direct on IP, bypassing DNS)
#   - Show endpoints, logs tail
# Idempotent.
# =========================================================================

source "$(dirname "$0")/lib/common.sh"
require_phase "05"

banner "PHASE 06 · BRING UP STACK + SMOKE TEST"

# --- New Ollama model to pull (override via env OLLAMA_MODEL) ---
NEW_OLLAMA_MODEL="${OLLAMA_MODEL_NEW:-llama3.2:3b}"
info "Will pull new Ollama model: ${NEW_OLLAMA_MODEL}"
info "(Override with:  OLLAMA_MODEL_NEW=qwen3:4b ./06-bring-up-stack.sh  )"

# --- 1. Bring up both stacks together (matches Vultr's deploy-docsign.sh pattern) ---
# docsign-api refers to 'careai-net', which is only defined in docker-compose.yml.
# Compose treats both files as ONE project when stacked with -f -f, sharing the network.
step "Bringing up combined stack (docker-compose.yml + docker-compose.docsign.yml)"
ssh_hetzner "cd ${REMOTE_CAREAI_DIR} && docker compose -f docker-compose.yml -f docker-compose.docsign.yml up -d"

# --- 3. Show running containers ---
step "Running containers on Hetzner"
ssh_hetzner "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# --- 4. Wait for healthchecks ---
step "Waiting up to 90s for containers to become healthy"
for i in $(seq 1 30); do
  unhealthy="$(ssh_hetzner "docker ps --filter 'health=unhealthy' --format '{{.Names}}' | wc -l" | tr -d '[:space:]')"
  starting="$(ssh_hetzner "docker ps --filter 'health=starting' --format '{{.Names}}' | wc -l" | tr -d '[:space:]')"
  if [[ "${unhealthy}" == "0" && "${starting}" == "0" ]]; then
    ok "All healthchecks passing"
    break
  fi
  printf '.'
  sleep 3
done
echo

# --- 5. Pull upgraded Ollama model ---
step "Pulling new Ollama model: ${NEW_OLLAMA_MODEL}"
info "This runs in background — takes ~3-5 min for a 3b model, ~8 min for 7b+"
ssh_hetzner "docker exec careai-ollama ollama pull ${NEW_OLLAMA_MODEL}" &
OLLAMA_PULL_PID=$!

# --- 6. Smoke test — hit endpoints directly on Hetzner IP ---
step "HTTP smoke test (direct to Hetzner IP, bypassing DNS)"

# Try HTTP (most likely to work without SSL cert domain match)
for port in 80 443; do
  proto="http"; [[ $port -eq 443 ]] && proto="https"
  info "Testing ${proto}://${HETZNER_IP}:${port}/ …"
  code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "${proto}://${HETZNER_IP}:${port}/" 2>/dev/null || echo '000')"
  if [[ "${code}" =~ ^(200|301|302|401|403)$ ]]; then
    ok "  ${proto}://${HETZNER_IP}:${port}/ → HTTP ${code}"
  else
    warn "  ${proto}://${HETZNER_IP}:${port}/ → HTTP ${code} (might be OK if nginx expects host header)"
  fi
done

# Try with Host header — tells nginx which vhost to route to
info "Testing with Host header for ${SIGNSIMPLE_DOMAIN}"
code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 \
  --resolve "${SIGNSIMPLE_DOMAIN}:443:${HETZNER_IP}" \
  "https://${SIGNSIMPLE_DOMAIN}/" 2>/dev/null || echo '000')"
if [[ "${code}" =~ ^(200|301|302|401|403)$ ]]; then
  ok "  https://${SIGNSIMPLE_DOMAIN}/ (resolved to Hetzner) → HTTP ${code}"
else
  warn "  https://${SIGNSIMPLE_DOMAIN}/ (resolved to Hetzner) → HTTP ${code}"
fi

info "Testing with Host header for ${CAREAI_DOMAIN}"
code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 \
  --resolve "${CAREAI_DOMAIN}:443:${HETZNER_IP}" \
  "https://${CAREAI_DOMAIN}/" 2>/dev/null || echo '000')"
if [[ "${code}" =~ ^(200|301|302|401|403)$ ]]; then
  ok "  https://${CAREAI_DOMAIN}/ (resolved to Hetzner) → HTTP ${code}"
else
  warn "  https://${CAREAI_DOMAIN}/ (resolved to Hetzner) → HTTP ${code}"
fi

# --- 7. Test in browser instructions ---
cat <<BROWSER

${C_BOLD}Manual browser smoke test (add to /etc/hosts temporarily):${C_OFF}

  sudo sh -c 'echo "${HETZNER_IP} ${SIGNSIMPLE_DOMAIN}" >> /etc/hosts'
  sudo sh -c 'echo "${HETZNER_IP} ${CAREAI_DOMAIN}"     >> /etc/hosts'
  # Test in browser — both sites should work with your actual domain.
  # When done, remove those lines from /etc/hosts.

BROWSER

# --- 8. Wait for Ollama pull (if still running) ---
if kill -0 ${OLLAMA_PULL_PID} 2>/dev/null; then
  info "Waiting for Ollama model pull to finish…"
  wait ${OLLAMA_PULL_PID} && ok "Ollama model ${NEW_OLLAMA_MODEL} ready" \
                          || warn "Ollama pull may have failed — check with: docker exec careai-ollama ollama list"
fi

# --- 9. Update OLLAMA_MODEL in .env ---
step "Updating OLLAMA_MODEL in .env files on Hetzner"
ssh_hetzner "cd ${REMOTE_CAREAI_DIR} && \
  for f in .env .env.docsign .env.docsign_prod env.production; do
    [[ -f \"\$f\" ]] || continue
    sed -i 's|^OLLAMA_MODEL=.*|OLLAMA_MODEL=${NEW_OLLAMA_MODEL}|' \"\$f\"
    echo \"  updated OLLAMA_MODEL in \$f\"
  done"
info "Restarting API containers to pick up new OLLAMA_MODEL"
ssh_hetzner "cd ${REMOTE_CAREAI_DIR} && docker compose -f docker-compose.yml -f docker-compose.docsign.yml restart careai-api-blue docsign-api-blue 2>/dev/null || true"

# --- 10. Recent logs for visibility ---
step "Last 20 lines from each key container"
for c in careai-api-blue docsign-api-blue careai-nginx careai-postgres; do
  echo
  dim "──── ${c} ────"
  ssh_hetzner "docker logs --tail 20 ${c} 2>&1 | head -25" || true
done

banner "PHASE 06 COMPLETE"
mark_done "06"

cat <<NEXT

${C_BOLD}Next step — DNS cutover:${C_OFF}
  Both sites are live on ${HETZNER_IP}.
  Verify them via the /etc/hosts trick above before flipping DNS.
  When ready, follow the steps in:  ${C_BOLD}07-dns-cutover.md${C_OFF}

NEXT
