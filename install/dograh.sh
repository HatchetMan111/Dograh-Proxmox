#!/usr/bin/env bash
# =============================================================================
#  🎙️ Dograh – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/Dograh-Proxmox
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  Dograh (https://github.com/dograh-hq/dograh): die Open-Source-Alternative
#  zu Vapi & Retell – Voice-Agenten mit visuellem Workflow-Builder bauen,
#  im Browser testen (Test Audio / Test Chat), eigene LLM/TTS/STT-Provider
#  verbinden. Nach dem Vorbild der Proxmox VE Community Scripts.
#
#  Architektur im Container: Docker CE + die OFFIZIELLE dograh-Compose-Datei
#  (unverändert) + ein eigenes docker-compose.override.yaml (Restart-Policies,
#  Ports, Härtung: Postgres/Redis nur localhost) + systemd-Unit `dograh`.
#  UI (Port 3010) und API (Port 8000) lauschen auf 0.0.0.0 – von jedem Gerät
#  im LAN erreichbar. KEIN Cloudflare-Tunnel, Telemetrie standardmäßig AUS.
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Dograh-Proxmox/main/install/dograh.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 210 --memory 8192 --port 3010
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.0"   # wird in --status/-Logs ausgegeben – hilft bei Fehlersuche
APP_NAME="dograh"
UPSTREAM_OWNER="dograh-hq"
UPSTREAM_REPO="dograh"
UPSTREAM_BRANCH="main"      # Update-Quelle (Compose-Datei); für einen Fixpin hier z. B. einen Tag eintragen
UPSTREAM_COMPOSE_URL="https://raw.githubusercontent.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/${UPSTREAM_BRANCH}/docker-compose.yaml"
IMAGE_REGISTRY="ghcr.io/dograh-hq"   # offizielle Release-Images (kein Build im CT)
APP_DIR="/opt/dograh"       # Projektverzeichnis im Container
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="dograh"
CT_STORAGE="local-lvm"
CT_ROOTFS=24                # GB – Docker-Images (~3 GB) + Postgres + MinIO-Audio
CT_CORES=4                  # Realtime-Audio (Resampling/VAD) profitiert von Kernen
CT_MEMORY=4096              # MB – upstream-Minimum ist 8 GB (4 Worker); lokal reicht 1 Worker
CT_SWAP=1024                # MB Puffer für Pull/Entpacken-Spitzen
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren
CT_SSHKEY=""                # Pfad ODER URL zu einer Public-Key-Datei (optional)
SSH_KEY_FILE=""             # aufgelöste Key-Datei für pct create
UI_PORT=3010                # Dograh-Web-UI (Next.js) – Native-Portnummer
API_PORT=8000               # Dograh-Backend (FastAPI) – fest, Browser braucht beide
TELEMETRY=false             # ENABLE_TELEMETRY (Dograh sammelt sonst anonyme Nutzungsdaten)
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Dograh-Proxmox/main/install/dograh.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Docker-Compose), falls schon
# ein Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + Docker):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/dograh-setup.log 2>/dev/null
            echo "--- docker compose ps ---"
            docker compose --project-directory /opt/dograh ps 2>/dev/null || true
            echo "--- docker compose logs (letzte 25 Zeilen) ---"
            docker compose --project-directory /opt/dograh logs --tail 25 2>/dev/null || true
            echo "--- journalctl -u dograh -u docker ---"
            journalctl -u dograh --no-pager 2>/dev/null | tail -n 10 || true
            journalctl -u docker --no-pager 2>/dev/null | tail -n 10 || true
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # if statt [[ ]] && … – Rückgabewert sauber halten.
    # Name ist in `pct list` IMMER die letzte Spalte (Lock kann leer sein).
    if pct list 2>/dev/null | awk '{print $NF}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1; exit}'
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    # Nach pct create --start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – Docker-Images + Compose-Datei brauchen Namensauflösung.
    # Live-Fall (2026-11-10, CT 200): DNS ist FLAKY – ein einzelner getent-Erfolg
    # reichte, Stunden später war wieder alles tot. Deshalb: 3 Erfolge in Folge
    # verlangen; eine einzige Störung in diesem Fenster → Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts raw.githubusercontent.com >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver eintragen
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht) + nochmal prüfen.
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts raw.githubusercontent.com >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).\n  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1\n  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    # pct status liefert "status: <wert>" – Prefix abschneiden für saubere Meldungen
    state="${state#status: }"
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)            CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)      CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)       CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)        CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)         CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)        CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)          CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)        CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)            CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)       CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)      CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)        CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)          UI_PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --telemetry)     TELEMETRY=true; i=$((i+1)) ;;
            --force)         FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)        ASSUME_YES=true; i=$((i+1)) ;;
            --update)        UPDATE=true; i=$((i+1)) ;;
            --uninstall)     UNINSTALL=true; i=$((i+1)) ;;
            --status)        STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)         set -x; i=$((i+1)) ;;
            --help|-h)       print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (–help zeigt alle Optionen)" ;;
        esac
    done
    # Ports hart validieren – sie landen direkt in der Compose-Config im Container.
    if ! [[ "$UI_PORT" =~ ^[0-9]+$ ]] || [[ "$UI_PORT" -lt 1 || "$UI_PORT" -gt 65535 ]]; then
        die "Ungültiger UI-Port: '$UI_PORT' (1–65535 erwartet, z. B. --port 3010)"
    fi
    if [[ "$UI_PORT" == "$API_PORT" ]]; then
        die "UI-Port ($UI_PORT) und API-Port ($API_PORT) dürfen nicht identisch sein."
    fi
}

