# Bouwplannen – deploy

Draait de [frontend](https://github.com/hjeverts/bouwplannen_frontend) en de [API](https://github.com/hjeverts/bouwplannen_backend) samen met Docker Compose, en houdt ze bij met één script.

## Structuur op de server

```
bouwplannen/
├── bouwplannen_deploy/     ← deze repo; hier draai je ./update.sh
├── bouwplannen_frontend/   ← opgehaald en bijgehouden door update.sh
├── bouwplannen_backend/    ← idem
└── data/projects/*.json    ← de projecten
```

Alles draait onder één adres: nginx serveert de app en stuurt `/api/` door naar de API. Geen CORS, één certificaat. In de app vul je bij **Synchroniseren** dat adres in (staat al voorgevuld) en de API-sleutel.

## Installeren

Nodig: Docker met Compose v2, git, en leesrecht op de drie repo's vanaf de server (een SSH-sleutel of [deploy key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)).

```bash
mkdir -p ~/bouwplannen && cd ~/bouwplannen
git clone git@github.com:hjeverts/bouwplannen_deploy.git
cd bouwplannen_deploy
cp .env.example .env
sed -i "s/^BOUWPLANNEN_API_KEY=.*/BOUWPLANNEN_API_KEY=$(openssl rand -hex 24)/" .env
./update.sh
```

De eerste run clonet de frontend en backend naast deze map, maakt `../data` aan, bouwt de images en start alles. Daarna staat de app op `http://127.0.0.1:8080` (zie `WEB_BIND` / `WEB_PORT` in `.env`).

De API-sleutel voor de app vind je terug met `grep BOUWPLANNEN_API_KEY .env`.

## Bijwerken

```bash
./update.sh             # alleen bouwen als er nieuwe commits zijn
./update.sh --force     # altijd opnieuw bouwen
./update.sh --no-backup # zonder back-up vooraf
```

Wat het script doet:

1. Werkt deze repo zelf bij (`git pull --ff-only`) en start zichzelf opnieuw als het script veranderd is.
2. Haalt `BRANCH` (standaard `main`) op voor frontend en backend. Lokale wijzigingen in die mappen worden overschreven: de server is geen werkplek.
3. Niets nieuw? Dan alleen `docker compose up -d` (doet niets als alles al draait) en klaar.
4. Anders: back-up van `../data` naar `backups/data-<tijd>.tgz` (de laatste `BACKUP_KEEP` blijven bewaard), `docker compose build --pull`, `docker compose up -d`.
5. Wacht tot de healthcheck slaagt. Die controleert nginx én de API erachter. Lukt dat niet, dan toont het de logs, zet het de vorige versie terug en bouwt die opnieuw. Die mislukte versie wordt bij volgende runs overgeslagen tot er een nieuwe commit is (of je `--force` gebruikt).
6. Ruimt oude images op.

Er draait altijd maar één `update.sh` tegelijk (lock), dus automatisch draaien kan veilig:

```cron
# crontab -e  (als de gebruiker die eigenaar is van ~/bouwplannen)
*/15 * * * * cd ~/bouwplannen/bouwplannen_deploy && ./update.sh >> update.log 2>&1
```

## Data en back-ups

- Projecten staan als JSON-bestanden in `bouwplannen/data/projects/`. De API-container schrijft als de eigenaar van die map (`BOUWPLANNEN_UID`/`GID` in `.env`, door `update.sh` ingevuld). Je kunt de map dus zelf lezen en meenemen in een back-up, bijvoorbeeld naar Nextcloud.
- Terugzetten van een back-up:

  ```bash
  docker compose stop api
  tar xzf backups/data-20261009-131500.tgz -C ../data
  docker compose start api
  ```

## HTTPS

- **Heb je al een reverse proxy** (nginx, Traefik, Caddy, Nginx Proxy Manager): laat `WEB_BIND=127.0.0.1` staan en stuur je domein door naar `http://127.0.0.1:8080`.
- **Geen reverse proxy:** zet in `.env` `COMPOSE_PROFILES=https` en `DOMAIN=bouwplannen.jouwdomein.nl`. Poort 80 en 443 moeten naar de server wijzen. Caddy haalt dan zelf een Let's Encrypt-certificaat op.

Gebruik de app niet zonder HTTPS buiten je eigen netwerk: de API-sleutel gaat anders leesbaar mee.

## Handig

```bash
docker compose ps                 # wat draait er
docker compose logs -f api web    # logboek volgen
docker compose restart api        # API herstarten
```

## Tests

`tests/run-tests.sh` test `update.sh` van begin tot eind, met lokale git-repo's en een nagebootste `docker` (geen Docker of netwerk nodig). Het doorloopt 26 controles, waaronder: eerste installatie, niets nieuw, nieuwe commit met back-up, een kapotte versie die wordt teruggedraaid en daarna overgeslagen, `--force`, een bouwfout, opruimen van back-ups, de lock en het zelf bijwerken van deze repo.
