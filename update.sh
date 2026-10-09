#!/usr/bin/env bash
# Bouwplannen installeren of bijwerken: nieuwste code ophalen, images bouwen en de containers vernieuwen.
#
#   ./update.sh               alleen bouwen als er nieuwe commits zijn
#   ./update.sh --force       altijd opnieuw bouwen
#   ./update.sh --no-backup   geen back-up van de projectdata vooraf
#
# Veilig om vanuit cron te draaien: één run tegelijk, en als de nieuwe versie niet gezond opstart,
# zet het script de vorige versie terug.

set -Eeuo pipefail

DEPLOY_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$DEPLOY_DIR"

FORCE=0
BACKUP=1
SELF_UPDATE=1
ARGS=("$@")
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f | --force) FORCE=1 ;;
    --no-backup) BACKUP=0 ;;
    --no-self-update) SELF_UPDATE=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Onbekende optie: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() {
  log "FOUT: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Voorbereiding
# ---------------------------------------------------------------------------

for cmd in git docker flock; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is niet geïnstalleerd."
done
docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) ontbreekt."

# Eén run tegelijk (cron en handmatig kunnen elkaar anders in de weg zitten).
exec 9>"$DEPLOY_DIR/.update.lock"
flock -n 9 || die "update.sh draait al."

if [[ ! -f .env ]]; then
  cp .env.example .env
  log ".env aangemaakt uit .env.example (pas WEB_PORT daar aan als 8380 al in gebruik is)."
fi
set -a
# shellcheck disable=SC1091
source ./.env
set +a

if [[ ",${COMPOSE_PROFILES:-}," == *",https,"* && -z "${DOMAIN:-}" ]]; then
  die "COMPOSE_PROFILES bevat https, maar DOMAIN is leeg in .env."
fi

