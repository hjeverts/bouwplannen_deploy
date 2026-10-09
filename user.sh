#!/usr/bin/env bash
# Accounts beheren voor Bouwplannen. Draait de opdracht in de API-container, dus .NET is niet nodig.
#
#   ./user.sh add <naam> [--admin] [--name "Volledige naam"]   account aanmaken (vraagt wachtwoord)
#   ./user.sh passwd <naam>                                    nieuw wachtwoord (logt overal uit)
#   ./user.sh list                                             alle accounts
#   ./user.sh admin <naam> on|off                              beheerdersrechten
#   ./user.sh disable <naam> | enable <naam>                   blokkeren of weer toestaan
#   ./user.sh logout <naam>                                    overal uitloggen
#
# Het eerste account wordt beheerder. Wijzigingen werken direct, zonder herstart.
# Wachtwoord zonder te typen (bijvoorbeeld in een script): BOUWPLANNEN_PASSWORD=… ./user.sh add piet

set -Eeuo pipefail

DEPLOY_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$DEPLOY_DIR"

die() {
  echo "FOUT: $*" >&2
  exit 1
}

if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  [[ $# -eq 0 ]] && exit 2
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "'docker' is niet geïnstalleerd."
[[ -f .env ]] || die "Nog niet geïnstalleerd: draai eerst ./update.sh."
docker image inspect bouwplannen-api:latest >/dev/null 2>&1 || die "De API is nog niet gebouwd: draai eerst ./update.sh."

# Interactief (met verborgen invoer van het wachtwoord) als er een terminal is; anders zonder.
tty_flag="-T"
[[ -t 0 && -t 1 ]] && tty_flag=""

# --no-deps: de webserver hoeft hiervoor niet te starten. Zelfde gebruiker en datamap als de API.
# shellcheck disable=SC2086 # $tty_flag is bewust leeg of één optie
exec docker compose run --rm --no-deps $tty_flag api users "$@"
