#!/usr/bin/env bash
# =============================================================================
#  🧪 Dograh-Proxmox – Mock-Harness
#  Testet install/dograh.sh End-to-End gegen gemockte Proxmox-/Docker-Umgebung:
#   - `unshare -rm` mappt den Harness-User auf root (EUID-Prüfung des Scripts)
#   - pct/pveam/curl/apt/docker/systemctl/ip/hostname/getent als Mocks (Fakebin)
#   - Inner-Script läuft ECHT (nur Pfade auf Mock-Root umgeschrieben, Docker &
#     systemctl gemockt) – inkl. Bootstrap-Reihenfolge (nacktes Debian: kein
#     curl, kein docker → apt "installiert" curl, get.docker.com docker)
#  Usage: bash harness/run.sh [-v]   (Exit 0 = alle Cases grün)
# =============================================================================
set -u
SCRIPT="/home/phil/Proxmox-Scripts/Dograh-Proxmox/install/dograh.sh"
[[ -f "$SCRIPT" ]] || { echo "✘ Installer nicht gefunden: $SCRIPT"; exit 1; }

MK=$(mktemp -d /tmp/dograh-harness.XXXXXX)
KEEP="${HARNESS_KEEP:-0}"
trap 'if [[ "$KEEP" == "1" ]]; then echo "(Behalten: $MK)"; else rm -rf "$MK"; fi' EXIT
HS="$MK/state"                       # Mock-Status (ct_list, Calls, Hebel)
HOSTBIN="$MK/bin-host"               # Mocks für das HOST-Script
INNERBIN="$MK/bin-inner"             # Mocks für pct-exec (im CT)
CASES="$MK/cases"; mkdir -p "$HS" "$HOSTBIN" "$INNERBIN" "$CASES" \
    "$MK/etc" "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp"
CT_IP="10.120.5.42"

echo "$CT_IP" > "$HS/ct_ip"
: > "$HS/ct_list"                    # Zeilen: "VMID Status Lock-Name(=Name letztes Feld)"
echo "getent_mode=ok" > "$HS/getent_mode"

PASSED=0; FAILED=0; CUR_NAME=""; CUR_DIR=""

pass() { PASSED=$((PASSED+1)); echo "  ✔ $CUR_NAME – $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ✘ $CUR_NAME – $1"; [[ -n "${2:-}" ]] && echo "      ↳ $2"; }
skipnote() { echo "  – $CUR_NAME übersprungen: $1"; }

t()    { CUR_NAME="$1"; CUR_DIR=$(mktemp -d "$CASES/case.XXXXXX"); }
assert_exit() {
    local want="$1" got="$2"
    if [[ "$got" == "$want" ]]; then pass "exit=$got (erwartet $want)"
    else fail "exit=$got, erwartet $want"; fi
}
assert_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then pass "Ausgabe enthält: $1"
    else fail "Ausgabe enthält NICHT: $1"; fi
}
assert_no_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then fail "Ausgabe enthält (sollte nicht): $1"
    else pass "Ausgabe enthält nicht: $1"; fi
}
assert_file() {
    if [[ -f "$1" ]]; then pass "Datei: $1"
    else fail "Datei fehlt: $1"; fi
}
assert_no_file() {
    if [[ -f "$1" ]]; then fail "Datei existiert (sollte nicht): $1"
    else pass "Datei fehlt (korrekt): $1"; fi
}
assert_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then pass "$1 enthält: $2"
    else fail "$1 enthält NICHT: $2"; fi
}
assert_fregex() {
    if [[ -f "$1" ]] && /bin/grep -qE -- "$2" "$1"; then pass "$1 matcht: $2"
    else fail "$1 matcht NICHT: $2"; fi
}
assert_calls() { # COUNT needle in mock-calls log (host-mocks: pct/systemctl/apt)
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Calls ≥$want: $needle (ist $got)"
    else fail "Calls <$want: $needle (ist $got)"; fi
}
assert_docker() { # COUNT needle in docker_calls.log (docker compose …)
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/docker_calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Docker-Calls ≥$want: $needle (ist $got)"
    else fail "Docker-Calls <$want: $needle (ist $got)"; fi
}
assert_no_calls() {
    if /bin/grep -qF -- "$1" "$HS/calls.log" 2>/dev/null; then fail "Unerwarteter Call: $1"
    else pass "Kein Call: $1"; fi
}
dump_case() {
    echo "---- out.log ($CUR_NAME) ----"; tail -n 40 "$CUR_DIR/out.log" 2>/dev/null
    echo "---- calls.log ----"; tail -n 25 "$HS/calls.log" 2>/dev/null
}

# ── Mock-Umgebung bauen (env -i: Profil-Funktionen wie grep→ugrep meiden) ──
realbin() { env -i /bin/sh -c "command -v $1" || { echo "✘ real binary fehlt: $1"; exit 1; }; }
link_real() { # echte Binaries per Symlink verfügbar halten (Shadowing via PATH-Reihenfolge)
    local dest="$1"; shift
    local b
    for b in "$@"; do ln -sf "$(realbin "$b")" "$dest/$b"; done
}
link_real "$HOSTBIN" bash sh env awk sed grep cut head tail tr od mktemp tee openssl \
    seq cat mv cp rm mkdir chmod dirname basename sort uniq readlink date printf ls touch \
    stat id uname hostname
ln -sf "$MK/mock-curl"  "$HOSTBIN/curl"
ln -sf "$MK/mock-pct"   "$HOSTBIN/pct"
ln -sf "$MK/mock-pveam" "$HOSTBIN/pveam"
ln -sf "$MK/mock-sleep" "$HOSTBIN/sleep"
ln -sf "$MK/mock-sleep" "$INNERBIN/sleep"

