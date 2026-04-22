#!/usr/bin/env bash
# =========================================================================
# Shared functions used by all migration scripts
# Source this at the top of every script:  source "$(dirname "$0")/lib/common.sh"
# =========================================================================

set -euo pipefail

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.migration"
STATE_DIR="${SCRIPT_DIR}/state"
LOG_FILE="${STATE_DIR}/migration.log"

mkdir -p "${STATE_DIR}"

# --- Load config ---
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "❌ ${ENV_FILE} not found. Copy .env.migration.example → .env.migration and fill it in."
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"

# --- Colours (only if stdout is a TTY) ---
if [[ -t 1 ]]; then
  C_RED='\033[0;31m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[1;33m'
  C_BLUE='\033[0;34m'
  C_GREY='\033[0;90m'
  C_BOLD='\033[1m'
  C_OFF='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_GREY=''; C_BOLD=''; C_OFF=''
fi

# --- Logging ---
_log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%s] %s\n' "${ts}" "${level}" "${msg}" >> "${LOG_FILE}"
}

info()    { _log INFO    "$*"; printf "${C_BLUE}ℹ${C_OFF}  %s\n"               "$*"; }
ok()      { _log SUCCESS "$*"; printf "${C_GREEN}✓${C_OFF}  ${C_GREEN}%s${C_OFF}\n" "$*"; }
warn()    { _log WARN    "$*"; printf "${C_YELLOW}⚠${C_OFF}  ${C_YELLOW}%s${C_OFF}\n" "$*"; }
err()     { _log ERROR   "$*"; printf "${C_RED}✗${C_OFF}  ${C_RED}%s${C_OFF}\n"  "$*"; }
step()    { _log STEP    "$*"; printf "\n${C_BOLD}▶ %s${C_OFF}\n"              "$*"; }
dim()     { printf "${C_GREY}%s${C_OFF}\n"                                      "$*"; }

die() { err "$*"; exit 1; }

# --- User prompts ---
confirm() {
  local prompt="${1:-Continue?}"
  local default="${2:-n}"
  local yn
  if [[ "${default}" == "y" ]]; then
    read -r -p "${prompt} [Y/n] " yn
    yn="${yn:-y}"
  else
    read -r -p "${prompt} [y/N] " yn
    yn="${yn:-n}"
  fi
  # Portable lowercase (macOS bash 3.2 doesn't support ${var,,})
  yn="$(printf '%s' "${yn}" | tr '[:upper:]' '[:lower:]')"
  [[ "${yn}" == "y" || "${yn}" == "yes" ]]
}

prompt_secret() {
  local prompt="$1"
  local var
  read -r -s -p "${prompt}: " var
  echo >&2
  printf '%s' "${var}"
}

# --- Connection helpers ---
ssh_hetzner() {
  ssh -i "${LOCAL_SSH_KEY}" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      "${HETZNER_USER}@${HETZNER_IP}" "$@"
}

ssh_vultr() {
  ssh -i "${LOCAL_SSH_KEY}" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      "${VULTR_USER}@${VULTR_IP}" "$@"
}

scp_to_hetzner() {
  local src="$1" dst="$2"
  scp -i "${LOCAL_SSH_KEY}" \
      -o StrictHostKeyChecking=accept-new \
      "${src}" "${HETZNER_USER}@${HETZNER_IP}:${dst}"
}

# --- Phase markers (for idempotency + rollback) ---
mark_done() {
  local phase="$1"
  touch "${STATE_DIR}/phase-${phase}.done"
  ok "Phase ${phase} complete (marker: state/phase-${phase}.done)"
}

is_done() {
  local phase="$1"
  [[ -f "${STATE_DIR}/phase-${phase}.done" ]]
}

require_phase() {
  local phase="$1"
  if ! is_done "${phase}"; then
    die "Phase ${phase} has not been completed. Run ${phase}-*.sh first."
  fi
}

# --- Preflight assertion ---
require_tools() {
  local missing=()
  for tool in "$@"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      missing+=("${tool}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
}

# --- Banner ---
banner() {
  local title="$1"
  printf "\n${C_BOLD}═══════════════════════════════════════════════════════════════${C_OFF}\n"
  printf "${C_BOLD}  %s${C_OFF}\n" "${title}"
  printf "${C_BOLD}═══════════════════════════════════════════════════════════════${C_OFF}\n\n"
}
