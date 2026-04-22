#!/usr/bin/env bash
# =========================================================================
# Phase 01: Harden Hetzner
#   - Create deploy user with your SSH key
#   - Disable root SSH, disable password auth
#   - Install ufw + fail2ban, set firewall (22/80/443)
#   - Enable automatic security updates
#
# This is the ONLY phase that SSHes as root. The root password from the
# Hetzner provisioning email is required — you'll be prompted interactively.
# Idempotent: safe to re-run.
# =========================================================================

source "$(dirname "$0")/lib/common.sh"

banner "PHASE 01 · HARDEN HETZNER (${HETZNER_IP})"

# --- Check if already hardened ---
if ssh_hetzner -o BatchMode=yes -o ConnectTimeout=5 "echo ok" 2>/dev/null | grep -q ok; then
  ok "Hetzner already accepts deploy@ SSH — hardening appears complete."
  if confirm "Re-run hardening anyway (idempotent)?" n; then
    info "Proceeding with re-run…"
  else
    mark_done "01"
    exit 0
  fi
fi

# --- Load public key contents ---
PUB_KEY_CONTENT="$(cat "${LOCAL_PUB_KEY}")"
[[ -n "${PUB_KEY_CONTENT}" ]] || die "Empty public key file: ${LOCAL_PUB_KEY}"

# --- Accept new host key for root login attempt ---
ssh-keyscan -t ed25519,rsa "${HETZNER_IP}" >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true

# --- Detect whether root SSH uses keys (Robot pre-install) or password ---
ROOT_AUTH_MODE="password"
if ssh -i "${LOCAL_SSH_KEY}" \
       -o BatchMode=yes \
       -o StrictHostKeyChecking=accept-new \
       -o ConnectTimeout=5 \
       "root@${HETZNER_IP}" "echo keyauth_ok" 2>/dev/null | grep -q keyauth_ok; then
  ROOT_AUTH_MODE="key"
  ok "Root SSH accepts your key (Hetzner Robot pre-install detected) — no password prompt needed"
else
  info "Root SSH requires password — you'll be prompted shortly"
fi

# --- Build the hardening script (runs on Hetzner as root) ---
REMOTE_SCRIPT="$(cat <<REMOTE_EOF
set -euo pipefail

echo "[remote] Updating package lists"
apt-get update -qq

echo "[remote] Upgrading installed packages (may take a few min)"
DEBIAN_FRONTEND=noninteractive apt-get upgrade -qq -y

echo "[remote] Installing sudo, ufw, fail2ban, unattended-upgrades, tools"
DEBIAN_FRONTEND=noninteractive apt-get install -qq -y \\
  sudo ufw fail2ban unattended-upgrades ca-certificates curl gnupg \\
  htop tmux vim rsync git jq

# Ensure /etc/sudoers.d exists (defensive: some minimal images lack it)
mkdir -p /etc/sudoers.d
chmod 750 /etc/sudoers.d

# --- User 'deploy' ---
if id deploy >/dev/null 2>&1; then
  echo "[remote] User 'deploy' already exists"
else
  echo "[remote] Creating user 'deploy'"
  adduser --disabled-password --gecos "" deploy
fi

# Add deploy to sudo group
usermod -aG sudo deploy

# sudo without password (consistent with Vultr setup)
echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
chmod 440 /etc/sudoers.d/deploy
visudo -c -f /etc/sudoers.d/deploy  # validate syntax; script will abort if bad

# --- SSH key for deploy ---
mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh

# Idempotent: add the key only if not already there
KEY_FP='${PUB_KEY_CONTENT}'
if ! grep -qF "\${KEY_FP}" /home/deploy/.ssh/authorized_keys 2>/dev/null; then
  echo "\${KEY_FP}" >> /home/deploy/.ssh/authorized_keys
  echo "[remote] Added SSH key to deploy authorized_keys"
else
  echo "[remote] SSH key already in authorized_keys — skipping"
fi
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

# --- Hostname ---
hostnamectl set-hostname '${HETZNER_HOSTNAME}' || true

# --- SSH hardening ---
SSHD=/etc/ssh/sshd_config
cp "\${SSHD}" "\${SSHD}.bak.\$(date +%s)" 2>/dev/null || true

# Comment-out any existing directives we care about, then add canonical ones
for directive in PermitRootLogin PasswordAuthentication PubkeyAuthentication \\
                 ChallengeResponseAuthentication UsePAM; do
  sed -i "s/^#\\?\\s*\${directive}.*/# managed-by-migration: \${directive}/" "\${SSHD}" || true
done