# ── Inner-Fakebin: nacktes Debian simulieren (KEIN curl, KEIN docker) ──────
# PATH im Inner ist AUSSCHLIESSLICH $INNERBIN (kein /usr/bin!) – sonst würde
# ein echtes curl/docker des Desktops das Bootstrap-Design aushebeln.
link_real "$INNERBIN" bash sh env awk sed grep cut head tail tr od seq cat mv cp rm \
    mkdir chmod dirname basename sort uniq printf ls touch readlink stat uname \
    tee openssl wc ln
ln -sf "$MK/mock-aptget"    "$INNERBIN/apt-get"
ln -sf "$MK/mock-systemctl" "$INNERBIN/systemctl"
ln -sf "$MK/mock-ip"        "$INNERBIN/ip"
ln -sf "$MK/mock-hostname"  "$INNERBIN/hostname"
ln -sf "$MK/mock-getent"    "$INNERBIN/getent"
ln -sf "$MK/mock-curl"      "$MK/mock-curl.src" 2>/dev/null || true

seed_inner_tools() { # simuliert bereits installiertes curl+docker (Update-Pfad)
    ln -sf "$MK/mock-curl"   "$INNERBIN/curl"
    ln -sf "$MK/mock-docker" "$INNERBIN/docker"
}
unseed_inner_tools() {
    rm -f "$INNERBIN/curl" "$INNERBIN/docker"
}

# ══════════════════════════ Mock-Binaries ══════════════════════════════════
cat > "$MK/mock-sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MK/mock-pct" <<'EOF'
#!/usr/bin/env bash
# pct-Mock: State in $HARNESS_STATE, Mock-Root = dirname davon
set -u
HS="${HARNESS_STATE:?HARNESS_STATE fehlt}"
MK="$(dirname "$HS")"
echo "pct $*" >> "$HS/calls.log"
cmd="${1:-}"; id="${2:-}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ $# -gt 0 ]]; then shift; fi

case "$cmd" in
    list)
        printf 'VMID       Status     Lock Name\n'
        [[ -s "$HS/ct_list" ]] && cat "$HS/ct_list"
        exit 0 ;;
    status)
        f="$HS/ct_${id}.status"
        [[ -f "$f" ]] || exit 2
        echo "status: $(cat "$f")"; exit 0 ;;
    create)
        # pct create ID TEMPLATE --flags...
        echo "pct $*" >> "$HS/calls.log"
        if [[ -f "$HS/create_fail" ]]; then echo "mock: create fehlgeschlagen" >&2; exit 255; fi
        tmpl="$1"; shift
        tmpl_base="${tmpl##*/}"
        if [[ ! -f "$HS/templates/$tmpl_base" ]]; then
            echo "mock: Template $tmpl nicht vorhanden" >&2; exit 2
        fi
        { echo "TEMPLATE=$tmpl"; echo "ARGS=$*"; } > "$HS/ct_${id}.create"
        hostname="ct-$id"
        prev=""
        for a in "$@"; do
            if [[ "$prev" == "--hostname" ]]; then hostname="$a"; fi
            prev="$a"
        done
        echo "$id running $hostname" >> "$HS/ct_list"
        echo "running" > "$HS/ct_${id}.status"
        echo "$hostname" > "$HS/ct_${id}.hostname"
        exit 0 ;;
    start)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "running" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id running $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    stop)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "stopped" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id stopped $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    destroy)
        /bin/sed -i "/^$id /d" "$HS/ct_list"
        rm -f "$HS/ct_${id}".status "$HS/ct_${id}".create "$HS/ct_${id}".hostname
        exit 0 ;;
    push)
        src="$1"; dst="$2"; shift 2
        mkdir -p "$MK$(dirname "$dst")"
        # Inner-Script: /etc/ und /tmp/-Pfade auf Mock-Root umschreiben.
        # Reihenfolge WICHTIG: /tmp zuerst – die /etc-Ersetzung injiziert selbst
        # ein /tmp/ (Mock-Root liegt unter /tmp) und würde doppelt umgeschrieben.
        /bin/sed -e "s|/tmp/|$MK/tmp/|g" -e "s|/etc/|$MK/etc/|g" "$src" > "$MK$dst"
        exit 0 ;;
    exec)
        # pct exec ID -- env K=V... cmd...   (Grube 10: gestoppter CT → Exit 255)
        [[ "${1:-}" == "--" ]] && shift
        envs=()
        if [[ "${1:-}" == "env" ]]; then
            shift
            while [[ "${1:-}" == *=* && "${1:-}" != -* ]]; do envs+=("$1"); shift; done
        fi
        if [[ ! -f "$HS/ct_${id}.status" || "$(cat "$HS/ct_${id}.status" 2>/dev/null)" != "running" ]]; then
            echo "mock: CT $id läuft nicht" >&2
            echo "pct exec $id (ABGELEHNT – CT gestoppt)" >> "$HS/calls.log"
            exit 255
        fi
        if [[ -f "$HS/exec_fail" ]]; then
            echo "mock: exec erzwingt Fehler" >&2
            exit 255
        fi
        # Quoted-Heredoc: INNERBIN erst zur LAUFZEIT ableiten ($MK = dirname($HS))
        INNERBIN="$MK/bin-inner"
        # Pfad-Umschreibung: Kommando-Args UND env-Args (Mock-Root).
        # /etc auch umschreiben – sonst schreibt der DNS-Fallback des Installers
        # ins echte /etc der Sandbox!
        rewrite_path() {
            local a="$1"
            a="${a//\/opt\/dograh/$MK/opt/dograh}"
            a="${a//\/root\//$MK/root/}"
            a="${a//\/var\/log/$MK/var/log}"
            a="${a//\/etc\//$MK/etc/}"
            printf '%s' "$a"
        }
        newargs=()
        for a in "$@"; do
            newargs+=("$(rewrite_path "$a")")
        done
        newenvs=()
        for a in ${envs[@]+"${envs[@]}"}; do
            newenvs+=("$(rewrite_path "$a")")
        done
        exec env -i PATH="$INNERBIN" \
            HARNESS_STATE="$HS" MKROOT="$MK" \
            HOME=/root TERM=dumb LANG=C.UTF-8 \
            ${newenvs[@]+"${newenvs[@]}"} \
            "${newargs[@]}"
        ;;
    enter|config|rollback|clone|resume|suspend|reboot|snapshot|delvolume|mount|resize|move|reindex|set)
        exit 0 ;;
    *)
        echo "mock-pct: unbekannter Befehl $cmd" >&2; exit 1 ;;
