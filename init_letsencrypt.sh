#!/usr/bin/env bash
# One-time Let's Encrypt bootstrap for every domain listed in $DOMAINS.
#
# Usage:
#     source ./env
#     ./init_letsencrypt.sh             # real certs
#     ./init_letsencrypt.sh --staging   # dry-run against LE staging first
#
# Adding a new domain after this script has already run:
#     1. Append the domain to DOMAINS in env (and add nginx/sites/<domain>.conf).
#     2. source ./env
#     3. ./init_letsencrypt.sh  (answer "y" when prompted; existing certs are
#                                preserved — only the new one is requested).
#
# The certbot sidecar in docker-compose.yml handles renewals after bootstrap.

set -euo pipefail
source ./env

: "${DOMAINS:?source env first}"
: "${ACME_EMAIL:?source env first}"

compose() { docker compose "$@"; }

# shellcheck disable=SC2206  # word-splitting on DOMAINS is intentional
domains=(${DOMAINS})
data_path="./letsencrypt"
staging=0
for arg in "$@"; do
    [ "$arg" = "--staging" ] && staging=1
done

if [ -d "$data_path/conf/live" ] && [ "$(ls -A "$data_path/conf/live" 2>/dev/null | grep -v '^README$' | head -c1)" ]; then
    read -r -p "Existing certificates found in $data_path/conf/live. Continue? Already-issued domains are kept, only missing ones will be requested. (y/N) " reply
    case "$reply" in
    y | Y) ;;
    *)
        echo "Aborted."
        exit 0
        ;;
    esac
fi

echo "### Creating bind-mount directories"
mkdir -p "$data_path/conf" "$data_path/www"

# 1. Dummy self-signed certs (only for domains that don't already have one) so
#    nginx can start with the SSL server blocks present in sites/*.conf.
for domain in "${domains[@]}"; do
    if [ -e "$data_path/conf/live/$domain/fullchain.pem" ]; then
        echo "### Skipping dummy for $domain (real cert already present)"
        continue
    fi
    echo "### Creating dummy certificate for $domain"
    path="/etc/letsencrypt/live/$domain"
    compose run --rm --entrypoint "/bin/sh" certbot -c "
        mkdir -p '$path' &&
        openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
            -keyout '$path/privkey.pem' \
            -out    '$path/fullchain.pem' \
            -subj '/CN=localhost'
    "
done

# 2. Bring nginx up so it can serve the ACME HTTP-01 challenge on port 80.
echo "### Starting nginx"
compose up --force-recreate -d nginx

# 3. Request real certs only for domains that don't already have one.
staging_arg=""
[ "$staging" -eq 1 ] && staging_arg="--staging"

for domain in "${domains[@]}"; do
    if [ -L "$data_path/conf/live/$domain/fullchain.pem" ]; then
        echo "### Skipping certbot for $domain (real cert already present)"
        continue
    fi
    echo "### Removing dummy certificate for $domain"
    compose run --rm --entrypoint "/bin/sh" certbot -c "
        rm -Rf /etc/letsencrypt/live/$domain \
               /etc/letsencrypt/archive/$domain \
               /etc/letsencrypt/renewal/$domain.conf
    "
    echo "### Requesting Let's Encrypt certificate for $domain"
    compose run --rm --entrypoint "/bin/sh" certbot -c "
        certbot certonly --webroot -w /var/www/certbot \
            --email '$ACME_EMAIL' \
            -d '$domain' \
            --rsa-key-size 4096 \
            --agree-tos --no-eff-email \
            --non-interactive \
            $staging_arg
    "
done

# 4. Reload nginx so it loads the freshly issued certs.
echo "### Reloading nginx"
compose exec nginx nginx -s reload

echo
echo "Done. Auto-renewal will continue via the certbot sidecar."
