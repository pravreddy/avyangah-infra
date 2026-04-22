# Phase 07 · DNS Cutover (Manual)

DNS is the one thing we don't automate — Spaceship & Namecheap don't have convenient CLIs, and doing this by hand is safer anyway (human eyes on the change, easy to revert).

## Before you start

- [ ] Phase 06 complete — stack is running on Hetzner
- [ ] You've tested both sites via `/etc/hosts` override (see Phase 06 output) and they work
- [ ] DNS TTLs are already lowered to ≤ 300 seconds (check: `dig +noall +answer A signsimple.co.uk` — second column is TTL)

If TTLs are still high, lower them first, **wait 1 hour** for old records to expire, then cut over.

## New IP to set

```
A record  @  →  88.99.167.49
A record  www  →  88.99.167.49
AAAA      @  →  2a01:4f8:10a:3759::2   (optional)
AAAA      www  →  2a01:4f8:10a:3759::2  (optional)
```

---

## 1. signsimple.co.uk — Spaceship

1. Sign in at **https://spaceship.com**
2. Navigate: **Domains → signsimple.co.uk → Advanced DNS** (or DNS records)
3. Find the A record for `@` (host = `@` or blank, meaning root)
4. Change **Value / IP** from `45.32.177.231` → `88.99.167.49`
5. Ensure **TTL is 300 seconds** (5 min)
6. **Save**
7. Repeat for `www` (same 88.99.167.49)
8. Optional — add AAAA records for IPv6: `@` → `2a01:4f8:10a:3759::2`

## 2. careaisoftware.co.uk — Namecheap

1. Sign in at **https://namecheap.com**
2. Navigate: **Domain List → careaisoftware.co.uk → Manage → Advanced DNS**
3. Find the A record for `@`
4. Change **Value** from `45.32.177.231` → `88.99.167.49`
5. Ensure **TTL is 300 seconds** (or custom "5 min")
6. **Save** (green checkmark)
7. Repeat for `www` A record

---

## 3. Verify propagation

From your Mac, run repeatedly until both return the Hetzner IP:

```bash
# Force bypass local DNS cache by querying specific public resolvers
dig @1.1.1.1 +short signsimple.co.uk
dig @1.1.1.1 +short careaisoftware.co.uk
dig @8.8.8.8 +short signsimple.co.uk
dig @8.8.8.8 +short careaisoftware.co.uk
```

Typical propagation on a 300s TTL: **2–10 minutes**. On "Automatic" TTL it can be 30 min or more.

Useful third-party propagation checker: https://www.whatsmydns.net/

---

## 4. Once DNS is live on Hetzner

Run the post-cutover verification:

```bash
./08-verify-and-park.sh
```

This does HTTPS smoke tests via the real domain (no `/etc/hosts` tricks) and prepares the Vultr box for safe parking.

---

## If something goes wrong — rollback

```bash
./rollback.sh
```

This reverts the DNS instructions (it can't actually change DNS, but walks you through reverting the registrar records) and brings the Vultr stack back up if you'd already stopped it.