esac
EOF

cat > "$MK/mock-pveam" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "pveam $*" >> "$HS/calls.log"
TMPL="local:vztmpl/debian-13-standard_13.2-1_amd64.tar.zst"
case "${1:-}" in
    list)
        if [[ -f "$HS/template_downloaded" && ! -f "$HS/pveam_empty" ]]; then
            echo "$TMPL  123456789"
        fi
        exit 0 ;;
    available)
        if [[ ! -f "$HS/pveam_empty" ]]; then
            echo "system          $TMPL  123456789"
        fi
        exit 0 ;;
    update)   exit 0 ;;
    download)
        mkdir -p "$HS/templates"
        touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
        touch "$HS/template_downloaded"
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-curl" <<'EOF'
#!/usr/bin/env bash
# curl-Mock: gesundheitschecks → 200/000; Downloads → Fixture-Dateien
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
url=""; outfile=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "-o" ]]; then outfile="$a"; fi
    case "$a" in http://*|https://*) url="$a" ;; esac
    prev="$a"
done
echo "curl $*" >> "$HS/calls.log" 2>/dev/null || true

case "$url" in
    https://get.docker.com)
        # get.docker.com-Stub: "installiert" docker + compose-plugin (Mock)
        [[ -n "$outfile" ]] || { echo "curl mock: get.docker.com ohne -o" >&2; exit 1; }
        cat > "$outfile" <<'STUB'
#!/usr/bin/env bash
# get.docker.com-Mock-Stub: installiert docker-CLI + compose-plugin
INNERBIN_DIR="${MKROOT:?MKROOT fehlt}/bin-inner"
ln -sf "$MKROOT/mock-docker" "$INNERBIN_DIR/docker" 2>/dev/null
exit 0
STUB
        chmod +x "$outfile"
        exit 0 ;;
    https://raw.githubusercontent.com/dograh-hq/dograh/*)
        [[ -n "$outfile" ]] || { echo "curl mock: compose-URL ohne -o" >&2; exit 1; }
        cat > "$outfile" <<'YAML'
# Fixture (gekürzte upstream docker-compose.yaml)
services:
  postgres:
    image: pgvector/pgvector:pg17
    ports: ["5432:5432"]
  redis:
    image: redis:7
    ports: ["6379:6379"]
  minio:
    image: dograhai/minio:2026.09.22
    ports: ["127.0.0.1:9000:9000", "127.0.0.1:9001:9001"]
  api:
    image: dograhai/dograh-api:latest
    ports: ["8000:8000"]
    environment:
      OSS_JWT_SECRET: "${OSS_JWT_SECRET:?OSS_JWT_SECRET must be set}"
  ui:
    image: dograhai/dograh-ui:latest
    ports: ["3010:3010"]
YAML
        exit 0 ;;
esac

# Health-/HTTP-Checks (Reihenfolge: API/MinIO vor generischem Loopback!)
# host_curl_fail gilt NUR auf Host-Ebene (inner erkennt man an MKROOT)
code="200"
if [[ -f "$HS/host_curl_fail" && -z "${MKROOT:-}" ]]; then
    code="000"
fi
# Next.js-UI antwortet auf / mit 307 (Redirect auf Login) — NUR curl mit -L
# folgt dem Redirect (Live-Fund 2026-11-18: Installer starb an 307 statt 200)
has_L="false"
for a in "$@"; do
    if [[ "$a" == "-L" || "$a" == -*L && "$a" != -*L*=* ]]; then has_L="true"; fi
done
case "$url" in
    *"/api/v1/health")    [[ -f "$HS/fail_api"   ]] && code="000" ;;
    *"minio/health/live") [[ -f "$HS/fail_minio" ]] && code="000" ;;
    http://127.0.0.1:*)
        if [[ "$has_L" != "true" ]]; then code="307"; fi
        [[ -f "$HS/fail_ui" ]] && code="000" ;;
esac
echo "$code"
[[ "$code" == "200" || "$code" == "307" ]] && exit 0 || exit 7
EOF

