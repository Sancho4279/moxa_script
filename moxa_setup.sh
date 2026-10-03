#!/usr/bin/env bash
# ==============================================================================
#  moxa_setup.sh - Konfiguration und Firmware-Update fuer Moxa Terminal-/Device-Server
# ------------------------------------------------------------------------------
#  Zielplattform : Ubuntu Desktop (bash >= 4.4)
#  Autor         : SJ
#  Version       : 1.0.0
#
#  Unterstuetzte Geraete (Familien):
#    NPORT6000  - NPort 6610-8/-16/-32, NPort 6650-8/-16/-32   (8/16/32 Port)
#    NPORT5400  - NPort 5410/5430/5450                          (4/8 Port)
#    CN2500     - CN2510-8/-16, CN2500-16   (EOL, kein MCC-Support -> gefuehrt)
#
#  Arbeitsweise:
#    1. Netz vorbereiten (temporaere IP im 192.168.127.0/24 Netz)
#    2. Geraet erkennen  (MCC-Tool / SNMP / HTTP-Fingerprint)
#    3. Firmware pruefen und ueber berechneten Upgrade-Pfad aktualisieren
#    4. Konfiguration setzen (Name, IP, Netzmaske, Gateway)
#    5. Ergebnis verifizieren und Report schreiben (Text + JSON)
#
#  Wichtige Herstellerfakten, die hier fest verdrahtet sind:
#    - MCC-Tool unterstuetzt NPort 6000 erst ab FW v1.13, NPort 5400 erst ab v3.13.
#      Aeltere Staende MUESSEN ueber die lokale Weboberflaeche angehoben werden.
#    - NPort 6000: v1.21 ist Pflicht-Zwischenschritt vor v2.0+.
#    - NPort 6000: ab v2.1 ist ein Downgrade unter v2.1 geraeteseitig gesperrt.
#    - Beim Config-Import darf "-n" NICHT gesetzt werden, sonst bleiben die alten
#      Netzwerkparameter erhalten und die neue IP wird nicht uebernommen.
# ==============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ------------------------------------------------------------------------------
# Konstanten und Vorgabewerte
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Werkseinstellung aller hier behandelten Moxa-Geraete
readonly DEFAULT_DEVICE_IP="192.168.127.254"
readonly DEFAULT_DEVICE_NET="192.168.127"
readonly DEFAULT_DEVICE_MASK="255.255.255.0"

# Ueberschreibbar per Konfigurationsdatei oder Kommandozeile
CONFIG_FILE="${MOXA_CONFIG:-${SCRIPT_DIR}/moxa_setup.conf}"
FW_DIR="${MOXA_FW_DIR:-${SCRIPT_DIR}/firmware}"
WORK_DIR="${MOXA_WORK_DIR:-${SCRIPT_DIR}/work}"
LOG_DIR="${MOXA_LOG_DIR:-${SCRIPT_DIR}/log}"
MCC_BIN="${MOXA_MCC_BIN:-}"
MCC_DIR=""

DEVICE_IP="$DEFAULT_DEVICE_IP"
DEVICE_USER="admin"
DEVICE_PASS="moxa"
# Weitere Passwoerter, die bei Anmeldefehlern durchprobiert werden.
# Reihenfolge zaehlt: die wahrscheinlichste Variante zuerst.
DEVICE_PASS_LIST=("moxa" "Be2ailoo" "admin")

# Zugangsdaten, die bei einer Erstkonfiguration automatisch gesetzt werden.
# Neue NPort-Geraete werden unkonfiguriert geliefert; das MCC-Tool verweigert
# dann Export und Import mit Code -17, bis ein Passwort existiert.
INITIAL_USER="admin"
INITIAL_PASS="moxa"
AUTH_PROBE=1               # 0 = nur die eingestellte Kombination versuchen
DEVICE_PSK="moxa"          # Pre-Shared Key fuer Config-Export/Import
STAGING_IP=""              # temporaere IP des Ubuntu-Rechners, leer = automatisch
STAGING_IFACE=""           # Netzwerkinterface, leer = automatisch ermitteln
SNMP_COMMUNITY="public"

# Betriebsmodi
DRY_RUN=0
ASSUME_YES=0
USE_TUI=1
VERBOSE=0
ACTION="run"               # run | discover | detect | export-config | install-mcc | net-up | net-down
KEEP_IP=0                  # 1 = Staging-Adresse am Ende stehen lassen
FORCE_WEB=0                # 1 = Konfiguration bewusst ueber die Weboberflaeche
NO_VERIFY=0                # 1 = Pruefung nach dem Neustart ueberspringen
NO_NET_SETUP=0             # 1 = keine IP-Adressen anlegen oder entfernen
SKIP_FIRMWARE=0            # 1 = Firmware gar nicht erst anfassen
FW_ACTION=""               # Ergebnis des Firmware-Schritts fuer den Bericht
INSTALL_SRC=""

# Vom Benutzer zu erfassende Zieldaten
NEW_NAME=""
NEW_IP=""
NEW_MASK=""
NEW_GW=""

# Laufzeitzustand (wird durch die Erkennung gefuellt)
DEV_MODEL=""
DEV_FAMILY=""
DEV_FWVER=""
DEV_MAC=""
DEV_SERVERNAME=""
DEV_SOURCE=""              # womit wurde erkannt: mcc | snmp | http | manuell
DEV_USERFIELD=""           # Inhalt der Spalte "User" aus der Geraeteliste
DETECT_HTTPS=0

# Aufraeumen
CLEANUP_IP=""
CLEANUP_IFACE=""

LOG_TXT=""
LOG_JSON=""
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"

# ------------------------------------------------------------------------------
# Logging: menschenlesbar auf stderr + Textlog, zusaetzlich JSON-Lines
# ------------------------------------------------------------------------------
C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_STEP=""
if [[ -t 2 ]]; then
    C_RESET=$'\033[0m'; C_INFO=$'\033[0;36m'; C_WARN=$'\033[0;33m'
    C_ERR=$'\033[0;31m'; C_OK=$'\033[0;32m';  C_STEP=$'\033[1;37m'
fi

# JSON-String escapen (nur die Zeichen, die wirklich vorkommen koennen)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# jlog <level> <event> [key=value ...] -> eine JSON-Zeile
jlog() {
    [[ -n "$LOG_JSON" ]] || return 0
    local level="$1" event="$2"; shift 2
    local line kv k v
    line=$(printf '{"ts":"%s","run":"%s","level":"%s","event":"%s"' \
        "$(date -Is)" "$RUN_ID" "$level" "$(json_escape "$event")")
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        line+=$(printf ',"%s":"%s"' "$(json_escape "$k")" "$(json_escape "$v")")
    done
    line+='}'
    printf '%s\n' "$line" >>"$LOG_JSON"
}

_log() {
    local color="$1" tag="$2" msg="$3"
    printf '%s[%s]%s %s\n' "$color" "$tag" "$C_RESET" "$msg" >&2
    [[ -n "$LOG_TXT" ]] && printf '%s [%s] %s\n' "$(date -Is)" "$tag" "$msg" >>"$LOG_TXT"
    return 0
}

log_info() { _log "$C_INFO" "INFO" "$1"; jlog info  "$1"; }
log_ok()   { _log "$C_OK"   " OK " "$1"; jlog ok    "$1"; }
log_warn() { _log "$C_WARN" "WARN" "$1"; jlog warn  "$1"; }
log_err()  { _log "$C_ERR"  "FEHL" "$1"; jlog error "$1"; }
log_dbg()  { (( VERBOSE )) && _log "$C_INFO" "DBUG" "$1"; jlog debug "$1"; return 0; }

log_step() {
    printf '\n%s=== %s ===%s\n' "$C_STEP" "$1" "$C_RESET" >&2
    [[ -n "$LOG_TXT" ]] && printf '\n%s === %s ===\n' "$(date -Is)" "$1" >>"$LOG_TXT"
    jlog step "$1"
    return 0
}

die() { log_err "$1"; exit "${2:-1}"; }

on_error() {
    local rc=$? line=$1
    log_err "Abbruch in Zeile ${line} (Exit-Code ${rc})."
    jlog error "unhandled_error" "line=${line}" "rc=${rc}"
}
trap 'on_error $LINENO' ERR

cleanup() {
    local rc=$?
    trap - EXIT ERR
    verify_teardown
    if [[ -n "$CLEANUP_IP" && -n "$CLEANUP_IFACE" ]]; then
        if (( KEEP_IP )); then
            log_info "Staging-Adresse ${CLEANUP_IP} bleibt auf ${CLEANUP_IFACE} bestehen."
            log_info "Entfernen mit: ${SCRIPT_NAME} --net-down"
        else
            log_info "Entferne temporaere IP ${CLEANUP_IP} von ${CLEANUP_IFACE}."
            priv ip addr del "${CLEANUP_IP}/24" dev "$CLEANUP_IFACE" || true
        fi
    fi
    # Wurde das Skript doch mit sudo gestartet, gehoeren Logs und Exportdateien
    # sonst root und lassen sich spaeter als normaler Benutzer nicht mehr lesen.
    if [[ -n "${SUDO_USER:-}" ]] && (( EUID == 0 )); then
        chown -R "${SUDO_USER}:" "$LOG_DIR" "$WORK_DIR" 2>/dev/null || true
    fi
    jlog info "script_end" "rc=${rc}"
    exit "$rc"
}
trap cleanup EXIT

# run_cmd: fuehrt ein Kommando aus, respektiert --dry-run
run_cmd() {
    if (( DRY_RUN )); then
        printf '%s[DRY ]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2
        jlog dryrun "would_execute" "cmd=$*"
        return 0
    fi
    log_dbg "exec: $*"
    "$@"
}

# priv: fuehrt ein Kommando mit erhoehten Rechten aus.
#
# Das Skript braucht Rechte ausschliesslich zum Setzen und Entfernen von
# IP-Adressen. Alles andere - MCC-Tool, Ping, Dateien - laeuft unprivilegiert.
# Deshalb wird nicht das ganze Skript als root gestartet, sondern nur diese
# einzelnen Aufrufe erhoben.
priv() {
    if (( EUID == 0 )); then
        run_cmd "$@"
        return $?
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        log_err "Fuer '$*' werden erhoehte Rechte gebraucht, sudo ist nicht vorhanden."
        return 1
    fi
    run_cmd sudo "$@"
}

# Meldet, ob Netzaenderungen ueberhaupt moeglich sind, und erklaert die
# Alternativen, falls nicht.
have_priv() {
    (( EUID == 0 )) && return 0
    command -v sudo >/dev/null 2>&1 || return 1
    sudo -n true 2>/dev/null && return 0
    # sudo vorhanden, aber Passwort noetig - das ist in Ordnung
    return 0
}

# ------------------------------------------------------------------------------
# Hilfe
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} - Moxa Konfigurations- und Firmware-Werkzeug

AUFRUF
  ${SCRIPT_NAME} [Optionen]

AKTIONEN
  (ohne Angabe)         Vollstaendiger Ablauf: Erkennen, Firmware, Konfiguration
  --detect              Nur Geraet erkennen und Firmwarestand melden
  --discover            Das 192.168.127.0/24 Netz nach Moxa-Geraeten absuchen
  --export-config       Konfiguration des Geraets exportieren und ablegen
                        (nuetzlich, um die INI-Schluesselnamen einmalig zu pruefen)
  --install-mcc DATEI   Heruntergeladenes MCC-Tool-Archiv (.zip/.tar.gz) entpacken
  --net-up              Nur die Staging-Adresse setzen und stehen lassen
                        (fuer Browser-Zugriff und manuelles Arbeiten am Geraet)
  --net-down            Staging-Adresse wieder entfernen
  --print-sudoers       Minimale sudoers-Regel ausgeben, damit die drei
                        Adressbefehle ohne Passwortabfrage laufen

GERAETEDATEN (koennen alle interaktiv abgefragt werden)
  --name NAME           Neuer Servername
  --ip ADRESSE          Neue IP-Adresse
  --mask MASKE          Neue Subnetzmaske
  --gw ADRESSE          Neues Gateway
  --device-ip ADRESSE   Aktuelle Adresse des Geraets (Standard: ${DEFAULT_DEVICE_IP})
  --user NAME           Login am Geraet (Standard: ${DEVICE_USER})
  --pass PASSWORT       Passwort am Geraet (Standard: ${DEVICE_PASS})
  --psk KEY             Pre-Shared Key fuer Config-Export/Import (Standard: ${DEVICE_PSK})
  --initial-pass PW     Passwort, das bei einer Erstkonfiguration automatisch
                        gesetzt wird (Standard: ${INITIAL_PASS})

UMGEBUNG
  --iface NAME          Netzwerkinterface fuer die Staging-IP
  --staging-ip ADRESSE  Temporaere IP des Rechners (Standard: ${DEFAULT_DEVICE_NET}.10)
  --fw-dir PFAD         Verzeichnis mit Firmware-Dateien und manifest.csv
  --mcc-bin PFAD        Pfad zur mcc_tool Binaerdatei
  --config DATEI        Konfigurationsdatei (Standard: ${CONFIG_FILE})

