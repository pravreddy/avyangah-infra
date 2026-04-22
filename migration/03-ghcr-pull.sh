#!/usr/bin/env bash
# =========================================================================
# Phase 03: Authenticate to GHCR on Hetzner and pre-pull all images
#   - Prompts for GHCR personal access token (read:packages scope)
#   - docker login ghcr.io on Hetzner (credentials stored in ~/.docker/config.json)
#   - Pulls every image referenced in compose files
# Idempotent: re-running is fine, pull is a no-op if image already present.
# =========================================================================

source "$(dirname "$0")/lib/common.sh"
require_phase "02"

banner "PHASE 03 · GHCR AUTH + PULL IMAGES"

# --- Get token ---
if [[ -z "${GHCR_TOKEN:-}" ]]; then
  info "Create a token at: https://github.com/settings/tokens (classic, scope: read:packages)"
  GHCR_TOKEN="$(prompt_secret "Paste GHCR token (starts with ghp_ or github_pat_)")"
fi

[[ -n "${GHCR_TOKEN}" ]] || die "Empty token"

# --- Login on Hetzner (pipe token via stdin, never on command line) ---
step "Logging deploy into ghcr.io on Hetzner"
ssh_hetzner "docker login ghcr.io -u '${GHCR_USER}' --password-stdin" <<< "${GHCR_TOKEN}" \
  || die "docker login failed — check token scope (need read:packages)"
ok "docker login to ghcr.io succeeded"

# --- Pull known images (from your memory of the stack) ---
IMAGES=(
  "ghcr.io/pravreddy/careai-api:latest"
  "ghcr.io/pravreddy/careai-frontend:latest"
  "ghcr.io/pravreddy/docsign-api:latest"
  "ghcr.io/pravreddy/docsign-frontend:latest"
  "postgres:16-alpine"
  "redis:7-alpine"
  "nginx:alpine"
  "ollama/ollama:latest"
)

step "Pulling images (${#IMAGES[@]} total — this takes a few minutes)"
for img in "${IMAGES[@]}"; do
  info "pulling ${img}"
  ssh_hetzner "docker pull '${img}'" || warn "Failed to pull ${img} — will retry during stack bring-up"
done

# --- Summary ---
step "Images on Hetzner"
ssh_hetzner "docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | head -20"

banner "PHASE 03 COMPLETE"
mark_done "03"
info "Ready to run: ./04-transfer-configs.sh"
