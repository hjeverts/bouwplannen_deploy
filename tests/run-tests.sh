#!/usr/bin/env bash
# Test update.sh van begin tot eind met lokale git-repo's en een nep-docker.
# Gebruik: tests/run-tests.sh   (geen Docker of netwerk nodig)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_DEPLOY="${1:-$(dirname "$HERE")}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export FAKE_DOCKER_STATE="$T/state" PATH="$T/bin:$PATH" HEALTH_TIMEOUT=6
mkdir -p "$T/state" "$T/bin"
cp "$HERE/fake-docker" "$T/bin/docker"
chmod +x "$T/bin/docker"
# Isolated git config, so settings of this machine do not interfere.
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@t; git config --global user.name t
git config --global init.defaultBranch main

pass=0; fail=0
check() { if eval "$2"; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1"; fail=$((fail+1)); fi; }

mkrepo() { # bare repo with one commit
  git init -q --bare "$T/$1.git"
  git clone -q "$T/$1.git" "$T/work-$1" 2>/dev/null
  echo "v1" >"$T/work-$1/README"
  git -C "$T/work-$1" add -A && git -C "$T/work-$1" commit -qm "$1 v1" && git -C "$T/work-$1" push -q origin main
}
commit() { # repo, message, [file to add], [file to remove]
  local r="$1" m="$2"
  [[ -n "${3:-}" ]] && echo x >"$T/work-$r/$3"
  [[ -n "${4:-}" ]] && rm -f "$T/work-$r/$4"
  echo "$m" >>"$T/work-$r/README"
  git -C "$T/work-$r" add -A && git -C "$T/work-$r" commit -qm "$m" && git -C "$T/work-$r" push -q origin main
}
mkrepo frontend; mkrepo backend

# Deploy repo as a clone of a bare copy, so self-update can be tested too.
git init -q --bare "$T/deploy.git"
git clone -q "$T/deploy.git" "$T/work-deploy" 2>/dev/null
tar -C "$SRC_DEPLOY" --exclude=.git -cf - . | tar -C "$T/work-deploy" -xf -
git -C "$T/work-deploy" add -A && git -C "$T/work-deploy" commit -qm deploy && git -C "$T/work-deploy" push -q origin main
mkdir -p "$T/bouwplannen"
git clone -q "$T/deploy.git" "$T/bouwplannen/bouwplannen_deploy"
S="$T/bouwplannen/bouwplannen_deploy"
# shellcheck disable=SC2034 # gebruikt in de check-expressies
P="$T/bouwplannen"
run() { (cd "$S" && ./update.sh "$@") >"$T/out.log" 2>&1; echo $? >"$T/rc"; }
rc() { cat "$T/rc"; }
out() { grep -q -- "$1" "$T/out.log"; }

echo "1. zonder .env"
# Repo-adressen komen normaal uit .env.example (GitHub); voor de test via de omgeving.
(cd "$S" && FRONTEND_REPO="$T/frontend.git" BACKEND_REPO="$T/backend.git" ./update.sh --no-self-update) >"$T/out.log" 2>&1; echo $? >"$T/rc"
check ".env aangemaakt uit het voorbeeld" '[[ -f $S/.env ]] && out ".env aangemaakt" && grep -q "^WEB_PORT=8380" "$S/.env"'
rm -rf "$S/.env" "$P/bouwplannen_frontend" "$P/bouwplannen_backend" "$P/data" "$S/.deployed-version"
rm -f "$T/state/images"

echo "2. user.sh vóór de installatie"
(cd "$S" && ./user.sh list) >"$T/out.log" 2>&1; echo $? >"$T/rc"
check "vraagt eerst update.sh te draaien" '[[ $(rc) == 1 ]] && out "draai eerst ./update.sh"'

cat >"$S/.env" <<EOF
FRONTEND_REPO=$T/frontend.git
BACKEND_REPO=$T/backend.git
BACKUP_KEEP=2
EOF

echo "3. eerste installatie"
run
check "clonet, bouwt, gezond" '[[ $(rc) == 0 ]] && out "frontend: nieuw" && out "Klaar:"'
check "repo's naast de deploy-map" '[[ -d $P/bouwplannen_frontend/.git && -d $P/bouwplannen_backend/.git && $(ls $P | tr "\n" " ") == "bouwplannen_backend bouwplannen_deploy bouwplannen_frontend data " ]]'
check "geen back-up zonder data" 'out "geen back-up nodig"'
check "versie vastgelegd" '[[ -s $S/.deployed-version ]]'
check "herinnert aan een eerste account" 'out "nog geen account"'
check "datamap naast de repo's" '[[ -d $P/data ]]'
check "eigenaar datamap in .env" 'grep -q "^BOUWPLANNEN_UID=$(id -u)$" "$S/.env" && grep -q "^BOUWPLANNEN_GID=$(id -g)$" "$S/.env"'

echo "4. niets nieuw"
: >"$T/state/calls.log"
run
check "slaat bouwen over" '[[ $(rc) == 0 ]] && out "Niets nieuws" && ! grep -q "compose build" "$T/state/calls.log"'

echo "5. nieuwe backend-commit"
commit backend "backend v2"
run
check "bouwt opnieuw met back-up" '[[ $(rc) == 0 ]] && out "backend : " && out "backend v2" && out "Back-up gemaakt"'
check "back-up bevat de projecten" 'tar tzf "$(ls -1 "$S"/backups/data-*.tgz | head -1)" | grep -q "projects/p1.json"'
check "UID maar één keer toegevoegd" '[[ $(grep -c "^BOUWPLANNEN_UID=" "$S/.env") == 1 ]]'
check "nieuwe versie gebouwd" '[[ $(cat "$T/state/built-backend") == $(git -C "$T/work-backend" rev-parse HEAD) ]]'
# shellcheck disable=SC2034 # gebruikt in de check-expressies
GOOD="$(git -C "$T/work-backend" rev-parse HEAD)"

echo "6. kapotte versie"
commit backend "kapot" BROKEN
run
check "faalt en zet terug" '[[ $(rc) == 1 ]] && out "niet gezond" && out "teruggedraaid"'
check "broncode staat op vorige versie" '[[ $(git -C $P/bouwplannen_backend rev-parse HEAD) == "$GOOD" ]]'
check "vorige versie opnieuw gebouwd" '[[ $(cat "$T/state/built-backend") == "$GOOD" ]]'
check "logs getoond" 'out "fake log line"'

echo "7. volgende run slaat de kapotte versie over"
: >"$T/state/calls.log"
run
check "overgeslagen, geen build" '[[ $(rc) == 0 ]] && out "startte eerder niet" && ! grep -q "compose build" "$T/state/calls.log"'
check "broncode blijft op goede versie" '[[ $(git -C $P/bouwplannen_backend rev-parse HEAD) == "$GOOD" ]]'

echo "8. --force probeert het toch"
run --force
check "probeert en faalt opnieuw" '[[ $(rc) == 1 ]] && out "teruggedraaid"'

echo "9. reparatie-commit"
commit backend "gerepareerd" "" BROKEN
run
check "nieuwe versie draait" '[[ $(rc) == 0 ]] && out "Klaar:" && [[ ! -f $S/.failed-version ]]'

echo "10. bouwfout"
commit frontend "frontend v2"
touch "$T/state/fail-build"
run
check "stopt, broncode terug" '[[ $(rc) == 1 ]] && out "Bouwen of starten mislukt"'
rm "$T/state/fail-build"

echo "11. back-ups opruimen (BACKUP_KEEP=2)"
run --force; sleep 1; run --force; sleep 1; run --force
check "maximaal 2 back-ups" '[[ $(ls "$S/backups" | wc -l) == 2 ]]'

echo "12. één run tegelijk"
( cd "$S" && flock -x .update.lock -c "sleep 3" ) &
sleep 0.5
run
check "tweede run stopt" '[[ $(rc) == 1 ]] && out "draait al"'
wait

echo "13. deploy-repo werkt zichzelf bij"
sed -i 's/^HEALTH_TIMEOUT=.*/&\n# zelf-update-test/' "$T/work-deploy/update.sh"
git -C "$T/work-deploy" commit -qam "script bijgewerkt" && git -C "$T/work-deploy" push -q origin main
run
check "haalt nieuw script op en herstart" '[[ $(rc) == 0 ]] && out "Deploy-repo bijgewerkt" && grep -q "zelf-update-test" "$S/update.sh"'

echo "14. poort al bezet door iets anders"
cat >"$T/bin/ss" <<'EOS'
#!/usr/bin/env bash
[[ -f "$FAKE_DOCKER_STATE/port-busy" ]] && echo "LISTEN 0 511 127.0.0.1:8380 0.0.0.0:*"
exit 0
EOS
chmod +x "$T/bin/ss"
touch "$T/state/not-running" "$T/state/port-busy"
run --force
check "stopt met duidelijke melding" '[[ $(rc) == 1 ]] && out "Poort 8380 is al in gebruik"'
rm "$T/state/not-running"
run --force
check "geen melding als het onze eigen container is" '[[ $(rc) == 0 ]]'
rm "$T/state/port-busy"

echo "15. user.sh na de installatie"
(cd "$S" && ./user.sh add hans --admin) >"$T/out.log" 2>&1; echo $? >"$T/rc"
check "roept de API-container aan" '[[ $(rc) == 0 ]] && out "users-cli: compose run --rm --no-deps -T api users add hans --admin"'
(cd "$S" && ./user.sh) >"$T/out.log" 2>&1; echo $? >"$T/rc"
check "zonder opdracht: hulp en code 2" '[[ $(rc) == 2 ]] && out "./user.sh add"'
mkdir -p "$P/data" && echo '{"users":[{}]}' >"$P/data/accounts.json"
run
check "geen herinnering als er accounts zijn" '[[ $(rc) == 0 ]] && ! out "nog geen account"'

echo "16. onbekende optie"
run --verkeerd
check "geeft hulp en code 2" '[[ $(rc) == 2 ]] && out "Onbekende optie"'

echo
echo "$pass geslaagd, $fail mislukt"
[[ $fail -eq 0 ]]