VERHALTEN
  -n, --dry-run         Nichts veraendern, nur zeigen was passieren wuerde
  -y, --yes             Rueckfragen automatisch bejahen
      --keep-ip         Staging-Adresse nach dem Lauf nicht entfernen
      --web             Konfiguration bewusst ueber die Weboberflaeche fuehren
                        statt ueber das MCC-Tool
      --no-net-setup    Keine IP-Adressen anlegen oder entfernen. Dann
                        braucht das Skript ueberhaupt keine Rechte, die
                        Adresse muss aber schon dauerhaft vergeben sein.
      --no-firmware     Firmware nicht anfassen, direkt zur Konfiguration
                        (sonst wird vor einem Update gefragt)
      --no-verify       Nach dem Neustart nicht pruefen, ob das Geraet
                        unter der neuen Adresse antwortet
      --no-probe        Keine weiteren Anmeldedaten durchprobieren
                        (nur die eingestellte Kombination versuchen)
      --no-tui          Keine Dialogboxen, reine Shell-Eingabe
  -v, --verbose         Ausfuehrliche Ausgabe
  -h, --help            Diese Hilfe

BEISPIELE
  # Interaktiv mit Dialogfuehrung
  ./${SCRIPT_NAME}

  # Vollautomatisch, ohne Rueckfragen
  ./${SCRIPT_NAME} -y --name ts-rack12-a --ip 10.20.30.41 \\
       --mask 255.255.255.0 --gw 10.20.30.1

  # Adresse setzen, danach im Browser weiterarbeiten
  ./${SCRIPT_NAME} --net-up
  xdg-open http://${DEFAULT_DEVICE_IP}
  ./${SCRIPT_NAME} --net-down

  # Erst einmal nur schauen, was passieren wuerde
  ./${SCRIPT_NAME} --dry-run --name test --ip 10.20.30.41 \\
       --mask 255.255.255.0 --gw 10.20.30.1
EOF
}

# ------------------------------------------------------------------------------
# Argumentauswertung
# ------------------------------------------------------------------------------
parse_args() {
    while (( $# )); do
        case "$1" in
            --detect)         ACTION="detect" ;;
            --net-up)         ACTION="net-up"; KEEP_IP=1 ;;
            --net-down)       ACTION="net-down" ;;
            --keep-ip)        KEEP_IP=1 ;;
            --web)            FORCE_WEB=1 ;;
            --no-verify)      NO_VERIFY=1 ;;
            --no-net-setup)   NO_NET_SETUP=1 ;;
            --no-firmware)    SKIP_FIRMWARE=1 ;;
            --print-sudoers)  ACTION="print-sudoers" ;;
            --discover)       ACTION="discover" ;;
            --export-config)  ACTION="export-config" ;;
            --install-mcc)    ACTION="install-mcc"; INSTALL_SRC="${2:?Archivdatei fehlt}"; shift ;;
            --name)           NEW_NAME="${2:?}"; shift ;;
            --ip)             NEW_IP="${2:?}"; shift ;;
            --mask)           NEW_MASK="${2:?}"; shift ;;
            --gw|--gateway)   NEW_GW="${2:?}"; shift ;;
            --device-ip)      DEVICE_IP="${2:?}"; shift ;;
            --user)           DEVICE_USER="${2:?}"; shift ;;
            --pass|--password) DEVICE_PASS="${2:?}"; shift ;;
            --psk)            DEVICE_PSK="${2:?}"; shift ;;
            --initial-pass)   INITIAL_PASS="${2:?}"; shift ;;
            --iface)          STAGING_IFACE="${2:?}"; shift ;;
            --staging-ip)     STAGING_IP="${2:?}"; shift ;;
            --fw-dir)         FW_DIR="${2:?}"; shift ;;
            --mcc-bin)        MCC_BIN="${2:?}"; shift ;;
            --config)         CONFIG_FILE="${2:?}"; shift ;;
            --snmp-community) SNMP_COMMUNITY="${2:?}"; shift ;;
            -n|--dry-run)     DRY_RUN=1 ;;
            -y|--yes)         ASSUME_YES=1 ;;
            --no-tui)         USE_TUI=0 ;;
            --no-probe)       AUTH_PROBE=0 ;;
            -v|--verbose)     VERBOSE=1 ;;
            -h|--help)        usage; exit 0 ;;
            *) usage >&2; die "Unbekannte Option: $1" 2 ;;
        esac
        shift
    done
}

load_config_file() {
    [[ -r "$CONFIG_FILE" ]] || return 0
    # Konfigurationsdatei ist reines Shell-Fragment mit KEY="wert"
    log_info "Lade Konfiguration aus ${CONFIG_FILE}."
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

# ------------------------------------------------------------------------------
# Bedienoberflaeche: whiptail wenn vorhanden, sonst schlichte Shell-Eingabe
# ------------------------------------------------------------------------------
have_whiptail() {
    (( USE_TUI )) || return 1
    command -v whiptail >/dev/null 2>&1 || return 1
    # Ohne steuerndes Terminal kann whiptail nicht zeichnen
    [[ -r /dev/tty && -w /dev/tty ]]
}

# whiptail malt sein Fenster auf STDOUT und liefert das Ergebnis auf STDERR.
# Wird eine dieser Funktionen innerhalb einer Kommandosubstitution aufgerufen,
# landet sonst die komplette Bildschirmausgabe im Rueckgabewert.
# Deshalb hier immer explizit: Fenster nach /dev/tty, Ergebnis nach stdout.
ui_input() {
    local title="$1" prompt="$2" default="${3:-}" answer=""
    if have_whiptail; then
        answer=$(whiptail --title "$title" --inputbox "$prompt" 12 74 "$default" \
                 2>&1 1>/dev/tty </dev/tty) || { printf ''; return 1; }
    else
        if [[ -n "$default" ]]; then
            read -r -p "$prompt [$default]: " answer </dev/tty || true
            answer="${answer:-$default}"
        else
            read -r -p "$prompt: " answer </dev/tty || true
        fi
    fi
    printf '%s' "$answer"
}

ui_password() {
    local title="$1" prompt="$2" default="${3:-}" answer=""
    if have_whiptail; then
        answer=$(whiptail --title "$title" --passwordbox "$prompt" 12 74 \
                 2>&1 1>/dev/tty </dev/tty) || { printf ''; return 1; }
        answer="${answer:-$default}"
    else
        read -r -s -p "$prompt [Enter = Vorgabe]: " answer </dev/tty || true
        echo >&2
        answer="${answer:-$default}"
    fi
    printf '%s' "$answer"
}

ui_yesno() {
    local title="$1" prompt="$2" answer=""
    (( ASSUME_YES )) && return 0
    if have_whiptail; then
        whiptail --title "$title" --yesno "$prompt" 16 74 </dev/tty >/dev/tty 2>&1
        return $?
    fi
    read -r -p "$prompt [j/N]: " answer </dev/tty || true
    [[ "${answer,,}" == j* || "${answer,,}" == y* ]]
}

ui_msg() {
    local title="$1" text="$2"
    if have_whiptail; then
        whiptail --title "$title" --msgbox "$text" 20 78 </dev/tty >/dev/tty 2>&1 || true
    else
        printf '\n%s--- %s ---%s\n%s\n\n' "$C_STEP" "$title" "$C_RESET" "$text" >&2
        (( ASSUME_YES )) || read -r -p "Weiter mit Enter ..." _ </dev/tty || true
    fi
}

ui_menu() {
    local title="$1" prompt="$2"; shift 2
    local -a items=("$@")
    local choice="" i=1
    if have_whiptail; then
        choice=$(whiptail --title "$title" --menu "$prompt" 20 74 8 "${items[@]}" \
                 2>&1 1>/dev/tty </dev/tty) || { printf ''; return 1; }
    else
        printf '\n%s\n' "$prompt" >&2
        for ((i=0; i<${#items[@]}; i+=2)); do
            printf '  %s) %s\n' "${items[i]}" "${items[i+1]}" >&2
        done
        read -r -p "Auswahl: " choice </dev/tty || true
    fi
    printf '%s' "$choice"
}

# ------------------------------------------------------------------------------
# Validierung
# ------------------------------------------------------------------------------
is_ipv4() {
    local ip="$1" o
    local -a oct
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a oct <<<"$ip"
    for o in "${oct[@]}"; do
        # fuehrende Nullen ausschliessen (008 waere oktal-verdaechtig)
        [[ "$o" == "0" || "$o" != 0* ]] || return 1
        (( 10#$o >= 0 && 10#$o <= 255 )) || return 1
    done
    return 0
}

is_netmask() {
    local m="$1" o seen_zero=0
    local -a oct
    is_ipv4 "$m" || return 1
    IFS='.' read -r -a oct <<<"$m"
    for o in "${oct[@]}"; do
        # nur gueltige Oktettwerte einer zusammenhaengenden Maske
        case "$o" in
            255|254|252|248|240|224|192|128|0) : ;;
            *) return 1 ;;
        esac
        # nach dem ersten Nicht-255-Oktett darf nichts mehr folgen ausser 0
        (( seen_zero && o != 0 )) && return 1
        (( o != 255 )) && seen_zero=1
    done
    return 0
}

is_hostname() {
    # Moxa-Servername: Buchstaben, Ziffern, Bindestrich, Unterstrich, Punkt
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,38})$ ]]
}

# ------------------------------------------------------------------------------
# Abhaengigkeiten
# ------------------------------------------------------------------------------

# Klartext-Diagnose, wenn sich die Binaerdatei nicht starten laesst.
diagnose_mcc() {
    local rc="$1" target=""
    log_err "MCC-Tool laesst sich nicht ausfuehren (Exit-Code ${rc}):"
    log_err "  ${MCC_BIN}"
    if (( rc == 126 )); then
        log_err "Exit-Code 126 bedeutet: Datei vorhanden, aber nicht ausfuehrbar."
        log_err "Typische Ursachen:"
        log_err "  - der Pfad zeigt auf ein Verzeichnis statt auf die Binaerdatei"
        log_err "  - das Ausfuehrungsrecht fehlt"
        log_err "  - das Dateisystem ist mit 'noexec' gemountet (USB-Stick, /tmp)"
        log_err "  - 32-Bit-Binaerdatei auf 64-Bit-System ohne i386-Unterstuetzung"
    else
        log_err "Exit-Code 127 bedeutet: eine benoetigte Bibliothek fehlt."
    fi
    log_err "Zur Eingrenzung bitte ausfuehren:"
    log_err "  file '${MCC_BIN}'"
    log_err "  ldd  '${MCC_BIN}'"
    if command -v df >/dev/null 2>&1; then
        target=$(df --output=target "$MCC_BIN" 2>/dev/null | tail -n1)
        [[ -n "$target" ]] && log_err "  findmnt -no OPTIONS ${target}   # auf 'noexec' pruefen"
    fi
}

# Sucht in einem Verzeichnisbaum nach der eigentlichen Programmdatei.
# Moxa benennt sie je nach Paket "mcc_tool", "mcc_tool_x64" oder "MCC_Tool".
# Ausgeschlossen werden Bibliotheken, Archive und Dokumente.
find_mcc_candidates() {
    local root="$1"
    [[ -d "$root" ]] || return 0
    find "$root" -maxdepth 6 -type f \
        \( -iname 'mcc_tool' -o -iname 'mcc_tool_*' -o -iname 'mcc-tool*' \) \
        ! -iname '*.so' ! -iname '*.so.*' ! -iname '*.tar' ! -iname '*.gz' \
        ! -iname '*.tgz' ! -iname '*.zip' ! -iname '*.txt' ! -iname '*.pdf' \
        ! -iname '*.exe' ! -iname '*.md' 2>/dev/null || true
}

# Waehlt aus mehreren Kandidaten den zur Architektur passenden aus.
pick_mcc_candidate() {
    local list="$1" arch pref="" plain="" c
    arch="$(uname -m)"
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        case "$arch" in
            x86_64|amd64)
                [[ "${c,,}" == *x64* || "${c,,}" == *x86_64* || "${c,,}" == *amd64* ]] \
                    && { pref="$c"; break; } ;;
            i?86)
                [[ "${c,,}" == *x86* && "${c,,}" != *x86_64* ]] && { pref="$c"; break; } ;;
            aarch64|arm*)
                [[ "${c,,}" == *arm* || "${c,,}" == *aarch* ]] && { pref="$c"; break; } ;;
        esac
        [[ -z "$plain" ]] && plain="$c"
    done <<<"$list"
    printf '%s' "${pref:-$plain}"
}

