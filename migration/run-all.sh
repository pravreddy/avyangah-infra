#!/usr/bin/env bash
# =========================================================================
# Run phases 00 through 06 in sequence, with a pause between each.
# DNS cutover (Phase 07) and verification (Phase 08) are still manual,
# because they need human judgement.
# =========================================================================

source "$(dirname "$0")/lib/common.sh"

banner "MIGRATION RUN-ALL (phases 00 → 06)"

cat <<INFO

This will run:
  00-preflight.sh           (check prerequisites)
  01-harden-hetzner.sh      (root → deploy, SSH lockdown, firewall)  ← ROOT PASSWORD PROMPT
  02-install-docker.sh      (docker + directory layout)
  03-ghcr-pull.sh           (GHCR login + image pre-pull)            ← GHCR TOKEN PROMPT
  04-transfer-configs.sh    (rsync configs + media + SSL)
  05-db-migrate.sh          (rotate password + pg_dump/restore)      ← ~2 min downtime window
  06-bring-up-stack.sh      (compose up + Ollama pull + smoke tests)

After that, you do Phase 07 (DNS cutover) manually per 07-dns-cutover.md,
then run ./08-verify-and-park.sh.

INFO

if ! confirm "Start full automated run (phases 00-06)?" n; then
  info "Aborted. You can run each phase individually."
  exit 0
fi

PHASES=(
  "00-preflight.sh"
  "01-harden-hetzner.sh"
  "02-install-docker.sh"
  "03-ghcr-pull.sh"
  "04-transfer-configs.sh"
  "05-db-migrate.sh"
  "06-bring-up-stack.sh"
)

for phase in "${PHASES[@]}"; do
  banner "RUNNING: ${phase}"
  if ! "${SCRIPT_DIR}/${phase}"; then
    err "${phase} failed. Stopping. Fix the issue, then re-run ./${phase} or ./run-all.sh."
    exit 1
  fi
  echo
  if confirm "Continue to next phase?" y; then
    continue
  else
    info "Paused. Resume by running the next script manually."
    exit 0
  fi
done

banner "ALL AUTOMATED PHASES COMPLETE 🎉"
info "Next: follow 07-dns-cutover.md, then run ./08-verify-and-park.sh"
