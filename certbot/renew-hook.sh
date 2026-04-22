#!/usr/bin/env bash
# =========================================================================
# Certbot renewal hook — runs AFTER a successful renewal.
# Installed to: /etc/letsencrypt/renewal-hooks/deploy/careai-signsimple-reload.sh
# Called automatically by certbot when any cert is renewed.
#
# Certbot sets RENEWED_LINEAGE to the live dir of the just-renewed cert,
# e.g. /etc/letsencrypt/live/careaisoftware.co.uk
# We use this to figure out WHICH cert renewed and copy it to the right
# filename in ~/careai/ssl/, then reload nginx.
# =========================================================================

set -euo pipefail

# Careful: /etc/nginx/ssl/ inside the nginx container is bind-mounted from
# /mnt/nvme_data/ssl/ on the host. We write there, not to ~/careai/ssl/.
CAREAI_DIR="/home/deploy/careai"
SSL_DIR="/mnt/nvme_data/ssl"

# Figure out which cert just renewed
case "${RENEWED_LINEAGE:-}" in
  */careaisoftware.co.uk)
    echo "[renew-hook] Care AI cert renewed → copying to fullchain.pem / privkey.pem"
    cp -L "${RENEWED_LINEAGE}/fullchain.pem" "${SSL_DIR}/fullchain.pem"
    cp -L "${RENEWED_LINEAGE}/privkey.pem"   "${SSL_DIR}/privkey.pem"
    chmod 644 "${SSL_DIR}/fullchain.pem"
    chmod 600 "${SSL_DIR}/privkey.pem"
    ;;
  */signsimple.co.uk)
    echo "[renew-hook] SignSimple cert renewed → copying to docsign-fullchain.pem / docsign-privkey.pem"
    cp -L "${RENEWED_LINEAGE}/fullchain.pem" "${SSL_DIR}/docsign-fullchain.pem"
    cp -L "${RENEWED_LINEAGE}/privkey.pem"   "${SSL_DIR}/docsign-privkey.pem"
    chmod 644 "${SSL_DIR}/docsign-fullchain.pem"
    chmod 600 "${SSL_DIR}/docsign-privkey.pem"
    ;;
  *)
    echo "[renew-hook] Unknown lineage: ${RENEWED_LINEAGE:-<unset>} — skipping"
    exit 0
    ;;
esac

chown -R deploy:deploy "${SSL_DIR}/"

# Graceful nginx reload — no dropped connections
if docker exec careai-nginx nginx -s reload 2>&1; then
  echo "[renew-hook] ✓ Nginx reloaded with new certs"
else
  echo "[renew-hook] ✗ Nginx reload FAILED — manual intervention needed"
  exit 1
fi