# Entpackt verschachtelte Archive. Das Moxa-ZIP fuer Linux enthaelt selbst
# wieder ein .tar.gz (siehe MCC-Tool-Manual v2.5, "Installing MCC_Tool on Linux").
unpack_nested() {
    local dir="$1" _round inner cnt
    for _round in 1 2 3; do
        cnt=0
        while IFS= read -r inner; do
            [[ -n "$inner" ]] || continue
            log_info "Entpacke verschachteltes Archiv: $(basename "$inner")"
            case "$inner" in
                *.tar.gz|*.tgz) tar -xzf "$inner" -C "$(dirname "$inner")" 2>/dev/null || true ;;
                *.tar)          tar -xf  "$inner" -C "$(dirname "$inner")" 2>/dev/null || true ;;
                *.zip)          unzip -oq "$inner" -d "$(dirname "$inner")" 2>/dev/null || true ;;
            esac
            mv -f "$inner" "${inner}.done" 2>/dev/null || true
            cnt=$((cnt+1))
        done < <(find "$dir" -maxdepth 5 -type f \
                 \( -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.tar' -o -iname '*.zip' \) \
                 2>/dev/null || true)
        (( cnt == 0 )) && break
    done
}

# Findet die mcc_tool-Binaerdatei, macht den Pfad absolut und testet sie wirklich.
# Wichtig: '-x' allein reicht nicht, denn Verzeichnisse sind ebenfalls "ausfuehrbar".
resolve_mcc_bin() {
    local cand="" root rc=0

    # Ein explizit gesetzter Pfad darf auch auf das entpackte Verzeichnis zeigen
    if [[ -n "$MCC_BIN" && -d "$MCC_BIN" ]]; then
        cand="$(pick_mcc_candidate "$(find_mcc_candidates "$MCC_BIN")")"
        MCC_BIN="$cand"
    fi

    if [[ -z "$MCC_BIN" ]]; then
        for root in "$SCRIPT_DIR" /opt/moxa /usr/local/lib/moxa; do
            [[ -d "$root" ]] || continue
            cand="$(pick_mcc_candidate "$(find_mcc_candidates "$root")")"
            [[ -n "$cand" ]] && { MCC_BIN="$cand"; break; }
        done
        if [[ -z "$MCC_BIN" ]] && command -v mcc_tool >/dev/null 2>&1; then
            MCC_BIN="$(command -v mcc_tool)"
        fi
    fi

    [[ -n "$MCC_BIN" ]] || return 1

    if [[ ! -f "$MCC_BIN" ]]; then
        log_err "Der angegebene MCC-Pfad ist keine Datei: ${MCC_BIN}"
        return 1
    fi

    MCC_BIN="$(readlink -f "$MCC_BIN")"
    MCC_DIR="$(dirname "$MCC_BIN")"

    if [[ ! -x "$MCC_BIN" ]]; then
        log_warn "Ausfuehrungsrecht fehlt, setze es: chmod +x ${MCC_BIN}"
        chmod +x "$MCC_BIN" 2>/dev/null \
            || { log_err "chmod fehlgeschlagen."; return 1; }
    fi

    # Die Plugins (dsci_mcc.so, mxio_mcc.so, mgci_mcc.so) liegen neben der Binaerdatei
    export LD_LIBRARY_PATH="${MCC_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

    # Probelauf: klaert Rechte, Architektur und fehlende Bibliotheken sofort ab,
    # statt den Fehler erst mitten im Export auftauchen zu lassen.
    "$MCC_BIN" -ver >/dev/null 2>&1 || rc=$?
    if (( rc == 126 || rc == 127 )); then
        diagnose_mcc "$rc"
        jlog error "mcc_not_executable" "path=${MCC_BIN}" "rc=${rc}"
        return 1
    fi
    return 0
}

check_deps() {
    local -a required=(ping ip awk sed grep curl)
    local -a optional=(whiptail snmpget nmap arping xdg-open unzip tar sha256sum)
    local -a missing=()
    local c

    for c in "${required[@]}"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} )); then
        log_err "Fehlende Pflichtwerkzeuge: ${missing[*]}"
        log_err "Nachinstallieren mit: sudo apt install iputils-ping iproute2 curl"
        return 1
    fi
    for c in "${optional[@]}"; do
        command -v "$c" >/dev/null 2>&1 || log_dbg "Optional nicht vorhanden: $c"
    done

    # MCC-Tool suchen und wirklich pruefen
    if resolve_mcc_bin; then
        log_ok "MCC-Tool gefunden: ${MCC_BIN}"
        jlog info "mcc_found" "path=${MCC_BIN}"
    else
        MCC_BIN=""
        log_warn "MCC-Tool nicht nutzbar. Erkennung und Update laufen dann nur"
        log_warn "eingeschraenkt (SNMP/HTTP) bzw. ueber die gefuehrte Weboberflaeche."
        log_warn "Archiv entpacken mit: ${SCRIPT_NAME} --install-mcc <datei.zip>"
    fi
    return 0
}

# Wird aufgerufen, bevor tatsaechlich eine Adresse geaendert wird.
need_priv_for_net() {
    (( EUID == 0 )) && return 0
    if ! command -v sudo >/dev/null 2>&1; then
        log_err "Zum Setzen der IP-Adresse werden Rechte gebraucht, sudo fehlt."
        return 1
    fi
    if ! sudo -n true 2>/dev/null; then
        log_info "Zum Setzen der IP-Adresse wird einmalig das sudo-Passwort gebraucht."
    fi
    return 0
}

# Gibt eine minimale sudoers-Regel aus, damit das Skript ohne Passwortabfrage
# laeuft. Bewusst auf die tatsaechlich benoetigten Aufrufe beschraenkt.
print_sudoers() {
    local ipbin user
    ipbin="$(command -v ip || echo /usr/sbin/ip)"
    user="${SUDO_USER:-${USER:-$(id -un)}}"
    cat <<EOF
# Minimale Regel fuer ${SCRIPT_NAME}
# Ablegen als /etc/sudoers.d/moxa-setup und mit "sudo visudo -c" pruefen.
#
# Damit braucht das Skript selbst kein sudo mehr - nur die drei
# Adressbefehle laufen erhoben.
#
# Hinweis: "ip" bleibt ein maechtiges Werkzeug. Wer die Regel enger fassen
# will, legt stattdessen ein kleines Wrapper-Skript an und traegt nur dieses
# ein. Noch einfacher ist der Weg ohne jede Regel: die Adresse dauerhaft
# vergeben (siehe ${SCRIPT_NAME} --help, Abschnitt --no-net-setup).

${user} ALL=(root) NOPASSWD: ${ipbin} addr add * dev *, ${ipbin} addr del * dev *, ${ipbin} link set * up
EOF
}

install_mcc() {
    local src="$1" dest="${SCRIPT_DIR}/mcc" found
    [[ -r "$src" ]] || die "Archiv nicht lesbar: $src"
    mkdir -p "$dest"
    case "$src" in
        *.zip)          run_cmd unzip -o "$src" -d "$dest" ;;
        *.tar.gz|*.tgz) run_cmd tar -xzf "$src" -C "$dest" ;;
        *) die "Unbekanntes Archivformat: $src" ;;
    esac

    # Das Linux-ZIP von Moxa enthaelt seinerseits ein .tar.gz
    unpack_nested "$dest"

    # Achtung: nur regulaere Dateien, kein Verzeichnis. Der Versuch, ein
    # Verzeichnis auszufuehren, endet in Exit-Code 126.
    found="$(pick_mcc_candidate "$(find_mcc_candidates "$dest")")"
    if [[ -z "$found" ]]; then
        log_err "Im Archiv wurde keine ausfuehrbare MCC-Datei gefunden."
        log_err "Inhalt von ${dest}:"
        find "$dest" -maxdepth 4 \( -type f -o -type d \) -printf '    %y %p\n' 2>/dev/null >&2 \
            || find "$dest" -maxdepth 4 >&2
        return 1
    fi
    log_info "Architektur des Rechners: $(uname -m) -> gewaehlt: $(basename "$found")"

    run_cmd chmod +x "$found"
    MCC_BIN="$found"
    if resolve_mcc_bin; then
        log_ok "MCC-Tool installiert und lauffaehig: ${MCC_BIN}"
        log_info "Dauerhaft eintragen in moxa_setup.conf:"
        log_info "  MCC_BIN=\"${MCC_BIN}\""
    else
        log_err "MCC-Tool wurde entpackt, laesst sich aber nicht starten."
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Netzvorbereitung: temporaere IP im Werksnetz des Geraets
# ------------------------------------------------------------------------------
pick_iface() {
    local iface
    if [[ -n "$STAGING_IFACE" ]]; then printf '%s' "$STAGING_IFACE"; return 0; fi
    # bevorzugt ein kabelgebundenes Interface mit Link
    iface=$(ip -o link show up 2>/dev/null \
            | awk -F': ' '$2 !~ /^(lo|docker|veth|br-|virbr|wl)/ {print $2; exit}')
    printf '%s' "${iface:-}"
}

prepare_network() {
    local iface staging
    # Wenn das Geraet nicht im Werksnetz haengt, ist keine Staging-IP noetig
    if [[ "$DEVICE_IP" != "${DEFAULT_DEVICE_NET}."* ]]; then
        log_info "Geraet liegt ausserhalb ${DEFAULT_DEVICE_NET}.0/24 - keine Staging-IP noetig."
        return 0
    fi
    if ip -4 addr show 2>/dev/null | grep -q "inet ${DEFAULT_DEVICE_NET}\."; then
        log_ok "Es existiert bereits eine Adresse im ${DEFAULT_DEVICE_NET}.0/24 Netz."
        return 0
    fi

    if (( NO_NET_SETUP )); then
        log_err "Es gibt keine Adresse im ${DEFAULT_DEVICE_NET}.0/24 Netz und --no-net-setup ist gesetzt."
        log_err "Adresse vorher dauerhaft vergeben, z.B.:"
        log_err "  nmcli con add type ethernet ifname <iface> con-name moxa-staging \\"
        log_err "        ip4 ${DEFAULT_DEVICE_NET}.10/24"
        return 1
    fi
    need_priv_for_net || return 1

    iface="$(pick_iface)"
    [[ -n "$iface" ]] || { log_warn "Kein aktives Interface gefunden."; return 1; }
    staging="${STAGING_IP:-${DEFAULT_DEVICE_NET}.10}"
    is_ipv4 "$staging" || die "Ungueltige Staging-IP: $staging"

    log_info "Setze temporaere Adresse ${staging}/24 auf ${iface}."
    if priv ip addr add "${staging}/24" dev "$iface"; then
        if (( ! DRY_RUN )); then
            CLEANUP_IP="$staging"; CLEANUP_IFACE="$iface"
        fi
        priv ip link set "$iface" up || true
        # ARP und Link brauchen einen Moment, sonst scheitert der erste Ping
        sleep 3
        ping -c 1 -W 1 -n "$DEVICE_IP" >/dev/null 2>&1 || true
        log_ok "Staging-Adresse aktiv."
    else
        log_warn "Staging-Adresse konnte nicht gesetzt werden - evtl. schon vorhanden."
    fi
    return 0
}

# Entfernt alle Adressen im Werksnetz von allen Interfaces.
net_down() {
    local iface addr found=0
    while read -r addr iface; do
        [[ -n "$addr" && -n "$iface" ]] || continue
        log_info "Entferne ${addr} von ${iface}."
        priv ip addr del "$addr" dev "$iface" || true
        found=1
    done < <(ip -o -4 addr show 2>/dev/null \
             | awk -v net="${DEFAULT_DEVICE_NET}." '$4 ~ net {print $4, $2}')
    if (( found )); then
        log_ok "Staging-Adressen entfernt."
    else
        log_info "Es war keine Adresse im ${DEFAULT_DEVICE_NET}.0/24 Netz gesetzt."
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Erreichbarkeit und Hardware-Reset-Fuehrung
# ------------------------------------------------------------------------------
ping_host() { ping -c 2 -W 2 -n "$1" >/dev/null 2>&1; }

tcp_open() {
    local host="$1" port="$2"
    timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

wait_for_host() {
    local host="$1" timeout="${2:-120}" waited=0
    log_info "Warte auf ${host} (max. ${timeout}s) ..."
    while (( waited < timeout )); do
        if ping_host "$host"; then
            log_ok "${host} antwortet nach ${waited}s."
            return 0
        fi
        sleep 5; waited=$((waited+5))
        printf '.' >&2
    done
    printf '\n' >&2
    log_warn "${host} war nach ${timeout}s nicht erreichbar."
    return 1
}

factory_reset_hint() {
    ui_msg "Geraet nicht erreichbar" \
"Das Geraet unter ${DEVICE_IP} antwortet nicht.

Bitte pruefe der Reihe nach:

 1. Netzwerkkabel steckt im LAN-Port des Geraets
 2. Stromkabel steckt, Kippschalter steht auf EIN
 3. Link-LED am LAN-Port leuchtet

Wenn das alles stimmt, ist meist eine abweichende IP konfiguriert.
Dann das Geraet hardwareseitig in den Werkszustand versetzen:

 - Reset-Taster (Nadelloch an der Front bzw. Rueckseite) mit einer
   Bueroklammer druecken und ca. 5 Sekunden gedrueckt halten,
   bis die Ready-LED blinkt
 - Taster loslassen, Geraet startet neu (dauert bis zu 90 Sekunden)
 - Danach ist das Geraet wieder unter ${DEFAULT_DEVICE_IP} erreichbar
   (Benutzer: admin, Passwort: moxa)

Achtung: Der Reset loescht die gesamte Konfiguration des Geraets."
}

ensure_reachable() {
    local attempt=1
    while (( attempt <= 4 )); do
        if ping_host "$DEVICE_IP"; then
            log_ok "Geraet unter ${DEVICE_IP} erreichbar."
            jlog ok "device_reachable" "ip=${DEVICE_IP}"
            return 0
        fi
        log_warn "Versuch ${attempt}: ${DEVICE_IP} antwortet nicht."
        factory_reset_hint
        if ! ui_yesno "Erneut pruefen" "Soll die Erreichbarkeit erneut geprueft werden?"; then
            return 1
        fi
        wait_for_host "$DEVICE_IP" 90 || true
        attempt=$((attempt+1))
    done
    return 1
}

# ------------------------------------------------------------------------------
# Geraeteerkennung
# ------------------------------------------------------------------------------

# Modellbezeichnung -> Familie
family_of_model() {
    local m="${1^^}"
    m="${m// /}"; m="${m//_/-}"
    case "$m" in
        *6610*|*6650*|*NPORT66*|*NPORT64*|*NP66*|*NP64*) printf 'NPORT6000' ;;
        *5410*|*5430*|*5450*|*NPORT54*|*NP54*) printf 'NPORT5400' ;;
        *CN2510*|*CN2500*)                 printf 'CN2500' ;;
        *) printf '' ;;
    esac
}

# Anzahl serieller Ports aus der Modellbezeichnung ableiten (nur informativ)
ports_of_model() {
    local m="${1^^}"
    case "$m" in
        *-32*|*32)  printf '32' ;;
        *-16*|*16)  printf '16' ;;
        *-8*|*8)    printf '8'  ;;
        *54[0-9]0*) printf '4'  ;;   # NPort 5400 Serie ist durchgaengig 4-Port
        *)          printf '?'  ;;
    esac
}

