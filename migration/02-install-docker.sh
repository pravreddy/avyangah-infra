#!/usr/bin/env bash
# =========================================================================
# Phase 02: Install Docker on Hetzner + prep directory layout
#   - Install Docker CE + docker compose v2
#   - Add deploy to docker group (no more sudo docker)
#   - Create /mnt/nvme_data with subdirs (matching Vultr paths)
#   - Create ~/careai project directory
# Idempotent.
# =========================================================================

source "$(dirname "$0")/lib/common.sh"
require_phase "01"

banner "PHASE 02 · INSTALL DOCKER + PREP DIRS"

REMOTE_SCRIPT="$(cat <<'REMOTE_EOF'
set -euo pipefail

# --- Install fuse-overlayfs FIRST (Debian 12 + Docker 29 overlayfs quirk) ---
# Avoids "failed to convert whiteout file ... operation not permitted" on image pull
sudo apt-get install -qq -y fuse-overlayfs

# --- Install Docker CE (official convenience script) ---
if command -v docker >/dev/null 2>&1; then
  echo "[remote] Docker already installed: $(docker --version)"
else
  echo "[remote] Installing Docker CE"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi

# --- Configure Docker daemon with fuse-overlayfs (before first start) ---
echo "[remote] Configuring Docker to use fuse-overlayfs storage driver"
sudo mkdir -p /etc/docker
cat <<'EOF' | sudo tee /etc/docker/daemon.json >/dev/null
{
  "storage-driver": "fuse-overlayfs",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
sudo systemctl restart docker

# --- Add deploy to docker group (no more sudo docker) ---
sudo usermod -aG docker deploy
echo "[remote] deploy is now in docker group (re-login needed for this shell)"

# --- Ensure docker compose plugin is present ---
if ! docker compose version >/dev/null 2>&1; then
  sudo apt-get install -y docker-compose-plugin
fi
echo "[remote] docker compose: $(docker compose version)"

# --- Prep directory layout (mirrors Vultr paths so compose files Just Work) ---
echo "[remote] Creating /mnt/nvme_data and subdirs"
sudo mkdir -p /mnt/nvme_data/{careai,docsign/media,docsign/static,ssl,backups,logs}
sudo mkdir -p /mnt/nvme_data/postgres_data /mnt/nvme_data/redis_data

# Ownership
sudo chown -R deploy:deploy /mnt/nvme_data
# Postgres inside container runs as uid 70 (postgres:alpine) — will chown on first run

# --- Project directory ---
mkdir -p /home/deploy/careai
mkdir -p /home/deploy/careai/hdd_storage/{careai,careai_logs,ollama/models}

echo "[remote] ✓ Docker + directory layout complete"
REMOTE_EOF
)"

step "Running Docker install on Hetzner"
ssh_hetzner "bash -s" <<< "${REMOTE_SCRIPT}"

# --- Verify docker works as deploy (without sudo) ---
# Need a fresh SSH session to pick up the new group membership
step "Verifying docker works as deploy (without sudo)"
if ssh_hetzner "docker version --format '{{.Server.Version}}'" 2>/dev/null; then
  ok "Docker works for deploy (no sudo needed)"
else
  warn "Docker may need one more SSH session to pick up group change"
  warn "That's fine — the next phase will work correctly."
fi

# --- Show layout ---
step "Directory layout on Hetzner"
ssh_hetzner "ls -la /mnt/nvme_data && echo && ls -la /home/deploy/careai"

banner "PHASE 02 COMPLETE"
mark_done "02"
info "Ready to run: ./03-ghcr-pull.sh"
