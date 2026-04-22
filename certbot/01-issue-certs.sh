#!/usr/bin/env bash
# =========================================================================
# Issue fresh Let's Encrypt certs for both domains.
# Run on Hetzner as: sudo ./01-issue-certs.sh
# Idempotent: uses --keep-until-expiring, so re-runs skip if cert is young.
# =========================================================================

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

# ─── EDIT THIS ───
EMAIL="praveen.moj@gmail.com"   # ← CHANGE to your real email (LE sends expiry warnings here if auto-renewal fails)
# ─────────────────

CAREAI_DIR="/home/deploy/careai"
SSL_DIR="/mnt/nvme_data/ssl"   # actual cert location — bind-mounted into nginx container at /etc/nginx/ssl/
WEBROOT="/var/www/certbot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Safety check
if [[ "${EMAIL}" == "praveen@avyangah.com" ]]; then
  echo "⚠  EMAIL still set to placeholder. Edit 01-issue-certs.sh first."
  echo "   Change EMAIL=\"...\" at the top to your real email address."
  exit 1
fi

echo "=== Issuing cert for Care AI (careaisoftware.co.uk, www.careaisoftware.co.uk) ==="
certbot certonly \
  --webroot \
  --webroot-path "${WEBROOT}" \
  --email "${EMAIL}" \
  --agree-tos \
  --no-eff-email \
  --keep-until-expiring \
  --non-interactive \
  --expand \
  -d careaisoftware.co.uk \
  -d www.careaisoftware.co.uk

echo
echo "=== Issuing cert for SignSimple (signsimple.co.uk, www.signsimple.co.uk) ==="
certbot certonly \
  --webroot \
  --webroot-path "${WEBROOT}" \
  --email "${EMAIL}" \
  --agree-tos \
  --no-eff-email \
  --keep-until-expiring \
  --non-interactive \
  --expand \
  -d signsimple.co.uk \
  -d www.signsimple.co.uk

echo
echo "=== Copying certs into ${SSL_DIR}/ ==="
echo "  (this is the directory bind-mounted into careai-nginx as /etc/nginx/ssl/)"

# Care AI uses: fullchain.pem + privkey.pem
cp -L /etc/letsencrypt/live/careaisoftware.co.uk/fullchain.pem "${SSL_DIR}/fullchain.pem"
cp -L /etc/letsencrypt/live/careaisoftware.co.uk/privkey.pem   "${SSL_DIR}/privkey.pem"

# SignSimple uses: docsign-fullchain.pem + docsign-privkey.pem
cp -L /etc/letsencrypt/live/signsimple.co.uk/fullchain.pem     "${SSL_DIR}/docsign-fullchain.pem"
cp -L /etc/letsencrypt/live/signsimple.co.uk/privkey.pem       "${SSL_DIR}/docsign-privkey.pem"

chown -R deploy:deploy "${SSL_DIR}/"
chmod 644 "${SSL_DIR}/"*fullchain.pem
chmod 600 "${SSL_DIR}/"*privkey.pem

echo
echo "=== Installing renew-hook.sh to auto-copy certs on future renewals ==="
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cp "${SCRIPT_DIR}/renew-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/careai-signsimple-reload.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/careai-signsimple-reload.sh
echo "  installed: /etc/letsencrypt/renewal-hooks/deploy/careai-signsimple-reload.sh"

echo
echo "=== Reloading nginx to pick up new certs ==="
sudo -u deploy docker exec careai-nginx nginx -s reload

echo
echo "=== Final verification ==="
for cert in fullchain.pem docsign-fullchain.pem; do
  echo "--- ${cert} ---"
  openssl x509 -in "${SSL_DIR}/${cert}" -noout -subject -dates
  echo
done

echo
echo "=== Systemd timer for auto-renewal ==="
systemctl list-timers | grep -i certbot || echo "  (timer will activate at next boot or after package install)"
systemctl is-active certbot.timer >/dev/null 2>&1 \
  && echo "  ✓ certbot.timer is active" \
  || echo "  ⚠ certbot.timer is not active — run: sudo systemctl enable --now certbot.timer"

echo
echo "=== ✓ DONE ==="
echo
echo "Next: sudo ./test-renewal.sh  (verify automation works)"