print_help() {
    cat <<'EOF'
🎙️ Dograh – Proxmox-Installer (Open-Source-Voice-Agenten, Vapi/Retell-Alternative)

Installation:   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Dograh-Proxmox/main/install/dograh.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID          Container-ID (Default: nächste freie ab 200)
  --hostname NAME  Container-Hostname (Default: dograh)
  --storage NAME   Storage für rootfs (Default: local-lvm)
  --rootfs GB      Disk-Größe (Default: 24 – Docker-Images + Daten)
  --cores N        vCPUs (Default: 4)
  --memory MB      RAM (Default: 4096 – 1 FastAPI-Worker; upstream empfiehlt 8192 für Produktion)
  --swap MB        Swap (Default: 1024)
  --bridge BR      Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR        Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
                   Empfehlenswert: feste IP (oder DHCP-Reservierung), damit die
                   vom Browser genutzte API-URL dauerhaft stimmt.
  --gateway GW     Gateway für statische IP
  --password PW    Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD    Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT      Web-UI-Port im Container (Default: 3010; API läuft fix auf 8000)
  --telemetry      Anonyme Nutzungsdaten an Dograh/PostHog erlauben (Default: AUS)
  --force          Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y       Rückfragen überspringen
  --update         Dograh im bestehenden Container aktualisieren (Compose-Datei + Images neu ziehen)
  --uninstall      Container stoppen und löschen (ALLE Daten gehen verloren!)
  --status         Status anzeigen
  --debug          Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte (Ports, URLs, DNS, Registry, Telemetrie) kommen als Umgebungs-
# variablen via `pct exec -- env …` in den Container. Das vermeidet die
# Escaping-Grube bei Compose-/Shell-Sonderzeichen komplett.
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# Dograh In-Container-Setup (idempotent – safe für Update & Re-Run)
# Variablen via env: APP_DIR, UPSTREAM_COMPOSE_URL, UI_PORT, API_PORT, HOST_DNS,
#                    TELEMETRY, IMAGE_REGISTRY, APPLY_UI_PORT
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo "✘ $1" >&2; }
ok(){ echo "✔ $1"; }
die(){ err "$1"; exit 1; }

: "${APP_DIR:?APP_DIR fehlt (env)}"
: "${UPSTREAM_COMPOSE_URL:?UPSTREAM_COMPOSE_URL fehlt (env)}"
: "${UI_PORT:?UI_PORT fehlt (env)}"
: "${API_PORT:?API_PORT fehlt (env)}"
: "${IMAGE_REGISTRY:?IMAGE_REGISTRY fehlt (env)}"