cat > "$MK/mock-docker" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "docker $*" >> "$HS/docker_calls.log"
sub="${1:-}"
case "$sub" in
    --version|-v) echo "Docker version 27.5.1, build mock"; exit 0 ;;
    info) exit 0 ;;
    ps)
        # `docker ps --filter label=… --format …` (lockfrei, Verifikation/Status)
        [[ -f "$HS/ps_empty" ]] && exit 0
        if [[ -f "$HS/stack_up" ]]; then
            printf 'dograh-postgres-1 running\ndograh-redis-1 running\nminio running\ndograh-api-1 running\ndograh-ui-1 running\n'
        fi
        exit 0 ;;
    compose)
        shift  # "compose"
        # globale Flags mit Werten überspringen (--project-directory DIR, --file F)
        while [[ "${1:-}" == --* ]]; do
            case "$1" in
                --project-directory|--file|-f) shift 2 ;;
                *) shift ;;
            esac
        done
        c="${1:-}"
        case "$c" in
            version) echo "Docker Compose version v2.39.2"; exit 0 ;;
            config)
                [[ -f "$HS/docker_config_fail" ]] && exit 1
                exit 0 ;;
            pull)   exit 0 ;;
            up)     touch "$HS/stack_up"; exit 0 ;;
            stop)   rm -f "$HS/stack_up"; exit 0 ;;
            ps)
                [[ -f "$HS/ps_empty" ]] && exit 0
                if [[ -f "$HS/stack_up" ]]; then
                    printf 'postgres running\nredis running\nminio running\napi running\nui running\n'
                fi
                exit 0 ;;
            logs)   echo "mock-compose-log-line"; exit 0 ;;
            *)      exit 0 ;;
        esac ;;
    *) echo "mock-docker: $sub (ignored)"; exit 0 ;;
esac
EOF

cat > "$MK/mock-systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
echo "systemctl $*" >> "$HS/calls.log"
MKDIR_MOCK="$MK"
unitdir="$MKDIR_MOCK/etc/systemd/system"
sub="${1:-}"
case "$sub" in
    daemon-reload) exit 0 ;;
    enable)
        mkdir -p "$unitdir"; echo "${2:-}" >> "$HS/enabled_units"; exit 0 ;;
    start)
        if [[ "${2:-}" == "dograh" ]]; then
            [[ -f "$unitdir/dograh.service" ]] || { echo "mock: dograh.service fehlt" >&2; exit 1; }
            touch "$HS/dograh_active"
        elif [[ "${2:-}" == "docker" ]]; then
            touch "$HS/docker_active"
        fi
        exit 0 ;;
    stop)
        rm -f "$HS/dograh_active" "$HS/docker_active"; exit 0 ;;
    is-active)
        svc="${3:-${2:-}}"
        if [[ "$svc" == "dograh" && -f "$HS/dograh_active" ]]; then exit 0; fi
        if [[ "$svc" == "docker" && -f "$HS/docker_active" ]]; then exit 0; fi
        exit 3 ;;
    status) echo "mock: ${2:-} active-ish"; exit 0 ;;
    *) exit 0 ;;
esac
EOF

cat > "$MK/mock-ip" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.42")
printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq state UP group default qlen 1000\n'
printf '    inet %s/24 scope global eth0\n       valid_lft forever preferred_lft forever\n' "$IP"
exit 0
EOF

cat > "$MK/mock-hostname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_hostname_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.42")
if [[ "${1:-}" == "-I" ]]; then printf '%s 2601:db8::1 \n' "$IP"; exit 0; fi
echo "dograh"; exit 0
EOF

cat > "$MK/mock-getent" <<'EOF'
#!/usr/bin/env bash
# DNS-Mock: ok | fail | flaky (jeder 4. failt) | fail_then_ok (12x fail, dann ok)
set -u
HS="${HARNESS_STATE:?}"
mode="ok"
[[ -f "$HS/getent_mode" ]] && mode=$(/bin/sed -n 's/^getent_mode=//p' "$HS/getent_mode")
case "$mode" in
    ok) exit 0 ;;
    fail) exit 2 ;;
    flaky)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        if [[ $((n % 4)) -eq 0 ]]; then exit 2; fi
        exit 0 ;;
    fail_then_ok)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        # 9x fail → Loop bricht bei Try 10 ab → Fallback → Post-Check (Call 10) erfolgreich
        [[ "$n" -le 9 ]] && exit 2
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-aptget" <<'EOF'
#!/usr/bin/env bash
# apt-Mock: installiert curl real in der Inner-Fakebin (Bootstrap-Reihenfolge)
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
INNERBIN_DIR="$MK/bin-inner"
echo "apt-get $*" >> "$HS/calls.log"
if [[ "${1:-}" == "install" ]]; then
    for a in "$@"; do
        if [[ "$a" == "curl" && ! -e "$INNERBIN_DIR/curl" ]]; then
            ln -sf "$MK/mock-curl" "$INNERBIN_DIR/curl"
        fi
        if [[ "$a" == docker* && ! -e "$INNERBIN_DIR/docker" ]]; then
            ln -sf "$MK/mock-docker" "$INNERBIN_DIR/docker"
        fi
    done
fi
exit 0
EOF