# Feld aus einer Semikolon-Zeile holen und Leerzeichen abschneiden.
csv_field() {
    local line="$1" idx="$2" v
    v=$(awk -F';' -v i="$idx" '{print $i}' <<<"$line")
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# Wertet die Ausgabedatei von "mcc_tool -fw -r" aus.
#
# Das Tool schreibt je nach Version entweder Semikolon-getrennte Felder oder
# durch Leerzeichen ausgerichtete Spalten:
#   Model   ServerName   IP   MAC   FwVer   User   PWD   CfgFile   Key   FwFile   Port
#
# Im Spaltenformat wird nach Mustern gesucht statt nach Position, weil leere
# Felder (PWD, CfgFile, Key, FwFile) die Spaltenzaehlung verschieben.
parse_mcc_record() {
    local file="$1" line tok
    local -a f=()

    # Kopfzeile aussortieren, Datenzeile muss eine IPv4-Adresse enthalten
    line=$(grep -v -i 'ServerName' "$file" \
           | grep -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    [[ -n "$line" ]] || return 1
    log_dbg "MCC-Datenzeile: ${line}"

    if [[ "$line" == *";"* ]]; then
        DEV_MODEL="$(csv_field "$line" 1)"
        DEV_SERVERNAME="$(csv_field "$line" 2)"
        DEV_MAC="$(csv_field "$line" 4)"
        DEV_FWVER="$(csv_field "$line" 5)"
        DEV_USERFIELD="$(csv_field "$line" 6)"
    else
        read -r -a f <<<"$line"
        DEV_MODEL="${f[0]:-}"
        DEV_SERVERNAME="${f[1]:-}"
        DEV_MAC=""; DEV_FWVER=""
        for tok in "${f[@]}"; do
            if [[ "$tok" =~ ^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$ ]]; then
                DEV_MAC="$tok"
            elif [[ -z "$DEV_FWVER" && -n "$DEV_MAC" \
                    && "$tok" =~ ^[vV]?[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
                # Die Version steht direkt hinter der MAC-Adresse
                DEV_FWVER="$tok"
            fi
        done
        # Notnagel, falls keine MAC gemeldet wurde
        if [[ -z "$DEV_FWVER" ]]; then
            for tok in "${f[@]}"; do
                [[ "$tok" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] && continue
                [[ "$tok" =~ ^[vV]?[0-9]+\.[0-9]+([.][0-9]+)?$ ]] \
                    && { DEV_FWVER="$tok"; break; }
            done
        fi
    fi

    DEV_FWVER="${DEV_FWVER#[vV]}"
    DEV_FWVER="$(grep -oE '^[0-9]+([.][0-9]+)*' <<<"$DEV_FWVER" || true)"
    [[ -n "$DEV_MODEL" ]]
}

# Liest den Fehlercode aus der Logdatei des MCC-Tools.
#
# Die Logdatei ist je nach Version semikolongetrennt oder in Spalten
# ausgerichtet; die letzte Spalte ist ErrCode. Liefert sie nichts
# Brauchbares, wird der Exit-Code des Prozesses genommen. Negative Werte
# kommen dort als 256+n an: -17 erscheint als 239.
mcc_error_code() {
    local logf="$1" rc="$2" code=""
    if [[ -s "$logf" ]]; then
        if grep -q ';' "$logf"; then
            code=$(awk -F';' '$0 !~ /ErrCode/ && NF>1 {v=$NF} END{gsub(/[[:space:]\r]/,"",v); print v}' "$logf")
        else
            code=$(awk '$0 !~ /ErrCode/ && NF>0 {v=$NF} END{gsub(/[[:space:]\r]/,"",v); print v}' "$logf")
        fi
    fi
    [[ "$code" =~ ^-?[0-9]+$ ]] || code=""
    if [[ -z "$code" ]]; then
        if (( rc > 127 )); then code=$(( rc - 256 )); else code="$rc"; fi
    fi
    printf '%s' "$code"
}

# Fuehrt ein MCC-Kommando aus. Anmeldedaten und "-l" werden hier angehaengt.
#
# Bei Anmeldefehlern (-2, -17) wird genau einmal die jeweils andere
# Anmeldeform versucht: aeltere NPort-Staende kennen nur ein Passwort,
# ab Firmware v2.0 wird ein Benutzername verlangt. Was ein konkretes Geraet
# erwartet, laesst sich vorher nicht zuverlaessig ablesen - das Feld "User"
# der Geraeteliste ist dafuer kein Beleg.
MCC_LAST_ERR=""
mcc_exec() {
    local logf="$1"; shift
    local -a base=("$@") auth=() pwlist=() userlist=()
    local rc code pw user attempt=0 pwnum
    local orig_user="$DEVICE_USER" orig_pass="$DEVICE_PASS"

    # Reihenfolge: die aktuell eingestellte Kombination zuerst, danach die
    # bekannten Alternativen. Doppelte Eintraege fallen raus.
    pwlist=("$DEVICE_PASS")
    if (( AUTH_PROBE )); then
        for pw in "${DEVICE_PASS_LIST[@]}"; do
            [[ "$pw" == "$DEVICE_PASS" ]] || pwlist+=("$pw")
        done
    fi
    # Aeltere Staende kennen nur ein Passwort, ab Firmware v2.0 wird ein
    # Benutzername verlangt. Beide Formen werden probiert.
    if [[ -n "$orig_user" ]]; then userlist=("$orig_user" ""); else userlist=("" "admin"); fi
    (( AUTH_PROBE )) || userlist=("$orig_user")

    pwnum=0
    for pw in "${pwlist[@]}"; do
        pwnum=$((pwnum+1))
        for user in "${userlist[@]}"; do
            attempt=$((attempt+1))
            DEVICE_USER="$user"
            DEVICE_PASS="$pw"

            auth=()
            [[ -n "$DEVICE_USER" ]] && auth+=(-u "$DEVICE_USER")
            auth+=(-p "$DEVICE_PASS")

            rc=0
            # Passwoerter werden bewusst nicht protokolliert, nur ihre Nummer
            log_dbg "MCC-Versuch ${attempt}: ${base[*]} (Benutzer: ${DEVICE_USER:-keiner}, Passwort #${pwnum})"
            "$MCC_BIN" "${base[@]}" "${auth[@]}" -l "$logf" >/dev/null 2>&1 || rc=$?
            code="$(mcc_error_code "$logf" "$rc")"
            MCC_LAST_ERR="$code"

            if [[ "$code" == "0" ]]; then
                if (( attempt > 1 )); then
                    log_ok "Anmeldung erfolgreich mit Benutzer '${DEVICE_USER:-keiner}' und Passwort #${pwnum}."
                    log_info "Diese Kombination gilt fuer den Rest des Laufs."
                fi
                return 0
            fi

            # Nur Anmeldeprobleme rechtfertigen einen weiteren Versuch.
            # Nur -2 ist ein Anmeldefehler. -17 heisst laut Manual, dass am
            # Geraet noch gar kein Passwort existiert - da hilft kein anderes.
            if [[ "$code" != "-2" ]]; then
                DEVICE_USER="$orig_user"; DEVICE_PASS="$orig_pass"
                return 1
            fi
            log_dbg "Versuch ${attempt} abgelehnt (Code ${code})."
        done
    done

    log_err "Keine der ${attempt} Anmeldekombinationen wurde akzeptiert."
    log_warn "Vorsicht: weitere Versuche koennen ab Firmware v2.0 das Konto sperren."
    DEVICE_USER="$orig_user"; DEVICE_PASS="$orig_pass"
    return 1
}

detect_via_mcc() {
    [[ -n "$MCC_BIN" ]] || return 1
    local out rc=0
    out="${WORK_DIR}/detect-${RUN_ID}.txt"
    mkdir -p "$WORK_DIR"
    # "-fw -r" liest nur aus und veraendert nichts. Deshalb laeuft die
    # Erkennung auch im Testlauf, sonst waere die Vorschau wertlos.
    log_dbg "MCC-Abfrage: ${MCC_BIN} -fw -r -i ${DEVICE_IP}"
    "$MCC_BIN" -fw -r -i "$DEVICE_IP" -o "$out" -t 15 >/dev/null 2>&1 || rc=$?
    [[ -s "$out" ]] || { log_dbg "MCC lieferte keine Ausgabedatei (rc=${rc})."; return 1; }

    if ! parse_mcc_record "$out"; then
        # Bei nicht unterstuetzten Baureihen (CN2500/CN2510) steht in der
        # Datei nur die Kopfzeile. Das ist kein Fehler, nur kein Treffer.
        log_dbg "Keine Datenzeile in der MCC-Ausgabe. Inhalt:"
        (( VERBOSE )) && sed -n '1,10p' "$out" | sed 's/^/    /' >&2
        return 1
    fi
    DEV_SOURCE="mcc"

    # Das Feld "User" der Geraeteliste wird NICHT als Anmeldename uebernommen.
    # Es gehoert zur Liste, die man fuer Stapelverarbeitung selbst befuellt,
    # und sagt nichts darueber aus, was das Geraet erwartet. Die Anmeldeform
    # klaert mcc_exec zur Laufzeit ueber einen Zweitversuch.
    [[ -n "$DEV_USERFIELD" ]] && log_dbg "Geraeteliste meldet User='${DEV_USERFIELD}'."
    return 0
}

detect_via_snmp() {
    command -v snmpget >/dev/null 2>&1 || return 1
    local desc
    desc=$(snmpget -v1 -c "$SNMP_COMMUNITY" -Ovq -t 3 -r 1 "$DEVICE_IP" \
           .1.3.6.1.2.1.1.1.0 2>/dev/null | tr -d '"') || return 1
    [[ -n "$desc" ]] || return 1
    log_dbg "SNMP sysDescr: ${desc}"
    DEV_MODEL=$(grep -oiE '(NPort|CN)[- ]?[0-9]{4}[A-Za-z0-9-]*' <<<"$desc" | head -n1)
    DEV_FWVER=$(grep -oiE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$desc" | head -n1 | sed 's/^[vV]//')
    [[ -n "$DEV_MODEL" ]] || return 1
    DEV_SOURCE="snmp"
    return 0
}

detect_via_http() {
    local body scheme
    for scheme in http https; do
        body=$(curl -sk --max-time 6 "${scheme}://${DEVICE_IP}/" 2>/dev/null) || continue
        [[ -n "$body" ]] || continue
        [[ "$scheme" == "https" ]] && DETECT_HTTPS=1
        DEV_MODEL=$(grep -oiE '(NPort|CN)[- ]?[0-9]{4}[A-Za-z0-9-]*' <<<"$body" | head -n1)
        DEV_FWVER=$(grep -oiE 'firmware[^0-9]{0,12}([0-9]+\.[0-9]+(\.[0-9]+)?)' <<<"$body" \
                    | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
        if [[ -n "$DEV_MODEL" ]]; then DEV_SOURCE="http"; return 0; fi
    done
    return 1
}

ask_model_manually() {
    local choice
    choice=$(ui_menu "Modell waehlen" \
        "Das Modell konnte nicht automatisch erkannt werden.\nBitte auswaehlen:" \
        "NPort-6610-8"  "NPort 6610, 8 Port" \
        "NPort-6610-16" "NPort 6610, 16 Port" \
        "NPort-6610-32" "NPort 6610, 32 Port" \
        "NPort-6650-32" "NPort 6650, 32 Port" \
        "NPort-5410"    "NPort 5410" \
        "CN2510-16"     "CN2510 (EOL)" \
        "CN2500-16"     "CN2500 (EOL)") || return 1
    [[ -n "$choice" ]] || return 1
    DEV_MODEL="$choice"
    DEV_SOURCE="manuell"
    if [[ -z "$DEV_FWVER" ]]; then
        DEV_FWVER=$(ui_input "Firmware" \
            "Aktuelle Firmwareversion des Geraets (z.B. 1.18).\nLeer lassen, wenn unbekannt:" "")
        DEV_FWVER="${DEV_FWVER#v}"
    fi
    return 0
}

detect_device() {
    log_step "Geraeteerkennung"
    DEV_MODEL=""; DEV_FWVER=""; DEV_MAC=""; DEV_SERVERNAME=""; DEV_SOURCE=""

    if detect_via_mcc;  then log_ok "Erkennung ueber MCC-Tool."
    elif detect_via_snmp; then log_ok "Erkennung ueber SNMP."
    elif detect_via_http; then log_ok "Erkennung ueber Weboberflaeche."
    else
        log_warn "Automatische Erkennung fehlgeschlagen."
        ask_model_manually || return 1
    fi

    DEV_FAMILY="$(family_of_model "$DEV_MODEL")"
    if [[ -z "$DEV_FAMILY" ]]; then
        log_warn "Modell '${DEV_MODEL}' laesst sich keiner bekannten Familie zuordnen."
        ask_model_manually || return 1
        DEV_FAMILY="$(family_of_model "$DEV_MODEL")"
    fi

    log_ok "Modell     : ${DEV_MODEL} ($(ports_of_model "$DEV_MODEL") Port)"
    log_ok "Familie    : ${DEV_FAMILY}"
    log_ok "Firmware   : ${DEV_FWVER:-unbekannt}"
    [[ -n "$DEV_MAC" ]]        && log_ok "MAC        : ${DEV_MAC}"
    [[ -n "$DEV_SERVERNAME" ]] && log_ok "Servername : ${DEV_SERVERNAME}"
    jlog ok "device_detected" "model=${DEV_MODEL}" "family=${DEV_FAMILY}" \
            "fw=${DEV_FWVER}" "mac=${DEV_MAC}" "source=${DEV_SOURCE}"
    return 0
}

# ------------------------------------------------------------------------------
# Firmware: Katalog, Versionsvergleich, Upgrade-Pfad
# ------------------------------------------------------------------------------
# manifest.csv Format (Semikolon, '#' = Kommentar):
#   familie;version;datei;sha256;min_von
#     familie  - NPORT6000 | NPORT5400 | CN2500
#     version  - Version dieses Images, z.B. 2.3
#     datei    - Dateiname im Firmware-Verzeichnis
#     sha256   - Pruefsumme oder '-' zum Ueberspringen
#     min_von  - kleinste Ausgangsversion, aus der direkt aktualisiert werden darf

declare -a FW_ROWS=()

load_fw_catalog() {
    local manifest="${FW_DIR}/manifest.csv" line
    FW_ROWS=()
    if [[ ! -r "$manifest" ]]; then
        log_warn "Kein Firmware-Manifest unter ${manifest}."
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        [[ -z "${line// }" ]] && continue
        [[ "${line,,}" == familie\;* ]] && continue     # Kopfzeile
        FW_ROWS+=("$line")
    done <"$manifest"
    log_info "Firmware-Katalog geladen: ${#FW_ROWS[@]} Eintraege."
    return 0
}

# version_cmp a b -> gibt -1 / 0 / 1 aus
version_cmp() {
    local a="${1#v}" b="${2#v}"
    if [[ "$a" == "$b" ]]; then printf '0'; return 0; fi
    local -a A B; local i n
    IFS='.' read -r -a A <<<"$a"
    IFS='.' read -r -a B <<<"$b"
    n=$(( ${#A[@]} > ${#B[@]} ? ${#A[@]} : ${#B[@]} ))
    for ((i=0; i<n; i++)); do
        local x="${A[i]:-0}" y="${B[i]:-0}"
        x="${x//[^0-9]/}"; y="${y//[^0-9]/}"
        x=$((10#${x:-0})); y=$((10#${y:-0}))
        (( x < y )) && { printf -- '-1'; return 0; }
        (( x > y )) && { printf '1';    return 0; }
    done
    printf '0'
}
version_lt() { [[ "$(version_cmp "$1" "$2")" == "-1" ]]; }

# Zielversion einer Familie = hoechste Version im Katalog
fw_target_version() {
    local family="$1" best="" row f v
    for row in "${FW_ROWS[@]}"; do
        IFS=';' read -r f v _ _ _ <<<"$row"
        [[ "${f// }" == "$family" ]] || continue
        v="${v// }"
        if [[ -z "$best" ]] || version_lt "$best" "$v"; then best="$v"; fi
    done
    printf '%s' "$best"
}

# fw_row_for <familie> <version> -> "datei;sha256;min_von"
fw_row_for() {
    local family="$1" want="$2" row f v file sum minfrom
    for row in "${FW_ROWS[@]}"; do
        IFS=';' read -r f v file sum minfrom <<<"$row"
        if [[ "${f// }" == "$family" && "${v// }" == "$want" ]]; then
            printf '%s;%s;%s' "${file// }" "${sum// }" "${minfrom// }"
            return 0
        fi
    done
    return 1
}

# Kleinste Firmwareversion, ab der das MCC-Tool die Familie bedienen kann.
# Quelle: Moxa CLI Configuration Tool Manual v2.5, Abschnitt "Supported Models".
mcc_min_version() {
    case "$1" in
        NPORT6000) printf '1.13' ;;
        NPORT5400) printf '3.13' ;;
        *)         printf '' ;;   # CN2500 wird vom MCC-Tool gar nicht unterstuetzt
    esac
}

mcc_supports_family() { [[ -n "$(mcc_min_version "$1")" ]]; }

# Upgrade-Pfad berechnen: greedy den hoechsten erreichbaren Schritt waehlen.
# Ausgabe: Versionen durch Leerzeichen getrennt, aufsteigend.
plan_upgrade_path() {
    local family="$1" current="$2" target="$3"
    local -a path=()
    local guard=0 row f v file sum minfrom best

    while version_lt "$current" "$target"; do
        (( ++guard > 12 )) && { log_err "Upgrade-Pfad konvergiert nicht."; return 1; }
        best=""
        for row in "${FW_ROWS[@]}"; do
            IFS=';' read -r f v file sum minfrom <<<"$row"
            f="${f// }"; v="${v// }"; minfrom="${minfrom// }"
            [[ "$f" == "$family" ]] || continue
            version_lt "$current" "$v" || continue           # nur echte Aufstiege
            [[ -z "$minfrom" || "$minfrom" == "-" ]] && minfrom="0.0"
            version_lt "$current" "$minfrom" && continue      # Vorbedingung verletzt
            if [[ -z "$best" ]] || version_lt "$best" "$v"; then best="$v"; fi
        done
        [[ -n "$best" ]] || { log_err "Von ${current} aus ist kein Schritt moeglich."; return 1; }
        path+=("$best")
        current="$best"
    done
    printf '%s' "${path[*]}"
}

verify_fw_file() {
    local file="$1" want="$2"
    [[ -r "$file" ]] || { log_err "Firmware-Datei fehlt: ${file}"; return 1; }
    if [[ -z "$want" || "$want" == "-" ]]; then
        log_warn "Keine Pruefsumme hinterlegt fuer $(basename "$file") - ueberspringe Pruefung."
        return 0
    fi
    command -v sha256sum >/dev/null 2>&1 || { log_warn "sha256sum fehlt."; return 0; }
    local have
    have=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$have" != "$want" ]]; then
        log_err "Pruefsumme falsch fuer $(basename "$file")."
        log_err "  erwartet: ${want}"
        log_err "  ermittelt: ${have}"
        return 1
    fi
    log_ok "Pruefsumme ok: $(basename "$file")"
    return 0
}

# Ein einzelner Upgrade-Schritt ueber das MCC-Tool
upgrade_step_mcc() {
    local version="$1" row file sum minfrom path rc=0 logf
    row=$(fw_row_for "$DEV_FAMILY" "$version") \
        || { log_err "Kein Katalogeintrag fuer ${DEV_FAMILY} ${version}."; return 1; }
    IFS=';' read -r file sum minfrom <<<"$row"
    path="${FW_DIR}/${file}"
    verify_fw_file "$path" "$sum" || return 1

    logf="${WORK_DIR}/fw-${version}-${RUN_ID}.log"
    log_info "Spiele Firmware ${version} ein (${file}). Das dauert mehrere Minuten."
    log_warn "Geraet in dieser Zeit NICHT vom Strom trennen."

    if (( DRY_RUN )); then
        log_info "[dry-run] ${MCC_BIN} -fw -up -i ${DEVICE_IP} ${DEVICE_USER:+-u ${DEVICE_USER} }-p *** -f ${path} -print -t 1200"
        return 0
    fi

    if mcc_exec "$logf" -fw -up -i "$DEVICE_IP" -f "$path" -print -t 1200; then
        log_ok "Firmware ${version} erfolgreich eingespielt."
        jlog ok "fw_upgraded" "version=${version}"
    else
        log_err "Firmware-Update auf ${version} fehlgeschlagen (MCC-Fehlercode: ${MCC_LAST_ERR})."
        explain_mcc_error "$MCC_LAST_ERR"
        return 1
    fi

    log_info "Geraet startet neu."
    wait_for_host "$DEVICE_IP" 180 || log_warn "Geraet meldet sich nicht - bitte manuell pruefen."
    sleep 10
    return 0
}

explain_mcc_error() {
    # Fehlercodes woertlich nach MCC-Tool-Manual v2.5, "Error Code Explanation"
    local c="$1" t=""
    case "$c" in
        0)   t="erfolgreich" ;;
        -1)  t="Geraet nicht gefunden" ;;
        -2)  t="Passwort oder Benutzername stimmt nicht" ;;
        -3)  t="Passwort zu lang (nur NPort 5100/5200)" ;;
        -4)  t="Datei konnte nicht geoeffnet werden - Pfad und Schreibrechte pruefen" ;;
        -5)  t="Zeitueberschreitung" ;;
        -6)  t="Import fehlgeschlagen" ;;
        -7)  t="Firmware-Update fehlgeschlagen" ;;
        -8)  t="neues Passwort zu lang (nur NPort 5100/5200)" ;;
        -9)  t="Port-Index fuer den Neustart konnte nicht gesetzt werden" ;;
        -10) t="Pre-Shared Key zum Entschluesseln der Konfigurationsdatei passt nicht" ;;
        -11) t="ungueltiger Parameter fuer dieses Modell" ;;
        -12) t="Kommando wird von diesem Geraet nicht unterstuetzt" ;;
        -13) t="fehlende Angaben in der Geraeteliste" ;;
        -14) t="fehlende Angaben in der Liste der neuen Passwoerter" ;;
        -15) t="nicht ausfuehrbar wegen Fehlern bei anderen Geraeten der Liste" ;;
        -16) t="das MCC-Tool unterstuetzt diesen Firmwarestand nicht - erst ueber die Weboberflaeche anheben" ;;
        -17) t="das Geraet ist noch im Auslieferungszustand - es muss zuerst ein Passwort angelegt werden" ;;
        *)   t="unbekannt, siehe MCC-Tool-Manual" ;;
    esac
    log_err "  Bedeutung: ${t}"
}

