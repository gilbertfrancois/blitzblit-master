# blitzblit-master

Shared **nginx reverse proxy + Let's Encrypt certbot** for every
`*.blitzblit.com` subdomain. Each app (digitizer, gallery, the main Flask
site, movie-downloader, ...) lives in its own repo and joins the shared
`blitzblit-net` docker network created by this stack.

## How it fits together

```
public internet ──HTTPS──▶ master nginx :443       ◀── owns every LE cert
                              │
                              ▼ proxy_pass (HTTP)
                          blitzblit-net (private docker network)
                              │
            ┌─────────────────┼──────────────────┬─────────────────┐
            ▼                 ▼                  ▼                 ▼
       digitizer:80     gallery:80       blitzblit-com:80   movie-downloader:80
       (own repo)       (own repo)       (own repo)         (own repo)
```

- **Master** terminates TLS, holds every cert under `./letsencrypt/conf/`,
  proxies plain HTTP to the right upstream by hostname.
- **Each app** ships its own tiny container (e.g. `nginx:alpine` for static
  React, `gunicorn` for Flask) listening on internal port 80. The app's
  `docker-compose.yml` joins `blitzblit-net` with `external: true`.
- No app needs a cert, opens 443, or runs its own certbot.

## Enabling / disabling sites (Debian-style split)

`nginx/sites-available/` holds the per-site `.conf` files. `nginx/sites-enabled/`
holds **relative symlinks** to whichever ones are active. nginx only loads
`sites-enabled/*.conf`.

**Enable a site**

```sh
cd nginx/sites-enabled
ln -s ../sites-available/<domain>.conf .
# add <domain> to DOMAINS in env and to domains: in ansible/group_vars/all.yml
```

**Disable a site (temporary)**

```sh
rm nginx/sites-enabled/<domain>.conf
# also drop it from DOMAINS in env / domains: in group_vars
```

The file in `sites-available/` is untouched, so re-enabling is one symlink
and an env edit away.

## Adding a new subdomain

1. Copy `nginx/sites-available/_template.conf.example` to
   `nginx/sites-available/<domain>.conf`; replace `{{DOMAIN}}` and `{{UPSTREAM}}`.
2. Enable it: `cd nginx/sites-enabled && ln -s ../sites-available/<domain>.conf .`
3. Add the domain to `domains:` in `ansible/group_vars/all.yml`.
4. From your laptop: `cd ansible && ansible-playbook playbook.yml`
5. On the server: `source ./env && ./init_letsencrypt.sh` (idempotent — only
   issues the new cert and reloads nginx).
6. Deploy the app's own repo; its compose joins `blitzblit-net`, exposes the
   service name on port 80, and master nginx picks it up.

## First-time deploy

From your laptop:

```bash
cd ansible
ansible-playbook playbook.yml
```

On the server (after DNS for every domain points here and ports 80/443 are
open in the security group):

```bash
ssh -i ~/.dotfiles_secret/ssh_keys/blitzblit-3.pem ubuntu@msx-digitizer.blitzblit.com

cd ~/sites/blitzblit-master
source ./env
./init_letsencrypt.sh --staging       # dry-run first
./init_letsencrypt.sh                 # real certs
./start.sh
```

After that, renewals are automatic every 12 h via the certbot sidecar
(nginx reloads every 6 h to pick up the renewed certs).

## File layout

```
blitzblit-master/
├── docker-compose.yml          nginx + certbot only
├── env                         DOMAINS list, ACME_EMAIL
├── nginx/
│   ├── nginx_prod.conf         main http{}, includes sites-enabled/*.conf
│   ├── sites-available/        every per-site config that *could* be served
│   │   ├── _template.conf.example
│   │   ├── msx-digitizer.blitzblit.com.conf
│   │   ├── msx-digitizer-gallery.blitzblit.com.conf
│   │   ├── www.blitzblit.com.conf
│   │   └── movie-downloader.blitzblit.com.conf
│   └── sites-enabled/          relative symlinks to the active subset
├── letsencrypt/                gitignored — populated by init script
│   ├── conf/                   /etc/letsencrypt inside containers
│   └── www/                    ACME HTTP-01 webroot
├── init_letsencrypt.sh         idempotent — adds new domains, skips existing
├── start.sh                    docker compose up -d
├── stop.sh                     docker compose down
└── ansible/                    playbook for fresh-host provisioning
```

## Why each design choice

- **Debian-style `sites-available/` + `sites-enabled/`** under `nginx/`, with
  `include /etc/nginx/sites-enabled/*.conf` in the main config. Enabling a site
  is one symlink; disabling is one `rm`; no edits to other configs.
- **External docker network `blitzblit-net`**. App repos are fully decoupled
  — none of them need to know about each other's compose files or volumes.
- **TLS termination only at master**. Apps stay HTTP-only internally; one
  certbot serves all domains. The internal HTTP hop never crosses the public
  network, so encryption inside the docker bridge would buy nothing.
- **No app containers in master's compose**. Master can be rolled back,
  upgraded, or restarted independently of any individual site.