chmod +x "$MK"/mock-* "$MK"/bin-host/* "$MK"/bin-inner/* 2>/dev/null

# ── Runner ─────────────────────────────────────────────────────────────────
reset_state() {
    rm -rf "$HS"; mkdir -p "$HS" "$HS/templates" "$MK/etc/systemd/system" "$MK/etc/dhcp" \
        "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp"
    echo "$CT_IP" > "$HS/ct_ip"
    : > "$HS/ct_list"
    echo "getent_mode=ok" > "$HS/getent_mode"
}
run_installer() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_stdin() {
    local input="$1"; shift
    ( printf '%s' "$input" | unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_devnull() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" < /dev/null > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
seed_ct() { # laufender CT mit installiertem Stack
    reset_state
    echo "200 running dograh" > "$HS/ct_list"
    echo "running" > "$HS/ct_200.status"
    echo "dograh" > "$HS/ct_200.hostname"
    mkdir -p "$MK/opt/dograh" "$MK/etc/systemd/system" "$MK/etc" "$MK/var/log"
    seed_inner_tools
    touch "$HS/stack_up" "$HS/dograh_active" "$HS/template_downloaded"
    touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
    touch "$MK/etc/systemd/system/dograh.service"
    cat > "$MK/opt/dograh/.env" <<ENVSEED
OSS_JWT_SECRET=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
POSTGRES_PASSWORD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
REDIS_PASSWORD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
MINIO_ROOT_USER=dograhfixeduser12
MINIO_ROOT_PASSWORD=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
REGISTRY=ghcr.io/dograh-hq
ENABLE_TELEMETRY=false
ENABLE_SIGNUP=true
FASTAPI_WORKERS=1
ENVIRONMENT=local
DOGRAH_UI_PORT=3010
BACKEND_API_ENDPOINT=http://10.120.5.42:8000
MINIO_PUBLIC_ENDPOINT=http://10.120.5.42:9000
SERVER_IP=10.120.5.42
ENVSEED
}

ENV_PATH="$MK/opt/dograh/.env"

echo "════════════════════════════════════════════════════════════"
echo " 🧪 Dograh-Proxmox Harness – $(date +%H:%M:%S)"
echo "════════════════════════════════════════════════════════════"

# ════════════════ A. Argumente & Grundlagen ════════════════
t "--help"
ec=$(run_installer --help); assert_exit 0 "$ec"
assert_out "Dograh – Proxmox-Installer"
assert_out "--update"

t "unbekannte Option"
ec=$(run_installer --schnulli); assert_exit 1 "$ec"
assert_out "Unbekannte Option: --schnulli"

t "--port ungültig"
ec=$(run_installer --port abc); assert_exit 1 "$ec"
assert_out "Ungültiger UI-Port: 'abc'"

t "--port == API-Port"
ec=$(run_installer --port 8000); assert_exit 1 "$ec"
assert_out "dürfen nicht identisch sein"

t "\$0-Fallback (bash -c-Muster)"
ec=$( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
      bash -c "$(<"$SCRIPT")" --status > "$CUR_DIR/out.log" 2>&1; echo $? )
assert_exit 0 "$ec"
assert_out "Status Dograh"

t "nächste freie CT-ID (200-202 belegt)"
reset_state
printf '200 running foo\n201 running bar\n202 running baz\n' > "$HS/ct_list"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Nächste freie CT-ID: 203"
assert_fcontains "$HS/ct_203.create" "hostname dograh"

t "pct list ohne Lock-Spalte (Name \$NF)"
reset_state
printf '200 running dograh\n' > "$HS/ct_list"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Container:  200 (running) – dograh"

t "pct list mit doppeltem Leerzeichen (Lock leer)"
reset_state
printf '200 running  dograh\n' > "$HS/ct_list"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Container:  200 (running) – dograh"

# ════════════════ B. Install Happy Path ════════════════
t "Install End-to-End (nacktes Debian: curl+docker bootstrappen)"
reset_state
unseed_inner_tools
ec=$(run_installer); assert_exit 0 "$ec"

assert_out "Container-IP: $CT_IP"
assert_out "DNS im Container funktioniert (3x bestätigt)"
assert_out "debian-13-standard_13.2"
assert_calls 1 "pct create 200"
assert_fcontains "$HS/ct_200.create" "unprivileged"
assert_fcontains "$HS/ct_200.create" "nesting=1,keyctl=1"
assert_fcontains "$HS/ct_200.create" "onboot 1"
assert_fcontains "$HS/ct_200.create" "memory 4096"
assert_fcontains "$HS/ct_200.create" "swap 1024"
assert_fregex "$HS/ct_200.create" "rootfs local-lvm:24"
assert_fcontains "$HS/ct_200.create" "firewall=0"
assert_calls 1 "apt-get install -y -qq curl"
assert_calls 1 "get.docker.com"
assert_file "$MK/opt/dograh/docker-compose.yaml"
assert_file "$MK/opt/dograh/docker-compose.override.yaml"
assert_file "$MK/opt/dograh/sync-backend-url.sh"
assert_file "$MK/etc/systemd/system/dograh.service"
assert_file "$MK/var/log/dograh-setup.log"
assert_calls 1 "systemctl enable dograh"
assert_calls 1 "systemctl start dograh"
[[ -f "$HS/dograh_active" ]] && pass "Service aktiv nach Install" || fail "dograh_active fehlt"
[[ -f "$HS/stack_up" ]] && pass "Compose-Stack up" || fail "stack_up fehlt"

# Zusammenfassung-Asserts laufen im selben out.log wie Install E2E (t nicht neu anlegen)
assert_out "🎙️  Dograh ist bereit!"
assert_out "http://$CT_IP:3010"
assert_out "http://$CT_IP:8000"
assert_out "Service dograh läuft (systemctl is-active)"
assert_out "Alle Compose-Services laufen (postgres, redis, minio, api, ui)"
assert_out "Web-UI antwortet (HTTP 200 auf Port 3010)"
assert_out "API gesund (HTTP 200 auf Port 8000)"
assert_out "Vom Host erreichbar: http://$CT_IP:3010 (HTTP 200)"
assert_out "Status:    bash -c"
assert_out "Update:    bash -c"
assert_out "Deinstall: bash -c"

t ".env vollständig & Secrets-Format"
assert_fregex "$ENV_PATH" '^OSS_JWT_SECRET=[0-9a-f]{64}$'
assert_fregex "$ENV_PATH" '^POSTGRES_PASSWORD=[0-9a-f]{64}$'
assert_fregex "$ENV_PATH" '^REDIS_PASSWORD=[0-9a-f]{64}$'
assert_fregex "$ENV_PATH" '^MINIO_ROOT_USER=dograh[0-9a-f]{12}$'
assert_fregex "$ENV_PATH" '^MINIO_ROOT_PASSWORD=[0-9a-f]{64}$'
assert_fcontains "$ENV_PATH" "REGISTRY=ghcr.io/dograh-hq"
assert_fcontains "$ENV_PATH" "ENABLE_TELEMETRY=false"
assert_fcontains "$ENV_PATH" "ENABLE_SIGNUP=true"
assert_fcontains "$ENV_PATH" "FASTAPI_WORKERS=1"
assert_fcontains "$ENV_PATH" "ENVIRONMENT=local"
assert_fcontains "$ENV_PATH" "DOGRAH_UI_PORT=3010"
assert_fcontains "$ENV_PATH" "BACKEND_API_ENDPOINT=http://$CT_IP:8000"
assert_fcontains "$ENV_PATH" "MINIO_PUBLIC_ENDPOINT=http://$CT_IP:9000"
assert_fcontains "$ENV_PATH" "SERVER_IP=$CT_IP"
perms=$(stat -c '%a' "$ENV_PATH" 2>/dev/null || echo "?")
[[ "$perms" == "600" ]] && pass ".env chmod 600" || fail ".env chmod: $perms (600 erwartet)"

t "Override-Datei: Ports/Härtung/Restart"
OV="$MK/opt/dograh/docker-compose.override.yaml"
assert_fcontains "$OV" 'postgres:'
assert_fcontains "$OV" 'ports: !override ["127.0.0.1:5432:5432"]'
assert_fcontains "$OV" 'ports: !override ["127.0.0.1:6379:6379"]'
assert_fcontains "$OV" 'ports: !override ["9000:9000"]'
assert_fcontains "$OV" 'ports: !override ["8000:8000"]'
assert_fcontains "$OV" 'ports: !override ["${DOGRAH_UI_PORT:-3010}:3010"]'
n_restart=$(/bin/grep -c 'restart: unless-stopped' "$OV" || true)
[[ "$n_restart" -ge 5 ]] && pass "5x restart: unless-stopped" || fail "restart-Policies: nur $n_restart"

t "systemd-Unit: detached Bootstrap + Prod-Pfade"
UNIT="$MK/etc/systemd/system/dograh.service"
assert_fcontains "$UNIT" "Type=oneshot"
assert_fcontains "$UNIT" "RemainAfterExit=yes"
assert_fcontains "$UNIT" "ExecStartPre=/opt/dograh/sync-backend-url.sh"
assert_fcontains "$UNIT" "ExecStart=/usr/bin/docker compose --project-directory /opt/dograh up -d --pull=missing"
assert_fcontains "$UNIT" "After=network-online.target docker.service"
assert_fcontains "$UNIT" "WantedBy=multi-user.target"

t "Sync-Script: dirname-basiert + ausführbar"
SYNC="$MK/opt/dograh/sync-backend-url.sh"
assert_fcontains "$SYNC" 'BASH_SOURCE[0]'
assert_no_fcontains() { if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then fail "$1 enthält (sollte nicht): $2"; else pass "$1 ohne: $2"; fi; }
assert_no_fcontains "$SYNC" "cd /opt/dograh"
perms=$(stat -c '%a' "$SYNC" 2>/dev/null || echo "?")
[[ "$perms" == "755" || "$perms" == "775" ]] && pass "sync-backend-url.sh chmod $perms" || fail "sync chmod: $perms"


t "Install mit --port 4545"
reset_state; unseed_inner_tools
ec=$(run_installer --port 4545); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "DOGRAH_UI_PORT=4545"
assert_fcontains "$MK/opt/dograh/docker-compose.override.yaml" '${DOGRAH_UI_PORT:-4545}:3010'
assert_out "http://$CT_IP:4545"

t "Install mit --telemetry"
reset_state; unseed_inner_tools
ec=$(run_installer --telemetry); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "ENABLE_TELEMETRY=true"

t "Install mit statischer IP (--ip)"
reset_state; unseed_inner_tools
echo "192.168.178.77" > "$HS/ct_ip"   # ip/hostname-Mock liefern die statische IP
ec=$(run_installer --ip 192.168.178.77/24 --gateway 192.168.178.1); assert_exit 0 "$ec"
cp "$HS/ct_200.create" "$CUR_DIR/create.snapshot" 2>/dev/null || true
assert_fcontains "$CUR_DIR/create.snapshot" "ip=192.168.178.77/24,gateway=192.168.178.1"
assert_out "http://192.168.178.77:3010"
assert_fcontains "$ENV_PATH" "BACKEND_API_ENDPOINT=http://192.168.178.77:8000"

# ════════════════ C. Update / Idempotenz ════════════════
t "--update: Secrets bleiben erhalten"
seed_ct
cat > "$ENV_PATH" <<ENVSEED
OSS_JWT_SECRET=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
POSTGRES_PASSWORD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
REDIS_PASSWORD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
MINIO_ROOT_USER=dograhfixeduser12
MINIO_ROOT_PASSWORD=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
REGISTRY=ghcr.io/dograh-hq
ENABLE_TELEMETRY=false
ENABLE_SIGNUP=false
FASTAPI_WORKERS=2
ENVIRONMENT=local
DOGRAH_UI_PORT=3010
BACKEND_API_ENDPOINT=http://$CT_IP:8000
MINIO_PUBLIC_ENDPOINT=http://$CT_IP:9000
SERVER_IP=$CT_IP
ENVSEED
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "OSS_JWT_SECRET=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
assert_fcontains "$ENV_PATH" "POSTGRES_PASSWORD=aaaaaaaa"
assert_fcontains "$ENV_PATH" "MINIO_ROOT_USER=dograhfixeduser12"
assert_fcontains "$ENV_PATH" "ENABLE_SIGNUP=false"          # Nutzer-Änderung erhalten
assert_fcontains "$ENV_PATH" "FASTAPI_WORKERS=2"            # Nutzer-Änderung erhalten
assert_docker 1 "docker compose pull"
assert_docker 1 "docker compose up -d"
assert_calls 1 "systemctl stop dograh"
assert_calls 1 "systemctl start dograh"
assert_out "Daten (Postgres/MinIO-Volumes) blieben erhalten"

t "--update --telemetry überschreibt auf true"
seed_ct
assert_fcontains "$ENV_PATH" "ENABLE_TELEMETRY=false"
ec=$(run_installer --update --telemetry); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "ENABLE_TELEMETRY=true"

t "--update: DOGRAH_UI_PORT aus .env bleibt (ohne --port)"
seed_ct
/bin/sed -i 's/^DOGRAH_UI_PORT=.*/DOGRAH_UI_PORT=4545/' "$ENV_PATH"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "DOGRAH_UI_PORT=4545"
# Override-Fallback bleibt bei der LAUFZEIT-UI_PORT (3010) – die Interpolation
# durch compose zieht den Wert aus .env (DOGRAH_UI_PORT=4545)
assert_fcontains "$MK/opt/dograh/docker-compose.override.yaml" '${DOGRAH_UI_PORT:-3010}:3010'