echo ">>> curl sicherstellen (nacktes Debian-Template hat KEIN curl) ..."
if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates >/dev/null
fi

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
# dhclient-Hook: verhindert, dass Lease-Renewals /etc/resolv.conf überschreiben.
# (chattr +i funktioniert in unprivilegierten LXCs nicht – fehlendes Capability,
#  Live-Fund 2026-11-10: CT-DNS war nach Stunden wieder kaputt.)
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# Dograh: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
printf 'domain home.arpa\nsearch home.arpa\nnameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n' "${HOST_DNS}" > /etc/resolv.conf

echo ">>> Docker installieren / prüfen ..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL --retry 3 "https://get.docker.com" -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh >/dev/null 2>&1 || sh /tmp/get-docker.sh
else
    echo "    Docker bereits vorhanden: $(docker --version 2>/dev/null || echo 'unbekannt')"
fi
if ! docker compose version >/dev/null 2>&1; then
    die "docker compose (v2-Plugin) fehlt – get.docker.com hätte es installieren müssen.\n  Debug: docker --version; ls /usr/libexec/docker/cli-plugins/"
fi
# Docker-Daemon muss laufen (Debian startet ihn bei apt-Install meist schon)
systemctl enable docker >/dev/null 2>&1 || true
if ! docker info >/dev/null 2>&1; then
    systemctl start docker
    for _ in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then break; fi
        sleep 1
    done
    docker info >/dev/null 2>&1 || die "Docker-Daemon startet nicht.\n  Debug: journalctl -u docker -e"
fi

echo ">>> Offizielle Dograh-Compose-Datei laden (${UPSTREAM_COMPOSE_URL}) ..."
mkdir -p "$APP_DIR"
curl -fsSL --retry 3 "${UPSTREAM_COMPOSE_URL}" -o /tmp/dograh-compose.yaml
# Explizites Swap statt blindes mv (GNU-mv würde INTO existierendes Verzeichnis
# verschieben; hier Datei→Datei, trotzdem sauber ersetzen):
mv -f /tmp/dograh-compose.yaml "${APP_DIR}/docker-compose.yaml"
cd "$APP_DIR"

