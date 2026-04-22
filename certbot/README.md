# Let's Encrypt Auto-Renewal for Hetzner

Manages SSL certs for `signsimple.co.uk` and `careaisoftware.co.uk` running in a Dockerised nginx on the Hetzner production box.

## Approach

- **HTTP-01 challenge via webroot** — certbot (on host) writes challenge files to a shared volume that nginx (in container) serves at `/.well-known/acme-challenge/`
- **Automatic renewal** via systemd timer (runs twice daily, renews when <30 days remain)
- **Zero-downtime** — nginx just reloads config, no restart

## Two SEPARATE certs

Your current setup uses two distinct certificates (not one SAN cert covering both):

| Cert file on host | Covers |
|---|---|
| `~/careai/ssl/fullchain.pem` + `privkey.pem` | `careaisoftware.co.uk`, `www.careaisoftware.co.uk` |
| `~/careai/ssl/docsign-fullchain.pem` + `docsign-privkey.pem` | `signsimple.co.uk`, `www.signsimple.co.uk` |

## Files

| File | When to run |
|---|---|
| `00-setup.sh` | **Once** — installs certbot, creates dirs, adds nginx config, restarts container |
| `01-issue-certs.sh` | **Once** — issues initial certs for both domains |
| `renew-hook.sh` | **Automatic** — called by certbot after successful renewal |
| `test-renewal.sh` | **On-demand** — dry-run renewal to prove auto-renewal works |

## First-time usage

```bash
# From your Mac — copy certbot/ to the Hetzner box
rsync -av certbot/ hetzner-prod:~/certbot/

# Then on Hetzner:
ssh hetzner-prod
cd ~/certbot
chmod +x *.sh

# ⚠️ Edit 01-issue-certs.sh and change EMAIL to your real address first!
vi 01-issue-certs.sh

sudo ./00-setup.sh          # one-time infra setup
sudo ./01-issue-certs.sh    # one-time cert issuance
sudo ./test-renewal.sh      # verify auto-renewal works
```

## Renewal schedule

- Debian's `certbot` package installs a **systemd timer** (`certbot.timer`) by default
- Runs **twice daily** at randomised minutes
- Certbot renews any cert with **<30 days remaining**; skips others
- After renewal, `renew-hook.sh` copies new certs to `~/careai/ssl/` and reloads nginx
- **No action needed from you** once set up

## Verify it's working

```bash
# Check expiry dates
ssh hetzner-prod 'sudo openssl x509 -in ~/careai/ssl/fullchain.pem         -noout -dates'
ssh hetzner-prod 'sudo openssl x509 -in ~/careai/ssl/docsign-fullchain.pem -noout -dates'

# Check timer status
ssh hetzner-prod 'systemctl list-timers | grep certbot'

# Dry-run renewal
ssh hetzner-prod 'sudo certbot renew --dry-run'
```

## Why not `certbot --nginx`?

The `certbot --nginx` plugin talks to a host-level `nginx` service via systemd. Your nginx runs **inside a Docker container**, so that plugin can't reach it. Webroot challenge works instead — certbot writes challenge files to disk, nginx container serves them via a read-only volume mount.

## What 00-setup.sh changes on the server

- Installs `certbot` (apt)
- Creates `/var/www/certbot` (webroot)
- Creates `~/careai/docker-compose.override.yml` to mount webroot into nginx
- Adds a `location /.well-known/acme-challenge/ { root /var/www/certbot; }` block to both nginx configs (idempotent — skips if already present)
- Recreates nginx container to pick up the new volume mount
- Tests that both domains serve `/.well-known/` correctly before you issue real certs

All changes are reversible; the setup script backs up nginx configs before editing.