t "--update mit IP-Wechsel: sync-backend-url aktualisiert .env"
seed_ct
/bin/sed -i "s|^BACKEND_API_ENDPOINT=.*|BACKEND_API_ENDPOINT=http://10.0.0.99:8000|" "$ENV_PATH"
/bin/sed -i "s|^MINIO_PUBLIC_ENDPOINT=.*|MINIO_PUBLIC_ENDPOINT=http://10.0.0.99:9000|" "$ENV_PATH"
/bin/sed -i "s|^SERVER_IP=.*|SERVER_IP=10.0.0.99|" "$ENV_PATH"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "BACKEND_API_ENDPOINT=http://$CT_IP:8000"
assert_fcontains "$ENV_PATH" "MINIO_PUBLIC_ENDPOINT=http://$CT_IP:9000"
assert_fcontains "$ENV_PATH" "SERVER_IP=$CT_IP"
assert_out "dograh-sync: CT-IP geändert"

t "sync-backend-url: gleiche IP → unverändert"
seed_ct
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_out "dograh-sync: CT-IP unverändert"
assert_fcontains "$ENV_PATH" "BACKEND_API_ENDPOINT=http://$CT_IP:8000"

t "sync-backend-url: keine IPv4 → .env unangetastet, exit 0"
seed_ct
touch "$HS/no_ip"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_out "keine globale IPv4 an eth0"
assert_fcontains "$ENV_PATH" "BACKEND_API_ENDPOINT=http://$CT_IP:8000"
rm -f "$HS/no_ip"

