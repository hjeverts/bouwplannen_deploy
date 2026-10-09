#!/usr/bin/env bash
# Zet de nginx-config voor Bouwplannen op de server en regelt het certificaat.
#
#   sudo host-nginx/install.sh bouwplannen.jouwdomein.nl
#   sudo host-nginx/install.sh bouwplannen.jouwdomein.nl --no-certbot   (certificaat regel je zelf)
#   host-nginx/install.sh bouwplannen.jouwdomein.nl --print             (alleen de config tonen)
#
# Leest WEB_PORT uit ../.env. Vraagt een Let's Encrypt-certificaat aan met certbot als dat er nog
# niet is, test de config (nginx -t) en herlaadt nginx alleen als de test slaagt.

set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DEPLOY_DIR="$(dirname "$HERE")"

DOMAIN="${1:-}"
MODE="install"
CERTBOT=1
shift || true
for arg in "$@"; do
  case "$arg" in
    --print) MODE="print" ;;
    --no-certbot) CERTBOT=0 ;;
    *)
      echo "Onbekende optie: $arg" >&2
      exit 2
      ;;
  esac
done

die() {
  echo "FOUT: $*" >&2
  exit 1
}

[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] ||
  die "Geef je domein op, bijvoorbeeld: sudo $0 bouwplannen.jouwdomein.nl"

PORT=8380
if [[ -f "$DEPLOY_DIR/.env" ]]; then
  value="$(sed -n 's/^WEB_PORT=\([0-9]\{1,5\}\)[[:space:]]*$/\1/p' "$DEPLOY_DIR/.env" | tail -n 1)"
  [[ -n "$value" ]] && PORT="$value"
fi

# Te overschrijven voor tests of afwijkende installaties.
NGINX_DIR="${NGINX_DIR:-/etc/nginx}"
CERT_DIR="${CERT_DIR:-/etc/letsencrypt/live/$DOMAIN}"
NGINX_BIN="${NGINX_BIN:-nginx}"

render() {
  local filter=(cat)
  # Zonder IPv6 op de server weigert nginx "listen [::]:…": laat die regels dan weg.
  [[ -f /proc/net/if_inet6 && "${NO_IPV6:-0}" != "1" ]] || filter=(grep -v 'listen \[::\]')
  sed -e "s|{{DOMAIN}}|$DOMAIN|g" -e "s|{{PORT}}|$PORT|g" -e "s|{{CERT_DIR}}|$CERT_DIR|g" "$HERE/bouwplannen.conf.template" | "${filter[@]}"
}

if [[ "$MODE" == "print" ]]; then
  render
  exit 0
fi

[[ -w "$NGINX_DIR" ]] || die "Geen schrijfrechten op $NGINX_DIR. Draai dit script met sudo."
command -v "$NGINX_BIN" >/dev/null 2>&1 || die "nginx is niet geïnstalleerd."

if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
  if [[ $CERTBOT -eq 0 ]]; then
    die "Geen certificaat in $CERT_DIR. Vraag er een aan, of laat --no-certbot weg."
  fi
  command -v certbot >/dev/null 2>&1 || die "certbot ontbreekt. Installeer met: sudo apt install certbot python3-certbot-nginx"
  echo "Certificaat aanvragen voor $DOMAIN (poort 80 moet vanaf internet naar deze server wijzen)…"
  # --nginx gebruikt de draaiende nginx voor de controle; certbot verlengt daarna automatisch.
  certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring ||
    die "Certificaat aanvragen mislukt. Klopt de DNS van $DOMAIN en is poort 80 bereikbaar?"
fi

TARGET="$NGINX_DIR/sites-available/bouwplannen.conf"
LINK="$NGINX_DIR/sites-enabled/bouwplannen.conf"
BACKUP=""
mkdir -p "$NGINX_DIR/sites-available" "$NGINX_DIR/sites-enabled"
if [[ -f "$TARGET" ]]; then
  BACKUP="$TARGET.bak.$(date +%Y%m%d%H%M%S)"
  cp "$TARGET" "$BACKUP"
fi
render >"$TARGET"
ln -sfn "$TARGET" "$LINK"

if ! "$NGINX_BIN" -t 2>&1; then
  # Niet herladen met een kapotte config: vorige versie terugzetten.
  if [[ -n "$BACKUP" ]]; then mv "$BACKUP" "$TARGET"; else rm -f "$TARGET" "$LINK"; fi
  die "nginx -t faalt; de vorige situatie is teruggezet. Zie de melding hierboven."
fi
[[ -n "$BACKUP" ]] && rm -f "$BACKUP"

if [[ "${NO_RELOAD:-0}" != "1" ]]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    "$NGINX_BIN" -s reload
  fi
fi

echo "Klaar: https://$DOMAIN stuurt door naar 127.0.0.1:$PORT."
echo "Open https://$DOMAIN en log in met een account (aanmaken met: ./user.sh add <naam>)."
