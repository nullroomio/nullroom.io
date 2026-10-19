#!/bin/sh
# Certbot deploy hook for the coturn host.
# Installed at /etc/letsencrypt/renewal-hooks/deploy/coturn.sh (chmod 755).
#
# Certbot renews turn.nullroom.io under /etc/letsencrypt/live/, but coturn reads
# the cert from /var/lib/coturn/certs (mounted read-only, see config/deploy.yml)
# and only loads it at startup. Copy the renewed files over and restart coturn.
set -e
install -m 644 /etc/letsencrypt/live/turn.nullroom.io/fullchain.pem /var/lib/coturn/certs/fullchain.pem
install -m 600 /etc/letsencrypt/live/turn.nullroom.io/privkey.pem  /var/lib/coturn/certs/privkey.pem
docker restart nullroom-coturn
