#!/usr/bin/env bash
set -euo pipefail

source ./env
docker compose run --rm --entrypoint "/bin/sh" certbot -c "
    rm -Rf /etc/letsencrypt/live/* \
           /etc/letsencrypt/archive/* \
           /etc/letsencrypt/renewal/*
  "