# Legt am Geraet erstmalig ein Passwort an.
#
# Fehlercode -17 heisst laut Manual: das Geraet ist noch im Auslieferungs-
# zustand. Import und Export sind erst moeglich, wenn ein Passwort existiert.
# Gesetzt wird es mit "-pw -ch". Welches Passwort im Auslieferungszustand als
# altes gilt, ist nicht dokumentiert, deshalb werden die bekannten Kandidaten
# der Reihe nach probiert.
set_initial_password() {
    local newpw="$1" logf="${WORK_DIR}/pw-${RUN_ID}.log"
    local oldpw rc code

    if (( DRY_RUN )); then
        log_info "[dry-run] ${MCC_BIN} -pw -ch -i ${DEVICE_IP} -u admin -p *** -npw ***"
        return 0
    fi

    for oldpw in "" "moxa" "${DEVICE_PASS_LIST[@]}"; do
        rc=0
        log_dbg "Passwort setzen, Ausgangspasswort: ${oldpw:-leer}"
        "$MCC_BIN" -pw -ch -i "$DEVICE_IP" -u "$INITIAL_USER" -p "$oldpw" \
                   -npw "$newpw" -l "$logf" >/dev/null 2>&1 || rc=$?
        code="$(mcc_error_code "$logf" "$rc")"
        if [[ "$code" == "0" ]]; then
            log_ok "Passwort am Geraet gesetzt (Benutzer '${INITIAL_USER}')."
            DEVICE_USER="$INITIAL_USER"
            DEVICE_PASS="$newpw"
            jlog ok "password_initialized" "ip=${DEVICE_IP}"
            log_info "Das Geraet startet dazu neu."
            wait_for_host "$DEVICE_IP" 120 || true
            sleep 5
            return 0
        fi
        log_dbg "Fehlgeschlagen (Code ${code})."
    done

    log_err "Das Passwort konnte nicht gesetzt werden."
    explain_mcc_error "$code"
    log_err "Von Hand: ${MCC_BIN} -pw -ch -i ${DEVICE_IP} -u ${INITIAL_USER} -p '' -npw '<passwort>'"
    return 1
}

# Reaktion auf Fehlercode -17: Passwort anlegen und Aktion wiederholen.
#
# Code -17 heisst laut Manual v2.5, dass das Geraet noch im Auslieferungs-
# zustand ist. Das ist bei fabrikneuen NPort-Geraeten der Normalfall und
# keine Entscheidung, die eine Rueckfrage rechtfertigt: es wird ohne Nachfrage
# INITIAL_USER/INITIAL_PASS gesetzt. Abweichende Vorgaben ueber die
# Konfigurationsdatei oder --initial-pass.
handle_default_state() {
    log_info "Geraet ist im Auslieferungszustand (Code -17) - noch kein Passwort gesetzt."
    log_info "Setze Erstzugangsdaten: Benutzer '${INITIAL_USER}'."
    jlog info "initial_password_auto" "user=${INITIAL_USER}"

    if [[ -z "$INITIAL_PASS" ]]; then
        log_err "INITIAL_PASS ist leer - es kann kein Passwort gesetzt werden."
        return 1
    fi
    set_initial_password "$INITIAL_PASS"
}

# Gefuehrtes Update ueber die lokale Weboberflaeche (fuer zu alte Staende)
guide_web_upgrade() {
    local target="$1" reason="${2:-alt}" row file sum minfrom path url intro
    row=$(fw_row_for "$DEV_FAMILY" "$target") || row=";;"
    IFS=';' read -r file sum minfrom <<<"$row"
    path="${FW_DIR}/${file}"
    url="http://${DEVICE_IP}"
    (( DETECT_HTTPS )) && url="https://${DEVICE_IP}"

    case "$reason" in
        alt)     intro="Der Firmwarestand ${DEV_FWVER:-unbekannt} liegt unter der vom MCC-Tool
unterstuetzten Mindestversion. Dieser Schritt muss einmalig ueber die
lokale Weboberflaeche erfolgen." ;;
        kein_mcc) intro="Das MCC-Tool steht nicht zur Verfuegung. Das Update laeuft deshalb
