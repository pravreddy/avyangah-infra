#!/usr/bin/env bash
# =========================================================================
# Verify auto-renewal is set up correctly.
# Does a DRY-RUN renewal (doesn't actually renew) and shows timer status.
# Run on Hetzner as: sudo ./test-renewal.sh
# =========================================================================

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

echo "=== 1. Dry-run renewal (does NOT actually renew) ==="
echo "    This tests that the renewal would succeed when the certs get close to expiry."
echo
certbot renew --dry-run

echo
echo "=== 2. Systemd timer status ==="
if systemctl list-timers 2>/dev/null | grep -q certbot; then
  systemctl list-timers | head -1    # header
  systemctl list-timers | grep -i certbot
else
  echo "⚠ No certbot timer found. Enable with:"
  echo "    sudo systemctl enable --now certbot.timer"
fi

echo
echo "=== 3. Certbot service config ==="
systemctl status certbot.timer --no-pager 2>/dev/null | head -12 || echo "(timer not active yet)"

echo
echo "=== 4. Current cert expiry dates ==="
for name in careaisoftware.co.uk signsimple.co.uk; do
  live_dir="/etc/letsencrypt/live/${name}"
  if [[ -d "${live_dir}" ]]; then
    echo "--- ${name} ---"
    openssl x509 -in "${live_dir}/fullchain.pem" -noout -subject -dates
    echo
  else
    echo "--- ${name} ---  (no cert found — did you run 01-issue-certs.sh?)"
  fi
done

echo
echo "=== 5. Renewal hook installed? ==="
HOOK="/etc/letsencrypt/renewal-hooks/deploy/careai-signsimple-reload.sh"
if [[ -x "${HOOK}" ]]; then
  echo "  ✓ ${HOOK}"
else
  echo "  ✗ ${HOOK} missing or not executable — re-run 01-issue-certs.sh"
fi

echo
echo "=== ✓ If dry-run above said 'Congratulations, all renewals succeeded' — you're golden ==="
echo "    Automatic renewal will happen ~30 days before each cert expires."