FRONTEND_REPO="${FRONTEND_REPO:-git@github.com:hjeverts/bouwplannen_frontend.git}"
BACKEND_REPO="${BACKEND_REPO:-git@github.com:hjeverts/bouwplannen_backend.git}"
BRANCH="${BRANCH:-main}"
BACKUP_KEEP="${BACKUP_KEEP:-14}"
# De repo's staan naast deze map: bouwplannen/{bouwplannen_deploy,bouwplannen_frontend,bouwplannen_backend}.
BASE_DIR="$(dirname "$DEPLOY_DIR")"
FRONTEND_DIR="$BASE_DIR/bouwplannen_frontend"
BACKEND_DIR="$BASE_DIR/bouwplannen_backend"
DATA_DIR_SETTING="${BOUWPLANNEN_DATA_DIR:-../data}"
if [[ "$DATA_DIR_SETTING" = /* ]]; then DATA_DIR="$DATA_DIR_SETTING"; else DATA_DIR="$DEPLOY_DIR/$DATA_DIR_SETTING"; fi

# Datamap klaarzetten. De API-container schrijft als de eigenaar van deze map.
mkdir -p "$DATA_DIR" || die "Kan de datamap $DATA_DIR niet aanmaken."
DATA_DIR="$(cd "$DATA_DIR" && pwd)"
if [[ -z "${BOUWPLANNEN_UID:-}" || -z "${BOUWPLANNEN_GID:-}" ]]; then
  BOUWPLANNEN_UID="$(stat -c %u "$DATA_DIR")"
  BOUWPLANNEN_GID="$(stat -c %g "$DATA_DIR")"
  {
    echo ""
    echo "# Toegevoegd door update.sh: eigenaar van $DATA_DIR"
    echo "BOUWPLANNEN_UID=$BOUWPLANNEN_UID"
    echo "BOUWPLANNEN_GID=$BOUWPLANNEN_GID"
  } >>.env
  export BOUWPLANNEN_UID BOUWPLANNEN_GID
  log "Datamap: $DATA_DIR (API schrijft als gebruiker $BOUWPLANNEN_UID:$BOUWPLANNEN_GID, vastgelegd in .env)"
fi

# ---------------------------------------------------------------------------
# Deze repo zelf bijwerken; bij een nieuw script opnieuw starten met de nieuwe versie.
# ---------------------------------------------------------------------------

if [[ $SELF_UPDATE -eq 1 && -d "$DEPLOY_DIR/.git" ]]; then
  before="$(git rev-parse HEAD)"
  if git pull --ff-only --quiet 2>/dev/null; then
    after="$(git rev-parse HEAD)"
    if [[ "$before" != "$after" ]]; then
      log "Deploy-repo bijgewerkt (${before:0:7} → ${after:0:7}); script opnieuw starten."
      flock -u 9
      exec "$0" --no-self-update "${ARGS[@]}"
    fi
  else
    log "Let op: deploy-repo kon niet worden bijgewerkt (lokale wijzigingen of geen verbinding); ga door met de huidige versie."
  fi
fi

# ---------------------------------------------------------------------------
# Broncode ophalen
# ---------------------------------------------------------------------------

# Zet de repo op de nieuwste commit van $BRANCH (clonet hem als hij er nog niet is).
# Schrijft "<oud> <nieuw>" naar stdout.
sync_repo() {
  local url="$1" dir="$2" old new
  if [[ ! -d "$dir/.git" ]]; then
    mkdir -p "$(dirname "$dir")"
    git clone --quiet --branch "$BRANCH" "$url" "$dir" >&2 || die "Kan $url niet clonen."
    old="-"
  else
    old="$(git -C "$dir" rev-parse HEAD)"
    git -C "$dir" remote set-url origin "$url"
    git -C "$dir" fetch --quiet origin "$BRANCH" >&2 || die "Kan $url niet ophalen."
    # De server is geen werkplek: lokale wijzigingen worden overschreven.
    git -C "$dir" checkout --quiet -B "$BRANCH" "origin/$BRANCH" >&2
    git -C "$dir" reset --quiet --hard "origin/$BRANCH" >&2
    git -C "$dir" clean --quiet -fd >&2
  fi
  new="$(git -C "$dir" rev-parse HEAD)"
  echo "$old $new"
}

checkout() {
  local dir="$1" sha="$2"
  git -C "$dir" reset --quiet --hard "$sha"
}

log "Code ophalen (branch $BRANCH)…"
read -r FRONT_OLD FRONT_NEW < <(sync_repo "$FRONTEND_REPO" "$FRONTEND_DIR")
read -r BACK_OLD BACK_NEW < <(sync_repo "$BACKEND_REPO" "$BACKEND_DIR")
[[ -n "${FRONT_NEW:-}" && -n "${BACK_NEW:-}" ]] || die "Ophalen van de broncode mislukt."

describe() {
  local name="$1" old="$2" new="$3" dir="$4"
  if [[ "$old" == "-" ]]; then
    log "  $name: nieuw ($(git -C "$dir" log -1 --format='%h %s'))"
  elif [[ "$old" == "$new" ]]; then
    log "  $name: ongewijzigd (${new:0:7})"
  else
    log "  $name: ${old:0:7} → ${new:0:7}"
    git -C "$dir" log --format='      %h %s' "$old..$new" 2>/dev/null | head -n 20 || true
  fi
}
describe "frontend" "$FRONT_OLD" "$FRONT_NEW" "$FRONTEND_DIR"
describe "backend " "$BACK_OLD" "$BACK_NEW" "$BACKEND_DIR"

# Is de webpoort vrij (of al van onze eigen container)? Voorkomt een vage Docker-fout bij een botsing.
check_port() {
  local port="${WEB_PORT:-8380}"
  command -v ss >/dev/null 2>&1 || return 0
  [[ -n "$(docker compose ps -q web 2>/dev/null)" ]] && return 0
  if [[ -n "$(ss -Hltn "sport = :$port" 2>/dev/null)" ]]; then
    die "Poort $port is al in gebruik door een ander programma of een andere container. Kies een vrije WEB_PORT in .env (bekijk bezette poorten met: ss -ltn) en pas de poort ook aan in je nginx-config."
  fi
}

remind_accounts() {
  if [[ ! -s "$DATA_DIR/accounts.json" ]]; then
    log "Er is nog geen account. Maak er een met: ./user.sh add <naam>   (het eerste account wordt beheerder)"
  fi
}

images_present() {
  docker image inspect bouwplannen-web:latest bouwplannen-api:latest >/dev/null 2>&1
}

FAILED_FILE="$DEPLOY_DIR/.failed-version"
CURRENT="$FRONT_NEW $BACK_NEW"

CHANGED=0
[[ "$FRONT_OLD" != "$FRONT_NEW" || "$BACK_OLD" != "$BACK_NEW" ]] && CHANGED=1
images_present || CHANGED=1

# Een versie die eerder niet wilde starten niet elke run opnieuw proberen (wel met --force).
if [[ $FORCE -eq 0 && -f "$FAILED_FILE" && "$(cat "$FAILED_FILE")" == "$CURRENT" ]]; then
  # Broncode terug op de versie die draait, zodat de map overeenkomt met de containers.
  if [[ -f "$DEPLOY_DIR/.deployed-version" ]]; then
    read -r GOOD_FRONT GOOD_BACK <"$DEPLOY_DIR/.deployed-version"
    checkout "$FRONTEND_DIR" "$GOOD_FRONT"
    checkout "$BACKEND_DIR" "$GOOD_BACK"
  fi
  log "Deze versie (frontend ${FRONT_NEW:0:7}, backend ${BACK_NEW:0:7}) startte eerder niet; overgeslagen. Gebruik --force om het opnieuw te proberen."
  exit 0
fi

if [[ $CHANGED -eq 0 && $FORCE -eq 0 ]]; then
  # Geen nieuwe code; wel zorgen dat alles draait met de huidige instellingen (no-op als dat al zo is).
  check_port
  docker compose up -d --remove-orphans >/dev/null
  log "Niets nieuws. Alles draait."
  remind_accounts
  exit 0
fi

# ---------------------------------------------------------------------------
# Back-up, bouwen, starten
# ---------------------------------------------------------------------------

backup_data() {
  if [[ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
    log "Nog geen projectdata; geen back-up nodig."
    return
  fi
  mkdir -p "$DEPLOY_DIR/backups"
  local file
  file="data-$(date '+%Y%m%d-%H%M%S').tgz"
  tar czf "$DEPLOY_DIR/backups/$file" -C "$DATA_DIR" . || die "Back-up van de projectdata mislukt; update afgebroken."
  log "Back-up gemaakt: backups/$file"
  # Oudste back-ups opruimen.
  find "$DEPLOY_DIR/backups" -maxdepth 1 -name 'data-*.tgz' -printf '%T@ %p\n' |
    sort -rn | tail -n "+$((BACKUP_KEEP + 1))" | cut -d' ' -f2- | xargs -r rm -f --
}

wait_healthy() {
  local id status waited=0
  id="$(docker compose ps -q web)"
  [[ -n "$id" ]] || return 1
  while ((waited < HEALTH_TIMEOUT)); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo unknown)"
    case "$status" in
      healthy) return 0 ;;
      unhealthy | exited | dead) return 1 ;;
    esac
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

build_and_start() {
  docker compose build --pull && docker compose up -d --remove-orphans
}

check_port
if [[ $BACKUP -eq 1 ]]; then backup_data; fi

log "Images bouwen…"
if ! build_and_start; then
  if [[ "$FRONT_OLD" != "-" ]]; then
    checkout "$FRONTEND_DIR" "$FRONT_OLD"
    checkout "$BACKEND_DIR" "$BACK_OLD"
  fi
  die "Bouwen of starten mislukt. De vorige containers draaien nog (als die er waren); broncode teruggezet."
fi

log "Wachten tot de app gezond is (max ${HEALTH_TIMEOUT}s)…"
if wait_healthy; then
  echo "$CURRENT" >"$DEPLOY_DIR/.deployed-version"
  rm -f "$FAILED_FILE"
  docker image prune -f >/dev/null 2>&1 || true
  log "Klaar: frontend ${FRONT_NEW:0:7}, backend ${BACK_NEW:0:7}."
  remind_accounts
  exit 0
fi

echo "$CURRENT" >"$FAILED_FILE"
log "De nieuwe versie wordt niet gezond. Logboek van de laatste regels:"
docker compose logs --tail=40 api web 2>&1 | sed 's/^/    /' || true

if [[ "$FRONT_OLD" == "-" ]]; then
  die "Eerste installatie start niet. Bekijk de logs hierboven en 'docker compose logs'."
fi

log "Vorige versie terugzetten (frontend ${FRONT_OLD:0:7}, backend ${BACK_OLD:0:7})…"
checkout "$FRONTEND_DIR" "$FRONT_OLD"
checkout "$BACKEND_DIR" "$BACK_OLD"
if build_and_start && wait_healthy; then
  die "Nieuwe versie teruggedraaid; de vorige versie draait weer. Volgende run probeert het opnieuw."
fi
die "Ook de vorige versie start niet. Bekijk 'docker compose logs'. Back-up van de data staat in backups/."