# ════════════════ D. Fehlerpfade ════════════════
t "docker compose config-Fehler → Kette + bash -x-Hinweis"
seed_ct
touch "$HS/docker_config_fail"
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "Installationsfehler – Exit-Code 1"
assert_out "docker compose config meldet Fehler"
assert_out "Vollständiges Log:"
assert_out "--debug"
assert_out "Neu ausführen mit vollem bash -x-Trace"
rm -f "$HS/docker_config_fail"

t "API-Health tot → die mit Debug-Hinweis"
seed_ct
touch "$HS/fail_api"
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "API antwortet nicht mit 200"
assert_out "docker compose logs --tail 50 api"
rm -f "$HS/fail_api"

t "UI-Health tot → die"
seed_ct
touch "$HS/fail_ui"
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "Web-UI antwortet nicht mit 200"
rm -f "$HS/fail_ui"

t "MinIO-Health tot → die"
seed_ct
touch "$HS/fail_minio"
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "MinIO-Healthcheck fehlgeschlagen"
rm -f "$HS/fail_minio"

t "Compose-Services fehlen (ps leer trotz up)"
seed_ct
touch "$HS/ps_empty"
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "Compose-Services fehlen oder sind nicht hochgekommen"
rm -f "$HS/ps_empty"

t "keine Container-IP → Fehlerkette (on_error)"
reset_state
touch "$HS/no_hostname_ip"   # hostname -I bleibt leer → Poll läuft 60x leer → on_error
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Container hat nach 60 s keine IP bekommen"
assert_out "Installationsfehler – Exit-Code 1"
assert_out "Fehlgeschlagener Befehl"
assert_out "Container 200 wurde NICHT gelöscht"
assert_out "pct enter 200"
rm -f "$HS/no_hostname_ip"

t "pct exec Exit 255 (Grube 10) → Kette"
reset_state
touch "$HS/exec_fail"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Installationsfehler – Exit-Code 1"
rm -f "$HS/exec_fail"

t "DNS total defekt → die mit Fallback-Diagnose"
reset_state
echo "getent_mode=fail" > "$HS/getent_mode"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "DNS im Container weiterhin ohne Funktion"
assert_out "ausgehende DNS-Anfragen (Port 53)"
assert_file "$MK/etc/dhcp/dhclient-enter-hooks.d/no-dns"

t "DNS flaky → Fallback + dhclient-Hook, dann Erfolg"
reset_state
echo "getent_mode=fail_then_ok" > "$HS/getent_mode"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt"
assert_file "$MK/etc/dhcp/dhclient-enter-hooks.d/no-dns"

t "Template komplett fehlend → die"
reset_state
touch "$HS/pveam_empty"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Kein debian-12/13-standard-Template gefunden"
rm -f "$HS/pveam_empty"

t "Template-Download-Pfad (list leer, available da)"
reset_state
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Kein Debian-12/13-Template vorhanden – lade es herunter"
assert_calls 1 "pveam download local"
assert_calls 1 "pct create 200"