ueber die lokale Weboberflaeche." ;;
        *)       intro="Das Update auf ${target} laeuft ueber die lokale Weboberflaeche." ;;
    esac

    if (( DRY_RUN )); then
        log_info "[dry-run] Hier wuerde die Anleitung fuer das Web-Update auf ${target} erscheinen."
        log_info "[dry-run] Grund: ${reason}, Adresse: ${url}, Datei: ${path}"
        return 0
    fi

    ui_msg "Firmware-Update ueber die Weboberflaeche" \
"${intro}

 1. Browser oeffnen: ${url}
    Login: ${DEVICE_USER} / ${DEVICE_PASS}

 2. Menuepunkt suchen. Je nach Firmwarealter heisst er unterschiedlich:
      neuere Staende : System Management > Maintenance > Update Firmware
      aeltere Staende: Update Firmware  bzw.  Maintenance > Firmware Upgrade
      CN2500/CN2510  : Menuegefuehrte Telnet-Konsole, Punkt 'Upgrade firmware'

 3. Datei auswaehlen:
      ${path}

 4. Upgrade starten und das Geraet NICHT vom Strom trennen.
    Der Vorgang dauert bis zu 5 Minuten, danach startet das Geraet neu.

 5. Zurueck in dieses Fenster wechseln und bestaetigen."

    # Ohne die Staging-Adresse waere die Weboberflaeche nach dem Lauf nicht
    # mehr erreichbar. Bei gefuehrten Schritten bleibt sie deshalb stehen.
    KEEP_IP=1
    if command -v xdg-open >/dev/null 2>&1 && ui_yesno "Browser" "Soll ${url} jetzt geoeffnet werden?"; then
        run_cmd xdg-open "$url" >/dev/null 2>&1 || true
    fi

    ui_yesno "Bestaetigung" "Wurde das Update auf ${target} durchgefuehrt?" || {
        log_warn "Update wurde nicht bestaetigt."
        return 1
    }
    wait_for_host "$DEVICE_IP" 180 || true
    sleep 10
    # Firmwarestand neu einlesen
    detect_device || true
    return 0
}

handle_firmware() {
    log_step "Firmware pruefen"

    if [[ "$DEV_FAMILY" == "CN2500" ]]; then
        log_warn "${DEV_MODEL} gehoert zu einer abgekuendigten Baureihe."
        log_warn "Das MCC-Tool unterstuetzt diese Geraete nicht (siehe Manual v2.5)."
        log_warn "Firmware und Konfiguration laufen ueber Telnet-Menue bzw. Weboberflaeche."
        FW_ACTION="nicht moeglich (abgekuendigte Baureihe)"
        jlog warn "legacy_family" "family=CN2500" "model=${DEV_MODEL}"
        return 0
    fi

    load_fw_catalog || {
        log_warn "Ohne Katalog wird die Firmware nicht angefasst."
        FW_ACTION="nicht geprueft (kein Firmware-Katalog)"
        return 0
    }

    local target current
    target="$(fw_target_version "$DEV_FAMILY")"
    if [[ -z "$target" ]]; then
        log_warn "Keine Firmware fuer ${DEV_FAMILY} im Katalog - ueberspringe."
        return 0
    fi

    current="${DEV_FWVER:-}"
    if [[ -z "$current" ]]; then
        log_warn "Aktueller Firmwarestand unbekannt - Update wird nicht automatisch gestartet."
        FW_ACTION="nicht geprueft (Stand unbekannt)"
        return 0
    fi

    log_info "Ist-Stand : ${current}"
    log_info "Ziel-Stand: ${target}"

    if ! version_lt "$current" "$target"; then
        log_ok "Firmware ist aktuell. Kein Update noetig."
        FW_ACTION="aktuell (${current}), kein Update noetig"
        jlog ok "fw_uptodate" "version=${current}"
        return 0
    fi

    # Die Entscheidung faellt genau hier, vor jedem Zweig: auch der gefuehrte
    # Weg ueber die Weboberflaeche wird sonst angestossen, ohne dass jemand
    # gefragt wurde, ob ueberhaupt aktualisiert werden soll.
    if (( SKIP_FIRMWARE )); then
        log_info "Firmware-Update per --no-firmware uebersprungen."
        log_info "Weiter mit der Konfiguration. Stand bleibt ${current}."
        FW_ACTION="uebersprungen (--no-firmware), Stand ${current}"
        jlog info "fw_skipped" "reason=flag" "version=${current}"
        return 0
    fi

    if ! ui_yesno "Firmware-Update" \
"Fuer ${DEV_MODEL} liegt ein neuerer Firmwarestand vor.

  aktuell : ${current}
  verfuegbar : ${target}

Ein Update dauert je Schritt mehrere Minuten, das Geraet startet
dabei neu und darf nicht vom Strom getrennt werden.

Jetzt aktualisieren?

Nein bedeutet: Firmware bleibt auf ${current}, es wird direkt
mit der Konfiguration weitergemacht."; then
        log_info "Firmware-Update abgelehnt. Stand bleibt ${current}."
        log_info "Weiter mit der Konfiguration."
        FW_ACTION="abgelehnt, Stand bleibt ${current}"
        jlog info "fw_skipped" "reason=declined" "version=${current}"
        return 0
    fi

    # Zu alt fuer das MCC-Tool? Dann muss der erste Schritt ueber das Web laufen.
    local mccmin
    mccmin="$(mcc_min_version "$DEV_FAMILY")"
    if [[ -n "$mccmin" ]] && version_lt "$current" "$mccmin"; then
        log_warn "Firmware ${current} liegt unter der MCC-Mindestversion ${mccmin}."
        guide_web_upgrade "$mccmin" alt || return 1
        current="${DEV_FWVER:-$mccmin}"
        version_lt "$current" "$target" || { log_ok "Firmware jetzt aktuell."; return 0; }
    fi

    if [[ -z "$MCC_BIN" ]]; then
        log_warn "Ohne MCC-Tool ist kein Kommandozeilen-Update moeglich."
        guide_web_upgrade "$target" kein_mcc || return 1
        return 0
    fi

    local plan
    plan="$(plan_upgrade_path "$DEV_FAMILY" "$current" "$target")" || {
        log_warn "Aus dem Katalog laesst sich kein durchgaengiger Pfad von ${current}"
        log_warn "nach ${target} bilden. Fehlt eine Zwischenversion in manifest.csv?"
        guide_web_upgrade "$target" pfad || return 1
        return 0
    }

    log_info "Geplanter Upgrade-Pfad: ${current} -> ${plan// / -> }"
    jlog info "fw_plan" "from=${current}" "path=${plan}"

    local v
    for v in $plan; do
        log_step "Firmware-Schritt: ${v}"
        upgrade_step_mcc "$v" || return 1
    done

    detect_device || true
    log_ok "Firmware-Update abgeschlossen. Stand jetzt: ${DEV_FWVER:-unbekannt}"
    FW_ACTION="aktualisiert auf ${DEV_FWVER:-${target}}"
    return 0
}

# ------------------------------------------------------------------------------
# Konfiguration: exportieren, patchen, importieren
# ------------------------------------------------------------------------------
# Feldnamen der exportierten Konfiguration, je Geraetefamilie.
#
# NPORT6000 ist am Geraet verifiziert (NPort 6610-8, Export ueber
# "mcc_tool -cfg -ex"). Die Datei benutzt "Feldname=Wert" mit Leerzeichen
# im Feldnamen. Deshalb wird exakt verglichen und nicht per Regex gesucht:
# in derselben Datei stehen Felder wie "GSM Netmask", "V.92 Modem Netmask",
# "IPv4 DNS Server 1", "Model Name" und "UDP Dest. IP Range Begin #1",
# die eine unscharfe Suche mit erwischen wuerde.
#
# NPORT5400 ist noch nicht am Geraet geprueft. Falls die Namen abweichen,
# bricht cfg_patch ab, statt eine halbe Konfiguration einzuspielen.
#
# Format je Zeile: Feldname|Rolle
#   NAME MASK GW IP STATIC
cfg_keys_for_family() {
    case "$1" in
        NPORT6000)
            printf '%s\n' \
                'Server Name|NAME' \
                'IPv4 Address|IP' \
                'IPv4 Netmask|MASK' \
                'IPv4 Gateway|GW' \
                'IP Address|IP' \
                'IPv4 Configuration|STATIC'
            ;;
        NPORT5400)
            printf '%s\n' \
                'Server Name|NAME' \
                'IP Address|IP' \
                'Netmask|MASK' \
                'Gateway|GW' \
                'IP Configuration|STATIC'
            ;;
        *) return 0 ;;
    esac
}

# Wert fuer "IPv4 Configuration". 0 bedeutet statisch - bestaetigt durch den
# Werkszustand eines NPort 6610-8, der mit 0 und fester IP ausgeliefert wird.
CFG_STATIC_VALUE="${CFG_STATIC_VALUE:-0}"