# ── .env: Secrets idempotent erzeugen (bestehende bleiben erhalten) ─────────
generate_secret() {
    # Gleiche Strategie wie upstream start_docker.sh: openssl → /dev/urandom+od
    if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32; return 0; fi
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}
dotenv_get() {
    # Wert eines Keys aus .env lesen (leer, wenn nicht vorhanden)
    local key=$1 line
    [[ -f .env ]] || { return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < .env
    return 0
}
dotenv_set() {
    # Key setzen/ersetzen; fehlende .env wird erzeugt
    local key=$1 value=$2 tmp=".env.tmp.$$" line updated=false
    if [[ -f .env ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                "$key"=*) printf '%s=%s\n' "$key" "$value"; updated=true ;;
                *) printf '%s\n' "$line" ;;
            esac
        done < .env > "$tmp"
        if [[ "$updated" != "true" ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"
        fi
    else
        printf '%s=%s\n' "$key" "$value" > "$tmp"
    fi
    mv -f "$tmp" .env
}

echo ">>> .env erzeugen/prüfen (Secrets bleiben bei Update erhalten) ..."
if [[ -z "$(dotenv_get OSS_JWT_SECRET)" ]]; then
    dotenv_set OSS_JWT_SECRET "$(generate_secret)"
    echo "    OSS_JWT_SECRET erzeugt"
else
    echo "    OSS_JWT_SECRET vorhanden"
fi
if [[ -z "$(dotenv_get POSTGRES_PASSWORD)" ]]; then
    dotenv_set POSTGRES_PASSWORD "$(generate_secret)"
    echo "    POSTGRES_PASSWORD erzeugt"
fi
if [[ -z "$(dotenv_get REDIS_PASSWORD)" ]]; then
    dotenv_set REDIS_PASSWORD "$(generate_secret)"
    echo "    REDIS_PASSWORD erzeugt"
fi
if [[ -z "$(dotenv_get MINIO_ROOT_USER)" ]]; then
    dotenv_set MINIO_ROOT_USER "dograh$(generate_secret | cut -c1-12)"
    echo "    MINIO_ROOT_USER erzeugt"
fi
if [[ -z "$(dotenv_get MINIO_ROOT_PASSWORD)" ]]; then
    dotenv_set MINIO_ROOT_PASSWORD "$(generate_secret)"
    echo "    MINIO_ROOT_PASSWORD erzeugt"
fi
# Nicht-geheime Werte (bei Update nur setzen, wenn noch nicht vorhanden –
# Nutzer-Änderungen in der .env bleiben damit erhalten):
[[ -n "$(dotenv_get REGISTRY)" ]]          || dotenv_set REGISTRY "$IMAGE_REGISTRY"
[[ -n "$(dotenv_get ENVIRONMENT)" ]]       || dotenv_set ENVIRONMENT "local"
[[ -n "$(dotenv_get FASTAPI_WORKERS)" ]]   || dotenv_set FASTAPI_WORKERS "1"
[[ -n "$(dotenv_get ENABLE_SIGNUP)" ]]     || dotenv_set ENABLE_SIGNUP "true"
if [[ "${TELEMETRY:-false}" == "true" ]]; then
    dotenv_set ENABLE_TELEMETRY "true"
else
    [[ -n "$(dotenv_get ENABLE_TELEMETRY)" ]] || dotenv_set ENABLE_TELEMETRY "false"
fi
if [[ "${APPLY_UI_PORT:-0}" == "1" ]]; then
    dotenv_set DOGRAH_UI_PORT "$UI_PORT"
else
    [[ -n "$(dotenv_get DOGRAH_UI_PORT)" ]] || dotenv_set DOGRAH_UI_PORT "$UI_PORT"
fi
chmod 600 .env

echo ">>> docker-compose.override.yaml schreiben (Restart-Policies, Ports, Härtung) ..."
# Wird von docker compose AUTOMATISCH über die offizielle Datei gemergt:
#  - restart: unless-stopped → Überleben nach Reboot/Crash (docker-seitig)
#  - UI auf 0.0.0.0:${DOGRAH_UI_PORT}, API auf 0.0.0.0:8000 (Browser braucht beide)
#  - Postgres/Redis nur 127.0.0.1 (Härtung – Container erreichen sich intern
#    ohnehin über das Docker-Netz, die veröffentlichten Ports sind nur für Debug)
#  - MinIO auf 0.0.0.0:9000 (Browser lädt Voice-Audio per Presigned-URL direkt)
# `!override` (Compose ≥ 2.24) ersetzt die Port-Listen der Original-Datei.
cat > /tmp/dograh-override.yaml <<OVHEREOF
services:
  postgres:
    restart: unless-stopped
    ports: !override ["127.0.0.1:5432:5432"]
  redis:
    restart: unless-stopped
    ports: !override ["127.0.0.1:6379:6379"]
  minio:
    restart: unless-stopped
    ports: !override ["9000:9000"]
  api:
    restart: unless-stopped
    ports: !override ["${API_PORT}:8000"]
  ui:
    restart: unless-stopped
    ports: !override ["\${DOGRAH_UI_PORT:-${UI_PORT}}:3010"]
OVHEREOF
mv -f /tmp/dograh-override.yaml "${APP_DIR}/docker-compose.override.yaml"

echo ">>> Compose-Konfiguration validieren ..."
docker compose config -q || die "docker compose config meldet Fehler (Compose-Dateien/override prüfen).\n  Debug: cd $APP_DIR && docker compose config"

echo ">>> Backend-URL-Sync-Script schreiben (passt .env bei IP-Wechsel an) ..."
cat > "${APP_DIR}/sync-backend-url.sh" <<SYNCEOF
#!/usr/bin/env bash
# Synchronisiert die IP-abhängigen Einträge in .env mit der aktuellen CT-IP.
# Läuft als ExecStartPre vor jedem Dograh-Start – DHCP-IP-Hüpfer brechen
# damit die Browser→API-URL nicht mehr. Fehlende Keys werden ERGÄNZT
# (Frisch-Install ohne IP-Werte wird damit automatisch vervollständigt).
set -euo pipefail
SELF_DIR=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)
cd "\$SELF_DIR"
set_key() { # KEY VALUE – ersetzen oder anhängen (idempotent)
    if /bin/grep -q "^\$1=" .env; then
        /bin/sed -i "s|^\$1=.*|\$1=\$2|" .env
    else
        printf '%s=%s\n' "\$1" "\$2" >> .env
    fi
}
IP=\$(ip -4 addr show eth0 scope global 2>/dev/null | awk '/inet /{print \$2; exit}' | cut -d/ -f1 || true)
[[ -n "\$IP" ]] || { echo "dograh-sync: keine globale IPv4 an eth0 – .env bleibt unverändert"; exit 0; }
WANT="http://\${IP}:${API_PORT}"
CURRENT=\$(sed -n 's/^BACKEND_API_ENDPOINT=//p' .env 2>/dev/null | head -1 || true)
if [[ "\$CURRENT" != "\$WANT" ]]; then
    echo "dograh-sync: CT-IP geändert (\${CURRENT:-unbekannt} → \${IP}) – aktualisiere .env"
else
    echo "dograh-sync: CT-IP unverändert (\${IP})"
fi
set_key BACKEND_API_ENDPOINT "\$WANT"
set_key MINIO_PUBLIC_ENDPOINT "http://\${IP}:9000"
set_key SERVER_IP "\$IP"
SYNCEOF
chmod +x "${APP_DIR}/sync-backend-url.sh"

echo ">>> systemd-Unit 'dograh' schreiben (Restart=always) ..."
cat > /etc/systemd/system/dograh.service <<UNITEOF
[Unit]
Description=Dograh Voice-Agent-Plattform (docker compose)
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
# Attached `docker compose up`: systemd überwacht den Compose-Prozess,
# Restart=always startet den Stack bei Crash/Abbruch neu. Die Container
# tragen zusätzlich restart: unless-stopped (override-Datei).
Type=simple
WorkingDirectory=/opt/dograh
ExecStartPre=/opt/dograh/sync-backend-url.sh
ExecStart=/usr/bin/docker compose --project-directory /opt/dograh up --pull=missing
ExecStop=/usr/bin/docker compose --project-directory /opt/dograh stop
Restart=always
RestartSec=15
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable dograh >/dev/null 2>&1 || true

echo ">>> IP-abhängige .env-Einträge synchronisieren ..."
"${APP_DIR}/sync-backend-url.sh"

echo ">>> Docker-Images ziehen (dograh-api, dograh-ui, postgres, redis, minio) ..."
systemctl stop dograh >/dev/null 2>&1 || true
docker compose pull

echo ">>> Dograh-Stack starten (docker compose up -d) ..."
docker compose up -d

echo ">>> systemd-Service starten (übernimmt den laufenden Stack) ..."
systemctl start dograh

echo ">>> Warte auf API-Gesundheit (http://127.0.0.1:${API_PORT}/api/v1/health) ..."
API_OK=""
for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
           "http://127.0.0.1:${API_PORT}/api/v1/health" || true)
    if [[ "$code" == "200" ]]; then
        API_OK=1
        break
    fi
    sleep 5
done
if [[ -z "$API_OK" ]]; then
    die "API antwortet nicht mit 200 auf /api/v1/health (letzter Code: ${code:-keiner}).\n  Debug: cd $APP_DIR && docker compose ps && docker compose logs --tail 50 api"
fi
ok "API gesund (HTTP 200)"

echo ">>> Warte auf Web-UI (http://127.0.0.1:${UI_PORT}/) ..."
UI_OK=""
for _ in $(seq 1 30); do
    code=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
           "http://127.0.0.1:${UI_PORT}/" || true)
    if [[ "$code" == "200" ]]; then
        UI_OK=1
        break
    fi
    sleep 3
