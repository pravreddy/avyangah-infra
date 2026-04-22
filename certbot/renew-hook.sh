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

CAREAI_DIR="/home/deploy/careai"

# Figure out which cert just renewed
case "${RENEWED_LINEAGE:-}" in
  */careaisoftware.co.uk)
    echo "[renew-hook] Care AI cert renewed → copying to fullchain.pem / privkey.pem"
    cp -L "${RENEWED_LINEAGE}/fullchain.pem" "${CAREAI_DIR}/ssl/fullchain.pem"
    cp -L "${RENEWED_LINEAGE}/privkey.pem"   "${CAREAI_DIR}/ssl/privkey.pem"
    chmod 644 "${CAREAI_DIR}/ssl/fullchain.pem"
    chmod 600 "${CAREAI_DIR}/ssl/privkey.pem"
    ;;
  */signsimple.co.uk)
    echo "[renew-hook] SignSimple cert renewed → copying to docsign-fullchain.pem / docsign-privkey.pem"
    cp -L "${RENEWED_LINEAGE}/fullchain.pem" "${CAREAI_DIR}/ssl/docsign-fullchain.pem"
    cp -L "${RENEWED_LINEAGE}/privkey.pem"   "${CAREAI_DIR}/ssl/docsign-privkey.pem"
    chmod 644 "${CAREAI_DIR}/ssl/docsign-fullchain.pem"
    chmod 600 "${CAREAI_DIR}/ssl/docsign-privkey.pem"
    ;;
  *)
    echo "[renew-hook] Unknown lineage: ${RENEWED_LINEAGE:-<unset>} — skipping"
    exit 0
    ;;
esac

chown -R deploy:deploy "${CAREAI_DIR}/ssl/"

# Graceful nginx reload — no dropped connections
if docker exec careai-nginx nginx -s reload 2>&1; then
  echo "[renew-hook] ✓ Nginx reloaded with new certs"
else
  echo "[renew-hook] ✗ Nginx reload FAILED — manual intervention needed"
  exit 1
fi