# Liest den Wert eines Feldes aus der exportierten Konfigurationsdatei.
ini_value() {
    local file="$1" key="$2" v
    v=$(grep -m1 -i "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null || true)
    v="${v#*=}"
    v="${v%$'\r'}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# Reduziert eine Modellbezeichnung auf ihren Kern, damit sich "NPort6610-32"
# und "NP6610-32" vergleichen lassen.
model_key() {
    grep -oE '[0-9]{4}(-[0-9]+)?' <<<"${1^^}" | head -n1 || true
}

# Prueft, ob die Exportdatei wirklich von diesem Geraet stammt.
#
# Ohne diese Pruefung koennte eine Datei aus einem frueheren Lauf auf ein
# anderes Geraet zurueckgeschrieben werden - z.B. die Konfiguration eines
# 8-Port-Geraets auf ein 32-Port-Geraet.
cfg_check_identity() {
    local file="$1" fmodel fip want have
    fmodel="$(ini_value "$file" "Model Name")"
    fip="$(ini_value "$file" "IP Address")"
    [[ -n "$fip" ]] || fip="$(ini_value "$file" "IPv4 Address")"

    log_info "Exportdatei meldet: Modell='${fmodel:-?}' IP='${fip:-?}'"

    if [[ -n "$fip" && "$fip" != "$DEVICE_IP" ]]; then
        log_err "Die Exportdatei gehoert zu ${fip}, angesprochen wurde aber ${DEVICE_IP}."
        return 1
    fi
    want="$(model_key "$DEV_MODEL")"
    have="$(model_key "$fmodel")"
    if [[ -n "$want" && -n "$have" && "$want" != "$have" ]]; then
        log_err "Modell passt nicht: erkannt '${DEV_MODEL}', Datei meldet '${fmodel}'."
        return 1
    fi
    return 0
}

# Ergebnis von cfg_export. Der Pfad wird bewusst ueber eine Variable
# zurueckgegeben und nicht ueber stdout: die Funktion gibt Meldungen aus und
# kann Rueckfragen stellen, deren Ausgabe sonst im Rueckgabewert landet.
CFG_EXPORT_FILE=""

cfg_export() {
    local rc=0 exdir prev f
    CFG_EXPORT_FILE=""
    [[ -n "$MCC_BIN" ]] || { log_err "Config-Export braucht das MCC-Tool."; return 1; }

    # Eigenes, leeres Verzeichnis je Lauf. Frueher wurde notfalls irgendeine
    # .ini aus dem Arbeitsverzeichnis genommen - dabei konnte die Datei eines
    # ganz anderen Geraets erwischt werden.
    exdir="${WORK_DIR}/export-${RUN_ID}"
    rm -rf "$exdir"
    mkdir -p "$exdir"

    if (( DRY_RUN )); then
        log_info "[dry-run] ${MCC_BIN} -cfg -ex -i ${DEVICE_IP} ${DEVICE_USER:+-u ${DEVICE_USER} }-p *** -dk *** -t 60"
        return 1
    fi

    log_info "Exportiere aktuelle Konfiguration."
    prev="$PWD"
    cd "$exdir" || { log_err "Kann nicht nach ${exdir} wechseln."; return 1; }
    mcc_exec "${exdir}/mcc-export.log" -cfg -ex -i "$DEVICE_IP" -dk "$DEVICE_PSK" -t 60 || rc=$?
    cd "$prev" || true

    if (( rc != 0 )); then
        if [[ "$MCC_LAST_ERR" == "-17" ]]; then
            handle_default_state || return 1
            # Nach dem Setzen des Passworts genau einmal wiederholen
            rm -rf "$exdir"; mkdir -p "$exdir"
            rc=0
            prev="$PWD"
            cd "$exdir" || return 1
            mcc_exec "${exdir}/mcc-export.log" -cfg -ex -i "$DEVICE_IP" -dk "$DEVICE_PSK" -t 60 || rc=$?
            cd "$prev" || true
        fi
    fi
    if (( rc != 0 )); then
        log_err "Export fehlgeschlagen (MCC-Fehlercode: ${MCC_LAST_ERR})."
        explain_mcc_error "$MCC_LAST_ERR"
        return 1
    fi

    # Ausschliesslich in diesem Verzeichnis suchen, kein Rueckgriff auf aeltere Laeufe
    f=$(find "$exdir" -maxdepth 1 -type f -name '*.ini' -print -quit 2>/dev/null || true)
    if [[ -z "$f" ]]; then
        log_err "Das MCC-Tool meldete Erfolg, hat aber keine INI-Datei abgelegt."
        log_err "Inhalt von ${exdir}:"
        find "$exdir" -maxdepth 1 -type f -printf '    %p\n' >&2 2>/dev/null || true
        return 1
    fi

    cfg_check_identity "$f" || return 1

    log_ok "Konfiguration exportiert: ${f}"
    CFG_EXPORT_FILE="$f"
    return 0
}

# cfg_patch <quelle> <ziel>
# Ersetzt die Werte der bekannten Feldnamen. Die Schreibweise des Feldnamens
# in der Datei bleibt unangetastet, nur der Wert hinter dem ersten "=" wird
# getauscht. Zeilen ohne "=" werden unveraendert durchgereicht.
cfg_patch() {
    local src="$1" dst="$2"
    local -A want=() applied=()
    local key role val line lkey norm changes=0 crlf=0 eol=""

    # Die exportierte Datei benutzt DOS-Zeilenenden. Wird das ignoriert,
    # landet das \r im Wert, die Logausgabe zerfaellt, und die gepatchten
    # Zeilen bekommen ein anderes Zeilenende als der Rest der Datei.
    if head -c 8192 "$src" | grep -q $'\r'; then
        crlf=1
        eol=$'\r'
        log_info "Datei hat DOS-Zeilenenden - werden beibehalten."
    fi

    while IFS='|' read -r key role; do
        [[ -n "$key" ]] || continue
        case "$role" in
            NAME)   val="$NEW_NAME" ;;
            IP)     val="$NEW_IP" ;;
            MASK)   val="$NEW_MASK" ;;
            GW)     val="$NEW_GW" ;;
            STATIC) val="$CFG_STATIC_VALUE" ;;
            *)      continue ;;
        esac
        want["${key,,}"]="${role}|${val}"
    done < <(cfg_keys_for_family "$DEV_FAMILY")

    if (( ${#want[@]} == 0 )); then
        log_err "Fuer die Familie ${DEV_FAMILY} sind keine Feldnamen hinterlegt."
        return 1
    fi

    : >"$dst"
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( crlf )) && line="${line%$'\r'}"
        if [[ "$line" == *"="* ]]; then
            lkey="${line%%=*}"
            # Rand-Leerzeichen abschneiden und klein schreiben
            lkey="${lkey#"${lkey%%[![:space:]]*}"}"
            lkey="${lkey%"${lkey##*[![:space:]]}"}"
            norm="${lkey,,}"
            if [[ -n "${want[$norm]+x}" ]]; then
                role="${want[$norm]%%|*}"
                val="${want[$norm]#*|}"
                log_info "  ${lkey} = ${val}   (vorher: ${line#*=})"
                line="${line%%=*}=${val}"
                applied["$role"]=1
                changes=$((changes+1))
            fi
        fi
        printf '%s%s\n' "$line" "$eol" >>"$dst"
    done <"$src"

    log_info "Geaenderte Zeilen: ${changes}"
    jlog info "cfg_patch" "family=${DEV_FAMILY}" "changes=${changes}"

    local role_missing=""
    for role in NAME IP MASK GW; do
        [[ -n "${applied[$role]+x}" ]] || role_missing+=" ${role}"
    done
    if [[ -n "$role_missing" ]]; then
        log_err "Diese Felder wurden in der Exportdatei nicht gefunden:${role_missing}"
        log_err "Exportdatei zum Nachsehen: ${src}"
        log_err "Feldnamen ggf. in cfg_keys_for_family() ergaenzen."
        return 1
    fi
    if (( VERBOSE )); then
        log_dbg "--- Unterschiede ---"
        diff -u "$src" "$dst" >&2 || true
    fi
    return 0
}

cfg_import() {
    local file="$1" rc=0 logf="${WORK_DIR}/cfg-import-${RUN_ID}.log"
    if (( DRY_RUN )); then
        log_info "[dry-run] ${MCC_BIN} -cfg -im -i ${DEVICE_IP} ${DEVICE_USER:+-u ${DEVICE_USER} }-p *** -dk *** -f ${file} -t 120"
        log_info "[dry-run] Hinweis: '-n' wird bewusst NICHT gesetzt, damit die neue IP greift."
        return 0
    fi
    if [[ "$file" != "${WORK_DIR}/export-${RUN_ID}/"* && "$file" != "${WORK_DIR}/patched-${RUN_ID}.ini" ]]; then
        log_err "Sicherheitsstopp: ${file} stammt nicht aus diesem Lauf."
        return 1
    fi
    log_info "Spiele Konfiguration ein. Das Geraet startet danach neu."
    # WICHTIG: kein -n, sonst behaelt das Geraet seine alten Netzwerkparameter.
    mcc_exec "$logf" -cfg -im -i "$DEVICE_IP" -dk "$DEVICE_PSK" -f "$file" -t 120 || rc=$?
    if (( rc == 0 )); then
        log_ok "Konfiguration uebernommen."
        jlog ok "cfg_imported" "ip=${NEW_IP}"
        return 0
    fi
    if [[ "$MCC_LAST_ERR" == "-17" ]]; then
        if handle_default_state; then
            rc=0
            mcc_exec "$logf" -cfg -im -i "$DEVICE_IP" -dk "$DEVICE_PSK" -f "$file" -t 120 || rc=$?
            if (( rc == 0 )); then
                log_ok "Konfiguration uebernommen."
                jlog ok "cfg_imported" "ip=${NEW_IP}"
                return 0
            fi
        fi
    fi
    log_err "Config-Import fehlgeschlagen (MCC-Fehlercode: ${MCC_LAST_ERR})."
    explain_mcc_error "$MCC_LAST_ERR"
    return 1
}

guide_web_config() {
    local url="http://${DEVICE_IP}"
    (( DETECT_HTTPS )) && url="https://${DEVICE_IP}"
    if (( DRY_RUN )); then
        log_info "[dry-run] Hier wuerde die Anleitung fuer die Web-Konfiguration erscheinen:"
        log_info "[dry-run]   Adresse   : ${url}"
        log_info "[dry-run]   Name      : ${NEW_NAME}"
        log_info "[dry-run]   IP        : ${NEW_IP}"
        log_info "[dry-run]   Netzmaske : ${NEW_MASK}"
        log_info "[dry-run]   Gateway   : ${NEW_GW}"
        return 0
    fi

    ui_msg "Konfiguration ueber die Weboberflaeche" \
"Fuer ${DEV_MODEL} erfolgt die Konfiguration ueber die lokale Oberflaeche.

 1. Browser oeffnen: ${url}
    Login: ${DEVICE_USER} / ${DEVICE_PASS}
    (CN2500/CN2510: alternativ 'telnet ${DEVICE_IP}', menuegefuehrte Konsole)

 2. Basic Settings > Server Settings
      Server name    : ${NEW_NAME}

 3. Network Settings > IP Configuration
      IP configuration : Static
      IP address       : ${NEW_IP}
      Netmask          : ${NEW_MASK}
      Gateway          : ${NEW_GW}

 4. Speichern und Neustart ausloesen
    (Save/Restart bzw. Save Configuration > Restart)

 5. Danach ist das Geraet unter ${NEW_IP} erreichbar."

    KEEP_IP=1
    if command -v xdg-open >/dev/null 2>&1 && ui_yesno "Browser" "Soll ${url} jetzt geoeffnet werden?"; then
        run_cmd xdg-open "$url" >/dev/null 2>&1 || true
    fi
    ui_yesno "Bestaetigung" "Wurde die Konfiguration gesetzt und gespeichert?" || return 1
    return 0
}

handle_config() {
    log_step "Konfiguration setzen"
    log_info "Servername : ${NEW_NAME}"
    log_info "IP-Adresse : ${NEW_IP}"
    log_info "Netzmaske  : ${NEW_MASK}"
    log_info "Gateway    : ${NEW_GW}"

    # Der gefuehrte Weg ueber die Weboberflaeche ist nur fuer Geraete gedacht,
    # die das MCC-Tool nicht bedienen kann - oder wenn er ausdruecklich mit
    # "--web" angefordert wird. Ein technischer Fehler auf dem CLI-Weg fuehrt
    # NICHT stillschweigend in den Browser: er wird gemeldet und behoben.
    local reason=""
    if (( FORCE_WEB )); then
        reason="per --web angefordert"
    elif [[ "$DEV_FAMILY" == "CN2500" ]]; then
        reason="${DEV_MODEL} wird vom MCC-Tool nicht unterstuetzt"
    elif [[ -z "$MCC_BIN" ]]; then
        reason="kein MCC-Tool verfuegbar"
    elif ! mcc_supports_family "$DEV_FAMILY"; then
        reason="Familie ${DEV_FAMILY} wird vom MCC-Tool nicht unterstuetzt"
    fi

    if [[ -n "$reason" ]]; then
        log_info "Weg ueber die Weboberflaeche: ${reason}."
        guide_web_config || return 1
        return 0
    fi

    ui_yesno "Konfiguration" \
"Konfiguration jetzt auf ${DEV_MODEL} schreiben?

  Name      : ${NEW_NAME}
  IP        : ${NEW_IP}
  Netzmaske : ${NEW_MASK}
  Gateway   : ${NEW_GW}

Das Geraet startet anschliessend neu und ist danach
nur noch unter ${NEW_IP} erreichbar." || {
        log_warn "Konfiguration vom Benutzer abgelehnt."; return 1; }

    mkdir -p "$WORK_DIR"
    local src patched
    if ! cfg_export; then
        log_err "Die Konfiguration konnte nicht ausgelesen werden."
        log_err "Der Ablauf wird hier beendet, damit nichts Halbes geschrieben wird."
        log_err "Alternativ von Hand ueber die Weboberflaeche: ${SCRIPT_NAME} --web ..."
        return 1
    fi
    src="$CFG_EXPORT_FILE"
    patched="${WORK_DIR}/patched-${RUN_ID}.ini"
    if ! cfg_patch "$src" "$patched"; then
        log_err "Die Exportdatei konnte nicht angepasst werden."
        log_err "Exportdatei zur Ansicht: ${src}"
        return 1
    fi
    if ! cfg_import "$patched"; then
        log_err "Die Konfiguration wurde nicht uebernommen."
        log_err "Das Geraet sollte unveraendert unter ${DEVICE_IP} erreichbar sein."
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Verifikation und Report
# ------------------------------------------------------------------------------

# IPv4 <-> Ganzzahl
ip2int() {
    local -a o
    IFS='.' read -r -a o <<<"$1"
    printf '%s' $(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
}
int2ip() {
    local n="$1"
    printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) \
                         $(( (n >> 8) & 255 ))  $(( n & 255 ))
}
# Netzmaske -> Praefixlaenge
mask2prefix() {
    local -a o; local bits=0 x
    IFS='.' read -r -a o <<<"$1"
    for x in "${o[@]}"; do
        case "$x" in
            255) bits=$((bits+8)) ;; 254) bits=$((bits+7)) ;; 252) bits=$((bits+6)) ;;
            248) bits=$((bits+5)) ;; 240) bits=$((bits+4)) ;; 224) bits=$((bits+3)) ;;
            192) bits=$((bits+2)) ;; 128) bits=$((bits+1)) ;; 0) : ;;
            *) return 1 ;;
        esac
    done
    printf '%s' "$bits"
}

# Sucht eine freie Adresse im Zielnetz fuer die Pruefung.
#
# Ausgeschlossen werden Netz- und Broadcastadresse, die neue Geraete-IP, das
# Gateway und alles, was auf diesem Rechner schon vergeben ist. Zusaetzlich
# wird jeder Kandidat angepingt: antwortet jemand, ist die Adresse belegt.
pick_verify_ip() {
    local target="$1" mask="$2" gw="$3"
    local net bcast ti mi gi cand c used
    ti="$(ip2int "$target")"; mi="$(ip2int "$mask")"
    gi=0; [[ -n "$gw" ]] && gi="$(ip2int "$gw")"
    net=$(( ti & mi ))
    bcast=$(( net | (~mi & 0xFFFFFFFF) ))

    used="$(ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')"

    for (( c = bcast - 1; c > net; c-- )); do
        (( c == ti )) && continue
        (( gi != 0 && c == gi )) && continue
        cand="$(int2ip "$c")"
        grep -qx "$cand" <<<"$used" && continue
        ping -c 1 -W 1 -n "$cand" >/dev/null 2>&1 && continue   # belegt
        printf '%s' "$cand"
        return 0
    done
    return 1
}

VERIFY_IP=""
VERIFY_IFACE=""
VERIFY_RESULT=""

verify_teardown() {
    if [[ -n "$VERIFY_IP" && -n "$VERIFY_IFACE" ]]; then
        log_info "Entferne Pruefadresse ${VERIFY_IP} von ${VERIFY_IFACE}."
        priv ip addr del "${VERIFY_IP}" dev "$VERIFY_IFACE" || true
        VERIFY_IP=""; VERIFY_IFACE=""
    fi
}