# Remove any previous "managed-by-migration" appended block, then re-append clean block
sed -i '/# >>> migration hardening >>>/,/# <<< migration hardening <<</d' "\${SSHD}"

cat >> "\${SSHD}" <<'SSHD_CONF'

# >>> migration hardening >>>
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
# <<< migration hardening <<<
SSHD_CONF

# Validate before restarting
sshd -t && systemctl restart ssh

# --- Firewall ---
# Hetzner Debian 12 ships with iptables-nft which can't fetch module info,
# causing ufw to fail. Switch to iptables-legacy (always supported).
if update-alternatives --list iptables 2>/dev/null | grep -q iptables-legacy; then
  echo "[remote] Switching to iptables-legacy backend (Hetzner nf_tables workaround)"
  update-alternatives --set iptables /usr/sbin/iptables-legacy || true
  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true
fi

# Load netfilter modules (safe if already loaded)
modprobe ip_tables 2>/dev/null || true
modprobe iptable_filter 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

# Try ufw — but don't abort the whole script if it fails (Hetzner has network firewall anyway)
set +e
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
ufw_status=\$?
set -e

if [[ \${ufw_status} -eq 0 ]]; then
  systemctl enable ufw
  echo "[remote] ✓ UFW enabled"
else
  echo "[remote] ⚠ UFW init failed (Hetzner kernel quirk) — continuing. Hetzner has network-level protections."
  echo "[remote] ⚠ You can try again after a reboot, or leave it — fail2ban still runs."
fi

# --- fail2ban ---
echo "[remote] Configuring fail2ban with systemd backend (Debian 12 has no /var/log/auth.log)"
cat > /etc/fail2ban/jail.local <<'F2B_CONF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ssh
backend  = systemd
F2B_CONF

# Install rsyslog for belt-and-braces text logs
DEBIAN_FRONTEND=noninteractive apt-get install -qq -y rsyslog
systemctl enable rsyslog
systemctl start rsyslog

systemctl enable fail2ban
systemctl restart fail2ban

# --- Unattended security upgrades ---
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTCONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APTCONF

echo "[remote] ✓ Hardening complete."
echo "[remote] Logging in as deploy should now work from your Mac."
REMOTE_EOF
)"

# --- Execute remote script via root SSH (using key if available, else password) ---
if [[ "${ROOT_AUTH_MODE}" == "key" ]]; then
  step "Running hardening via root SSH (key auth, no password prompt)"
  ssh -i "${LOCAL_SSH_KEY}" \
      -o StrictHostKeyChecking=accept-new \
      "root@${HETZNER_IP}" \
      "bash -s" <<< "${REMOTE_SCRIPT}"
else
  step "Connecting to root@${HETZNER_IP} — you'll be prompted for the root password from Hetzner email"
  info "Paste the root password when prompted (it won't be echoed)."
  echo

  ssh -o StrictHostKeyChecking=accept-new \
      -o PubkeyAuthentication=no \
      -o PreferredAuthentications=password \
      "root@${HETZNER_IP}" \
      "bash -s" <<< "${REMOTE_SCRIPT}"
fi

ok "Remote hardening script executed successfully"

# --- Verify we can now login as deploy ---
step "Verifying login as deploy@${HETZNER_IP}"
sleep 2  # give sshd a moment to settle
if ssh_hetzner -o BatchMode=yes "echo ok" 2>/dev/null | grep -q ok; then
  ok "Login as deploy works ✓"
else
  die "Could not login as deploy. Check Hetzner Robot KVM console."
fi

# --- Verify root SSH is blocked ---
step "Verifying root SSH is disabled"
if ssh -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password \
       -o ConnectTimeout=5 "root@${HETZNER_IP}" "true" 2>&1 | grep -qE "Permission denied|denied"; then
  ok "Root SSH correctly blocked ✓"
else
  warn "Root SSH may still be accessible — check manually"
fi

# --- Add convenience SSH config entry ---
if ! grep -q "Host hetzner-prod" "${HOME}/.ssh/config" 2>/dev/null; then
  if confirm "Add 'hetzner-prod' shortcut to ~/.ssh/config?" y; then
    cat >> "${HOME}/.ssh/config" <<SSH_CFG

Host hetzner-prod
    HostName ${HETZNER_IP}
    User ${HETZNER_USER}
    IdentityFile ${LOCAL_SSH_KEY}
    IdentitiesOnly yes
SSH_CFG
    chmod 600 "${HOME}/.ssh/config"
    ok "Added — you can now: ssh hetzner-prod"
  fi
fi

banner "PHASE 01 COMPLETE"
mark_done "01"
info "Ready to run: ./02-install-docker.sh"