t "existierender CT ohne --force → die mit Update-Hinweis"
seed_ct
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "existiert bereits"
assert_out "--update"

t "--force: destroy + recreate"
seed_ct
ec=$(run_installer --force); assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_calls 1 "pct create 200"
assert_out "existiert – --force: lösche und lege neu an"

t "--update ohne CT → die"
reset_state
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "Kein Container mit Hostname 'dograh' gefunden"
assert_out "Erst installieren"

t "nicht-root (EUID-Check via env ohne unshare)"
ec=$( env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" HARNESS_STATE="$HS" HOME=/root TERM=dumb \
      bash "$SCRIPT" > "$CUR_DIR/out.log" 2>&1; echo $? )
assert_exit 1 "$ec"
assert_out "Bitte als root ausführen"

# ════════════════ E. Uninstall ════════════════
t "--uninstall ohne CT"
reset_state
ec=$(run_installer --uninstall); assert_exit 0 "$ec"
assert_out "nichts zu tun"

t "--uninstall mit Bestätigung 'ja'"
seed_ct
ec=$(run_installer_stdin $'ja\n' --uninstall); assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_no_file "$HS/ct_200.status"
assert_out "Container 200 entfernt."

t "--uninstall mit 'nein' → Abbruch"
seed_ct
ec=$(run_installer_stdin $'nein\n' --uninstall); assert_exit 0 "$ec"
assert_out "Abgebrochen – nichts gelöscht."
assert_file "$HS/ct_200.status"
assert_no_calls "pct destroy"

t "--uninstall nicht-interaktiv → die"
seed_ct
ec=$(run_installer_devnull --uninstall); assert_exit 1 "$ec"
assert_out "Keine Bestätigung erhalten"
assert_out "--uninstall --yes"
assert_file "$HS/ct_200.status"

t "--uninstall --yes (ohne Rückfrage)"
seed_ct
ec=$(run_installer --uninstall --yes); assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_out "Container 200 entfernt."

# ════════════════ F. Update-Verwaltungswege ════════════════
t "--update auf gestopptem CT → startet ihn selbst (Grube 10)"
seed_ct
echo "stopped" > "$HS/ct_200.status"
/bin/sed -i "s/^200 .*/200 stopped dograh/" "$HS/ct_list"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_calls 1 "pct start 200"
assert_out "läuft nicht (Status: stopped) – starte ihn"
assert_out "Update abgeschlossen"

t "--status: laufender Stack + Signup offen"
seed_ct
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Service:   dograh läuft"
assert_out "Stack:     dograh-postgres-1 running"
assert_out "Signup:    OFFEN"
assert_out "Web-UI:    http://$CT_IP:3010  (HTTP 200)"
assert_out "API:       http://$CT_IP:8000  (HTTP 200)"

t "--status: Signup geschlossen"
seed_ct
/bin/sed -i 's/^ENABLE_SIGNUP=.*/ENABLE_SIGNUP=false/' "$ENV_PATH"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Signup:    geschlossen"

t "--status: gestoppter CT"
seed_ct
echo "stopped" > "$HS/ct_200.status"
/bin/sed -i "s/^200 .*/200 stopped dograh/" "$HS/ct_list"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "nicht gestartet (stopped)"
assert_out "pct start 200"

t "--status: CT fehlt"
reset_state
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Kein Container mit Hostname 'dograh' gefunden."
assert_out "Installieren:  bash -c"

t "Host-Check tot → warn, install trotzdem exit 0"
seed_ct
touch "$HS/host_curl_fail"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_out "vom Proxmox-Host nicht erreichbar (HTTP 000"
rm -f "$HS/host_curl_fail"

t "sshkey-Install (--sshkey Datei)"
reset_state; unseed_inner_tools
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test@host\n' > "$MK/testkey.pub"
ec=$(run_installer --sshkey "$MK/testkey.pub"); assert_exit 0 "$ec"
assert_fcontains "$HS/ct_200.create" "ssh-public-keys"

t "sshkey-Datei fehlt → die"
reset_state
ec=$(run_installer --sshkey /nicht/da.pub); assert_exit 1 "$ec"
assert_out "SSH-Key-Datei nicht gefunden"

# ════════════════ G. Bootstrap-Reihenfolge (Grube 21) ════════════════
t "nacktes CT: apt curl-Install VOR erstem Download"
reset_state
unseed_inner_tools
: > "$HS/calls.log"
ec=$(run_installer); assert_exit 0 "$ec"
first_apt=$(/bin/grep -n '^apt-get ' "$HS/calls.log" | head -1 | cut -d: -f1 || echo 99999)
first_curl_download=$(/bin/grep -n '^curl .*raw.githubusercontent.com/dograh' "$HS/calls.log" | head -1 | cut -d: -f1 || echo 0)
if [[ "$first_apt" -lt "$first_curl_download" ]]; then
    pass "apt-get (Zeile $first_apt) vor compose-Download (Zeile $first_curl_download)"
else
    fail "Bootstrap-Reihenfolge: apt=$first_apt, download=$first_curl_download"
fi

t "Update-CT: kein apt/get.docker nötig (bereits installiert)"
seed_ct
: > "$HS/calls.log"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_no_calls "apt-get"
assert_no_calls "get.docker.com"

# ════════════════ Zusammenfassung ════════════════
echo "════════════════════════════════════════════════════════════"
echo " 📊 Ergebnis: $PASSED bestanden, $FAILED fehlgeschlagen"
echo "════════════════════════════════════════════════════════════"
if [[ $FAILED -gt 0 ]]; then
    echo "✘ Harness ROT"
    exit 1
fi
echo "✔ Harness GRÜN"
exit 0