# Prueft, ob das Geraet unter der neuen Adresse antwortet.
#
# Nach dem Neustart liegt das Geraet in einem anderen Subnetz. Dieser Rechner
# hat dort in aller Regel keine Adresse und damit keinen Weg dorthin - ein
# einfacher Ping schlaegt dann fehl, obwohl die Konfiguration sitzt. Deshalb
# wird fuer die Dauer der Pruefung eine Adresse im Zielnetz gesetzt.
verify_result() {
    log_step "Ergebnis pruefen"
    if (( DRY_RUN )); then
        log_info "[dry-run] Verifikation uebersprungen."
        return 0
    fi
    if (( NO_VERIFY )); then
        VERIFY_RESULT="abgeschaltet (--no-verify)"
        log_info "Verifikation per --no-verify abgeschaltet."
        return 0
    fi

    local prefix vip iface ok=1

    # 1. Vielleicht existiert schon ein Weg dorthin (Firmennetz, andere Karte)
    log_info "Warte auf den Neustart des Geraets."
    sleep 20
    if ping_host "$NEW_IP"; then
        log_ok "${NEW_IP} ist ueber die vorhandene Route erreichbar."
        ok=0
    else
        # 2. Sonst voruebergehend eine Adresse im Zielnetz setzen
        iface="$(pick_iface)"
        prefix="$(mask2prefix "$NEW_MASK")" || { log_warn "Netzmaske ${NEW_MASK} nicht auswertbar."; prefix=""; }
        if (( NO_NET_SETUP )); then
            log_warn "--no-net-setup gesetzt - es wird keine Pruefadresse angelegt."
            iface=""; prefix=""
        fi
        if [[ -n "$iface" && -n "$prefix" ]] && need_priv_for_net; then
            vip="$(pick_verify_ip "$NEW_IP" "$NEW_MASK" "$NEW_GW")" || vip=""
            if [[ -n "$vip" ]]; then
                log_info "Setze Pruefadresse ${vip}/${prefix} auf ${iface}."
                if priv ip addr add "${vip}/${prefix}" dev "$iface"; then
                    VERIFY_IP="${vip}/${prefix}"; VERIFY_IFACE="$iface"
                    sleep 3
                    wait_for_host "$NEW_IP" 150 && ok=0
                else
                    log_warn "Pruefadresse konnte nicht gesetzt werden."
                fi
            else
                log_warn "Im Netz ${NEW_IP}/${prefix} war keine freie Adresse zu finden."
            fi
        fi
    fi

    if (( ok == 0 )); then
        # 3. Gegenprobe: meldet sich unter der neuen Adresse wirklich unser Geraet?
        local old_ip="$DEVICE_IP" old_mac="$DEV_MAC" old_model="$DEV_MODEL"
        DEVICE_IP="$NEW_IP"
        if detect_device; then
            if [[ -n "$old_mac" && -n "$DEV_MAC" && "${DEV_MAC,,}" != "${old_mac,,}" ]]; then
                log_err "Unter ${NEW_IP} antwortet ein anderes Geraet (MAC ${DEV_MAC} statt ${old_mac})."
                ok=1
            else
                log_ok "Geraet bestaetigt: ${DEV_MODEL}, Servername '${DEV_SERVERNAME}', Firmware ${DEV_FWVER}."
                if [[ -n "$DEV_SERVERNAME" && "$DEV_SERVERNAME" != "$NEW_NAME" ]]; then
                    log_warn "Servername lautet '${DEV_SERVERNAME}', erwartet war '${NEW_NAME}'."
                fi
            fi
        else
            log_warn "${NEW_IP} antwortet auf Ping, liefert aber keine Geraetedaten."
            log_warn "Modell vor der Aenderung: ${old_model}"
        fi
        [[ "$DEVICE_IP" == "$NEW_IP" ]] || DEVICE_IP="$old_ip"
    fi

    verify_teardown

    if (( ok == 0 )); then
        VERIFY_RESULT="ja, unter ${NEW_IP} erreichbar"
        log_ok "Konfiguration verifiziert: Geraet ist unter ${NEW_IP} erreichbar."
        jlog ok "verify_ok" "ip=${NEW_IP}" "fw=${DEV_FWVER}"
        return 0
    fi

    VERIFY_RESULT="nein, ${NEW_IP} antwortete nicht"
    log_warn "Unter ${NEW_IP} kam keine Antwort."
    log_warn "Das heisst nicht zwingend, dass die Konfiguration fehlschlug."
    log_warn "Zu pruefen:"
    log_warn "  - Steckt das Kabel noch im selben Port wie vorher?"
    log_warn "  - Braucht das Geraet laenger als ${NEW_IP} fuer den Neustart?"
    log_warn "  - Liegt zwischen Rechner und Geraet ein VLAN oder ein Switch mit Portsicherung?"
    log_warn "Manuell nachsehen:"
    log_warn "  sudo ip addr add <freie-adresse>/${prefix:-24} dev ${iface:-<interface>}"
    log_warn "  ping ${NEW_IP}"
    jlog warn "verify_failed" "ip=${NEW_IP}"
    return 1
}

write_report() {
    local report="${LOG_DIR}/report-${RUN_ID}.txt"
    {
        printf 'Moxa Konfigurationsbericht\n'
        printf '==========================\n'
        printf 'Zeitpunkt   : %s\n' "$(date -Is)"
        printf 'Lauf-ID     : %s\n' "$RUN_ID"
        printf 'Modus       : %s\n' "$( ((DRY_RUN)) && echo 'Testlauf (dry-run)' || echo 'Produktiv')"
        printf '\nGeraet\n------\n'
        printf 'Modell      : %s (%s Port)\n' "${DEV_MODEL:-unbekannt}" "$(ports_of_model "${DEV_MODEL:-}")"
        printf 'Familie     : %s\n' "${DEV_FAMILY:-unbekannt}"
        printf 'MAC         : %s\n' "${DEV_MAC:-unbekannt}"
        printf 'Firmware    : %s\n' "${DEV_FWVER:-unbekannt}"
        printf 'Firmware-Schritt: %s\n' "${FW_ACTION:-nicht ausgefuehrt}"
        printf 'Erkannt via : %s\n' "${DEV_SOURCE:-unbekannt}"
        printf 'Anmeldung   : %s\n' "${DEVICE_USER:-nur Passwort, kein Benutzername}"
        printf '\nKonfiguration\n-------------\n'
        printf 'Servername  : %s\n' "${NEW_NAME:--}"
        printf 'IP-Adresse  : %s\n' "${NEW_IP:--}"
        printf 'Netzmaske   : %s\n' "${NEW_MASK:--}"
        printf 'Gateway     : %s\n' "${NEW_GW:--}"
        printf 'Verifiziert : %s\n' "${VERIFY_RESULT:-nicht geprueft}"
        printf '\nProtokolle\n----------\n'
        printf 'Text        : %s\n' "$LOG_TXT"
        printf 'JSON        : %s\n' "$LOG_JSON"
    } >"$report"
    log_ok "Bericht geschrieben: ${report}"
    cat "$report" >&2
}

# ------------------------------------------------------------------------------
# Netzwerk-Suchlauf
# ------------------------------------------------------------------------------
discover() {
    log_step "Suche im ${DEFAULT_DEVICE_NET}.0/24 Netz"
    prepare_network || true
    local scan="${WORK_DIR}/scan-${RUN_ID}.txt" i
    mkdir -p "$WORK_DIR"; : >"$scan"

    log_info "Pinge ${DEFAULT_DEVICE_NET}.1 bis .254 (parallel) ..."
    for i in $(seq 1 254); do
        {
            ping -c 1 -W 1 -n "${DEFAULT_DEVICE_NET}.${i}" >/dev/null 2>&1 \
                && printf '%s\n' "${DEFAULT_DEVICE_NET}.${i}" >>"$scan"
        } &
    done
    wait

    if [[ -s "$scan" ]]; then
        log_ok "Antwortende Adressen:"
        sort -t. -k4 -n "$scan" | while read -r i; do
            printf '   %s\n' "$i" >&2
        done
        log_info "Details zu einer Adresse: ${SCRIPT_NAME} --detect --device-ip <adresse>"
    else
        log_warn "Keine Antwort im Werksnetz. Kabel, Strom und Kippschalter pruefen."
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Eingabe der Zieldaten
# ------------------------------------------------------------------------------
collect_input() {
    log_step "Zieldaten erfassen"

    while [[ -z "$NEW_NAME" ]] || ! is_hostname "$NEW_NAME"; do
        NEW_NAME=$(ui_input "Servername" \
            "Neuer Servername des Geraets\n(Buchstaben, Ziffern, - _ . / max. 39 Zeichen):" \
            "${NEW_NAME:-${DEV_SERVERNAME:-}}") || die "Eingabe abgebrochen." 3
        is_hostname "$NEW_NAME" || log_warn "Ungueltiger Name: '${NEW_NAME}'"
    done

    while [[ -z "$NEW_IP" ]] || ! is_ipv4 "$NEW_IP"; do
        NEW_IP=$(ui_input "IP-Adresse" "Neue IP-Adresse des Geraets:" "$NEW_IP") \
            || die "Eingabe abgebrochen." 3
        is_ipv4 "$NEW_IP" || log_warn "Ungueltige IP-Adresse: '${NEW_IP}'"
    done

    while [[ -z "$NEW_MASK" ]] || ! is_netmask "$NEW_MASK"; do
        NEW_MASK=$(ui_input "Netzmaske" "Subnetzmaske:" "${NEW_MASK:-$DEFAULT_DEVICE_MASK}") \
            || die "Eingabe abgebrochen." 3
        is_netmask "$NEW_MASK" || log_warn "Ungueltige Netzmaske: '${NEW_MASK}'"
    done

    while [[ -z "$NEW_GW" ]] || ! is_ipv4 "$NEW_GW"; do
        NEW_GW=$(ui_input "Gateway" "Gateway-Adresse:" "${NEW_GW:-${NEW_IP%.*}.1}") \
            || die "Eingabe abgebrochen." 3
        is_ipv4 "$NEW_GW" || log_warn "Ungueltige Gateway-Adresse: '${NEW_GW}'"
    done

    if [[ "$NEW_IP" == "$NEW_GW" ]]; then
        log_warn "IP-Adresse und Gateway sind identisch. Bitte pruefen."
    fi

    jlog info "input_collected" "name=${NEW_NAME}" "ip=${NEW_IP}" \
              "mask=${NEW_MASK}" "gw=${NEW_GW}"
    return 0
}

confirm_summary() {
    ui_yesno "Zusammenfassung" \
"Geraet
  Modell    : ${DEV_MODEL:-unbekannt}
  Firmware  : ${DEV_FWVER:-unbekannt}
  Aktuell   : ${DEVICE_IP}

Neue Konfiguration
  Name      : ${NEW_NAME}
  IP        : ${NEW_IP}
  Netzmaske : ${NEW_MASK}
  Gateway   : ${NEW_GW}

Modus: $( ((DRY_RUN)) && echo 'TESTLAUF, es wird nichts veraendert' || echo 'PRODUKTIV' )

Ablauf jetzt starten?"
}

# ------------------------------------------------------------------------------
# Hauptablauf
# ------------------------------------------------------------------------------
main() {
    parse_args "$@"
    load_config_file
    parse_args "$@"   # Kommandozeile gewinnt gegen die Konfigurationsdatei

    mkdir -p "$LOG_DIR" "$WORK_DIR"
    LOG_TXT="${LOG_DIR}/moxa-${RUN_ID}.log"
    LOG_JSON="${LOG_DIR}/moxa-${RUN_ID}.jsonl"
    : >"$LOG_TXT"; : >"$LOG_JSON"

    jlog info "script_start" "version=${SCRIPT_VERSION}" "action=${ACTION}" "dry_run=${DRY_RUN}"
    log_info "${SCRIPT_NAME} ${SCRIPT_VERSION} - Lauf-ID ${RUN_ID}"
    (( DRY_RUN )) && log_warn "TESTLAUF aktiv - es wird nichts am Geraet veraendert."
    if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" ]]; then
        log_info "Als root gestartet. Noetig ist das nicht: das Skript erhebt nur die"
        log_info "Adressbefehle selbst. Siehe '${SCRIPT_NAME} --print-sudoers'."
    fi

    # Braucht weder Werkzeuge noch Netz - deshalb vor der Abhaengigkeitspruefung
    if [[ "$ACTION" == "print-sudoers" ]]; then
        print_sudoers
        exit 0
    fi

    check_deps || exit 1

    case "$ACTION" in
        install-mcc)   install_mcc "$INSTALL_SRC"; exit 0 ;;
        discover)    discover; exit 0 ;;
        net-up)
            prepare_network || die "Staging-Adresse konnte nicht gesetzt werden." 7
            CLEANUP_IP=""; CLEANUP_IFACE=""      # Adresse bewusst stehen lassen
            log_ok "Netz vorbereitet. ${DEVICE_IP} ist jetzt erreichbar."
            log_info "Weboberflaeche: http://${DEVICE_IP}"
            log_info "Danach aufraeumen mit: ${SCRIPT_NAME} --net-down"
            exit 0
            ;;
        net-down)
            net_down
            exit 0
            ;;
    esac

    prepare_network || log_warn "Netzvorbereitung unvollstaendig - versuche es trotzdem."

    ensure_reachable || die "Geraet unter ${DEVICE_IP} nicht erreichbar. Abbruch." 4
    detect_device    || die "Geraet konnte nicht identifiziert werden. Abbruch." 5

    case "$ACTION" in
        detect)
            write_report
            exit 0
            ;;
        export-config)
            mkdir -p "$WORK_DIR"
            local f
            if cfg_export; then
                f="$CFG_EXPORT_FILE"
                log_ok "Datei zum Pruefen der Schluesselnamen: ${f}"
                grep -inE 'model|firmware|version|server name|ipv4|netmask|gateway' "$f" \
                    | head -n 40 >&2 || true
            fi
            exit 0
            ;;
    esac

    collect_input
    confirm_summary || die "Vom Benutzer abgebrochen." 3

    handle_firmware || log_warn "Firmware-Schritt nicht sauber abgeschlossen - fahre fort."
    handle_config   || die "Konfiguration fehlgeschlagen." 6
    verify_result   || log_warn "Verifikation nicht erfolgreich - bitte manuell nachsehen."
    write_report

    if (( KEEP_IP )) && [[ -n "$CLEANUP_IP" ]]; then
        log_info "Hinweis: ${CLEANUP_IP} bleibt gesetzt, damit das Geraet erreichbar bleibt."
    fi
    log_ok "Fertig."
    return 0
}

# Nur ausfuehren, wenn direkt gestartet (erlaubt "source" fuer Tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