done
if [[ -z "$UI_OK" ]]; then
    die "Web-UI antwortet nicht mit 200 (letzter Code: ${code:-keiner}).\n  Debug: cd $APP_DIR && docker compose ps && docker compose logs --tail 50 ui"
fi
ok "Web-UI antwortet (HTTP 200)"

code=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
       "http://127.0.0.1:9000/minio/health/live" || true)
if [[ "$code" == "200" ]]; then
    ok "MinIO gesund (HTTP 200)"
else
    die "MinIO-Healthcheck fehlgeschlagen (Code: ${code:-keiner}).\n  Debug: cd $APP_DIR && docker compose logs --tail 30 minio"
fi

echo ">>> Aufräumen ..."
rm -f /tmp/get-docker.sh

echo ">>> Setup abgeschlossen."
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere Dograh im Container $ct_id"
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert –
    # der DHCP-DNS des Zielnetzes war live unzuverlässig, siehe verify_ct_dns)
    HOST_DNS=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # Variablen via env in den Container (kein Expansion-Heredoc → keine
    # Escaping-Gruben). set -o pipefail: ein Crash im Inner-Script darf nicht
    # durch `tee` maskiert werden (Grube 14).
    # APPLY_UI_PORT: bei Installation immer setzen; bei Update nur, wenn --port
    # explizit vom Default abweicht (Nutzer-Änderungen in .env bleiben erhalten).
    local apply_ui_port=0
    if [[ "$UI_PORT" != "3010" ]]; then
        apply_ui_port=1
    fi
    pct exec "$ct_id" -- env APP_DIR="$APP_DIR" UPSTREAM_COMPOSE_URL="$UPSTREAM_COMPOSE_URL" \
        UI_PORT="$UI_PORT" API_PORT="$API_PORT" HOST_DNS="${HOST_DNS:-1.1.1.1}" \
        TELEMETRY="$TELEMETRY" IMAGE_REGISTRY="$IMAGE_REGISTRY" APPLY_UI_PORT="$apply_ui_port" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/dograh-setup.log'
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code=""

    header "✅ Verifikation"

    # systemd-Service aktiv?
    while true; do
        if pct exec "$ct_id" -- systemctl is-active --quiet dograh 2>/dev/null; then
            ok "Service dograh läuft (systemctl is-active)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Service dograh läuft nicht.\n  Debug: pct exec $ct_id -- journalctl -u dograh -e && pct exec $ct_id -- systemctl status dograh"
        fi
        sleep 1
    done

    # Alle 5 Compose-Services oben?
    local ps_out=""
    ps_out=$(pct exec "$ct_id" -- docker compose --project-directory /opt/dograh ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)
    local missing=""
    for svc in postgres redis minio api ui; do
        if ! grep -q "^${svc} " <<<"$ps_out"; then
            missing+="${svc} "
        fi
    done
    if [[ -n "$missing" ]]; then
        die "Compose-Services fehlen oder sind nicht hochgekommen: ${missing}\n  Debug: pct exec $ct_id -- docker compose --project-directory /opt/dograh ps -a\n  Logs:  pct exec $ct_id -- docker compose --project-directory /opt/dograh logs --tail 50"
    fi
    ok "Alle Compose-Services laufen (postgres, redis, minio, api, ui)"

    # Web-UI + API antworten? (Grube: curl -w gibt bei Verbindungsfehler bereits
    # 000 aus – NIE zusätzlich || echo 000 anhängen, sonst falsch-positiv.)
    tries=0
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${UI_PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-UI antwortet (HTTP 200 auf Port ${UI_PORT})"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Web-UI antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n  Debug: pct exec $ct_id -- docker compose --project-directory /opt/dograh logs --tail 50 ui"
        fi
        sleep 2
    done

    tries=0
    code=""
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${API_PORT}/api/v1/health" || true)
        if [[ "$code" == "200" ]]; then
            ok "API gesund (HTTP 200 auf Port ${API_PORT})"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "API antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n  Debug: pct exec $ct_id -- docker compose --project-directory /opt/dograh logs --tail 50 api"
        fi
        sleep 2
    done

    # Erreichbarkeit vom PROXMOX-HOST aus (die Nutzer-URL läuft über die CT-IP;
    # im CT-Loopback kann alles OK sein, während eine Firewall draußen blockt).
    local ct_ip="" host_code=""
    ct_ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        host_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    "http://${ct_ip}:${UI_PORT}/" || true)
        if [[ "$host_code" == "200" ]]; then
            ok "Vom Host erreichbar: http://${ct_ip}:${UI_PORT} (HTTP 200)"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${host_code:-000} über http://${ct_ip}:${UI_PORT})."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🎙️  Dograh ist bereit!"

    local ct_ip=""
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<IP-ADRESSE>"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Web-UI:    http://${ct_ip}:${UI_PORT}${NC}"
    echo -e "  ${GREEN}  🔌 API:      http://${ct_ip}:${API_PORT}  (benötigt der Browser im Hintergrund)${NC}"
    echo -e "  ${GREEN}  🐚 Terminal:  pct enter ${CT_ID}${NC}"
    if [[ -n "$CT_PASSWORD" ]]; then
        echo -e "  ${GREEN}  🔑 Root-PW:   ${CT_PASSWORD}${NC}"
    fi
    echo -e "  ${GREEN}  🔧 Installer: v${INSTALLER_VERSION} (upstream ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${UPSTREAM_BRANCH})${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Erste Schritte:${NC}"
    echo "  1. http://${ct_ip}:${UI_PORT} öffnen und den ersten Account anlegen"
    echo "     (Signup ist offen – danach schließen: in ${APP_DIR}/.env"
    echo "      ENABLE_SIGNUP=false setzen und ${ONE_LINER} --update ausführen)"
    echo "  2. Inbound/Outbound wählen, Agent benennen, Anwendungsfall beschreiben"
    echo "  3. „Test Agent“ → Test Audio (Mikrofon im Browser) oder Test Chat"
    echo ""
    echo -e "  ${CYAN}Stimme/Modell (Standard = Dograh-Cloud-Auto-Keys):${NC}"
    echo "  LLM/TTS/STT laufen standardmäßig über Dograhs gehosteten Stack"
    echo "  (keine eigenen Keys nötig). Eigene Provider – inkl. lokalen, "
    echo "  OpenAI-kompatiblen Endpunkten – stellst du in der Web-UI unter"
    echo "  Einstellungen/Provider ein. Dann läuft die Inferenz komplett bei dir."
    echo ""
    echo -e "  ${CYAN}Telefonie (optional):${NC}"
    echo "  Twilio/Vonage/Telnyx/Plivo/… lassen sich in der UI verbinden. Für"
    echo "  eingehende Webhooks von außen braucht der CT eine öffentliche"
    echo "  Erreichbarkeit (Port-Forward / Tunnel) – für Browser-Tests im LAN"
    echo "  ist das NICHT nötig."
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:    ${ONE_LINER} --status"
    echo "  Update:    ${ONE_LINER} --update"
    echo "  Deinstall: ${ONE_LINER} --uninstall"
    echo "  Stack-Logs: pct exec ${CT_ID} -- docker compose --project-directory /opt/dograh logs -f"
    echo ""
    warn "Daten (Postgres, Voice-Audio in MinIO) liegen in Docker-Volumes im CT –"
    warn "ein --update erhält sie, pct destroy löscht sie. Für Backups: pct backup / vzdump."
    if [[ "$CT_IP" == "dhcp" ]]; then
        warn "CT hat DHCP – bei IP-Wechsel sync'd das System die .env beim Boot selbst,"
        warn "trotzdem empfohlen: DHCP-Reservierung im Router (oder --ip beim Install)."
    fi
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "🎙️ Installiere Dograh (LXC)"
    info "Installer-Version: v${INSTALLER_VERSION}"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Bereits vorhanden?
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.\n  Update:  ${ONE_LINER} --update\n  Neu aufsetzen:  ${ONE_LINER} --force"
        fi
    fi

    # Debian-Template sicherstellen (13 bevorzugt – Docker unterstützt trixie;
    # rV-Sortierung nimmt 13 vor 12, Fallback bleibt)
    header "🧱 Container-Template"
    local template=""
    template=$(pveam list local 2>/dev/null | awk '{print $1}' | grep -o 'debian-1[23]-standard[^ ]*' | sort -rV | head -1 || true)
    if [[ -z "$template" ]]; then
        info "Kein Debian-12/13-Template vorhanden – lade es herunter ..."
        pveam update
        template=$(pveam available --section system 2>/dev/null | grep -o 'debian-1[23]-standard[^ ]*' | sort -rV | head -1 || true)
        if [[ -z "$template" ]]; then
            die "Kein debian-12/13-standard-Template gefunden (pveam available leer?)."
        fi
        pveam download local "$template"
    fi
    ok "Template: $template"

    # ID & Passwort
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="dg-$(date +%s)"
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    net0+=",firewall=0"
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            wget -q --tries=3 -O "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "local:vztmpl/${template}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --features nesting=1,keyctl=1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"
    ok "Container $CT_ID erstellt und gestartet"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update Dograh (Compose-Datei + Images neu ziehen)"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden.\n  Erst installieren:  ${ONE_LINER}"
    fi
    CT_ID="$ct_id"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    ok "Update abgeschlossen – Daten (Postgres/MinIO-Volumes) blieben erhalten."
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere Dograh"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden – nichts zu tun."
        return 0
    fi
    CT_ID="$ct_id"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "ALLE Daten gehen verloren: Agenten, Accounts, Postgres, Voice-Audio (MinIO)."
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.\n  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id entfernt."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status Dograh"
    info "Installer-Version: v${INSTALLER_VERSION}"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
        info "Installieren:  ${ONE_LINER}"
        return 0
    fi
    CT_ID="$ct_id"

    pct list 2>/dev/null | awk -v id="$ct_id" '$1==id {print "Container:  " $1 " (" $2 ") – " $NF}'

    # Gestoppten CT nicht als "Service läuft nicht" fehldeklarieren
    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Service/Stack/Web-UI ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet dograh 2>/dev/null; then
        ok "Service:   dograh läuft (systemctl is-active)"
    else
        err "Service:   dograh läuft NICHT"
        info "Logs:      pct exec $ct_id -- journalctl -u dograh -e"
    fi

    local ps_out=""
    ps_out=$(pct exec "$ct_id" -- docker compose --project-directory /opt/dograh ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)
    if [[ -n "$ps_out" ]]; then
        info "Stack:     $(echo "$ps_out" | tr '\n' ' ' | sed 's/ $//')"
    else
        warn "Stack:     docker compose ps lieferte nichts (Stack noch nie gestartet?)"
    fi

    local signup ip code=""
    signup=$(pct exec "$ct_id" -- sed -n 's/^ENABLE_SIGNUP=//p' "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
    if [[ "$signup" == "true" ]]; then
        warn "Signup:    OFFEN (nach dem ersten Account schließen: ENABLE_SIGNUP=false in ${APP_DIR}/.env + --update)"
    else
        ok "Signup:    geschlossen (ENABLE_SIGNUP=${signup:-unbekannt})"
    fi

    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${UI_PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-UI:    http://${ip}:${UI_PORT}  (HTTP 200)"
        else
            warn "Web-UI:    HTTP-Code ${code:-unbekannt} von http://${ip}:${UI_PORT}"
        fi
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${API_PORT}/api/v1/health" || true)
        if [[ "$code" == "200" ]]; then
            ok "API:       http://${ip}:${API_PORT}  (HTTP 200)"
        else
            warn "API:       HTTP-Code ${code:-unbekannt} von http://${ip}:${API_PORT}"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
parse_args "$@"

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi
