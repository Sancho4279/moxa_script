#!/usr/bin/env bash
# ==============================================================================
#  moxa_webdump.sh - sammelt die Struktur des Moxa-Webinterfaces ein
# ------------------------------------------------------------------------------
#  Zweck: Grundlage schaffen, um Firmware-Update und Neustart eines CN2500/
#         CN2510 ueber das Webinterface zu automatisieren.
#
#  WICHTIG: Dieses Werkzeug stellt ausschliesslich lesende GET-Anfragen.
#           Es sendet keine Formulare ab und veraendert nichts am Geraet.
#
#  Ergebnis: ein Verzeichnis mit allen erreichbaren Seiten, den HTTP-Kopfzeilen
#            und einer Zusammenfassung der gefundenen Formulare.
# ==============================================================================

set -Eeuo pipefail

DEVICE_IP="${1:-192.168.127.254}"
OUTDIR="${2:-webdump-${DEVICE_IP//./_}-$(date +%Y%m%d-%H%M%S)}"
USER_NAME="${MOXA_WEB_USER:-}"
PASSWORD="${MOXA_WEB_PASS:-moxa}"
MAXDEPTH=2

# Alte eingebettete Webserver vertragen oft kein HTTP/1.1 mit Chunking
CURL_OPTS=(-s -k --http1.0 --max-time 15 -A "Mozilla/5.0")
[[ -n "$USER_NAME" ]] && CURL_OPTS+=(-u "${USER_NAME}:${PASSWORD}")

COOKIES="${OUTDIR}/cookies.txt"
SEEN_FILE=""
declare -a QUEUE=()

log() { printf '%s\n' "$*" >&2; }

# Pfad -> Dateiname
flatten() {
    local p="${1#/}"
    p="${p//\//__}"
    [[ -z "$p" ]] && p="index"
    [[ "$p" == *.* ]] || p="${p}.html"
    printf '%s' "$p"
}

fetch() {
    local path="$1" name body
    name="$(flatten "$path")"
    [[ -f "${OUTDIR}/pages/${name}" ]] && return 0
    grep -qxF "$path" "$SEEN_FILE" 2>/dev/null && return 0
    printf '%s\n' "$path" >>"$SEEN_FILE"

    log "  GET ${path}"
    curl "${CURL_OPTS[@]}" -c "$COOKIES" -b "$COOKIES" \
         -D "${OUTDIR}/headers/${name}.hdr" \
         -o "${OUTDIR}/pages/${name}" \
         "http://${DEVICE_IP}${path}" || {
        log "      -> keine Antwort"
        return 0
    }
    body="${OUTDIR}/pages/${name}"
    [[ -s "$body" ]] || { log "      -> leer"; return 0; }

    # Verweise einsammeln: Frames, Links, Formularziele, JavaScript-Sprünge
    {
        grep -oiE '(src|href|action)[[:space:]]*=[[:space:]]*"[^"]+"' "$body" 2>/dev/null \
            | sed -E 's/.*"([^"]+)"/\1/'
        grep -oiE "(src|href|action)[[:space:]]*=[[:space:]]*'[^']+'" "$body" 2>/dev/null \
            | sed -E "s/.*'([^']+)'/\1/"
        grep -oiE '(src|href|action)[[:space:]]*=[[:space:]]*[A-Za-z0-9_./?=&-]+' "$body" 2>/dev/null \
            | sed -E 's/.*=[[:space:]]*//'
        grep -oiE 'location(\.href)?[[:space:]]*=[[:space:]]*"[^"]+"' "$body" 2>/dev/null \
            | sed -E 's/.*"([^"]+)"/\1/' || true
    } | sort -u >>"${OUTDIR}/links.raw" || true
    # Ein grep ohne Treffer darf den Durchlauf nicht beenden (pipefail)
    return 0
}

normalize_links() {
    local l
    : >"${OUTDIR}/links.txt"
    while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        case "$l" in
            http*|mailto:*|javascript:*|'#'*) continue ;;
        esac
        l="${l%%#*}"
        [[ "$l" != /* ]] && l="/${l}"
        printf '%s\n' "$l"
    done <"${OUTDIR}/links.raw" | sort -u >"${OUTDIR}/links.txt"
}

# ------------------------------------------------------------------------------
mkdir -p "${OUTDIR}/pages" "${OUTDIR}/headers"
SEEN_FILE="${OUTDIR}/seen.txt"
: >"$SEEN_FILE"; : >"${OUTDIR}/links.raw"

log "Sammle Webinterface von ${DEVICE_IP} nach ${OUTDIR}/"
log ""
log "Nur lesende Zugriffe - am Geraet wird nichts veraendert."
log ""

# Startseite und die bei alten Moxa-Geraeten ueblichen Einstiegspunkte
log "Runde 1: Startseite und bekannte Einstiegspunkte"
for p in / /index.htm /index.html /main.htm /home.htm /menu.htm \
         /overview.htm /Login.htm /login.htm; do
    fetch "$p"
done

for (( round = 2; round <= MAXDEPTH; round++ )); do
    normalize_links
    mapfile -t QUEUE <"${OUTDIR}/links.txt"
    (( ${#QUEUE[@]} )) || break
    log ""
    log "Runde ${round}: ${#QUEUE[@]} gefundene Verweise"
    for p in "${QUEUE[@]}"; do
        fetch "$p"
    done
done
normalize_links

# ------------------------------------------------------------------------------
# Zusammenfassung: alles, was fuer die Automatisierung zaehlt
# ------------------------------------------------------------------------------
SUM="${OUTDIR}/ZUSAMMENFASSUNG.txt"

# In der Auswertung ist ein grep ohne Treffer der Normalfall und kein Fehler.
set +e
{
    printf 'Moxa Webinterface-Analyse\n'
    printf '=========================\n'
    printf 'Geraet    : %s\n' "$DEVICE_IP"
    printf 'Zeitpunkt : %s\n' "$(date -Is)"
    printf 'Seiten    : %s\n\n' "$(find "${OUTDIR}/pages" -type f | wc -l)"

    printf 'ANMELDUNG\n---------\n'
    if grep -rliE 'www-authenticate' "${OUTDIR}/headers" >/dev/null 2>&1; then
        printf 'HTTP-Authentifizierung gefunden:\n'
        grep -rhiE 'www-authenticate.*' "${OUTDIR}/headers" | sort -u | sed 's/^/  /'
    else
        printf 'Keine HTTP-Authentifizierung in den Kopfzeilen.\n'
    fi
    if [[ -s "$COOKIES" ]]; then
        printf 'Cookies:\n'
        grep -v '^#' "$COOKIES" | sed 's/^/  /'
    fi
    printf '\n'

    printf 'FORMULARE\n---------\n'
    printf 'Fuer die Automatisierung zaehlen: action, method, enctype und alle\n'
    printf 'Feldnamen - besonders das Dateifeld des Firmware-Uploads.\n\n'
    for f in "${OUTDIR}"/pages/*; do
        [[ -f "$f" ]] || continue
        grep -qiE '<form' "$f" || continue
        printf -- '--- %s ---\n' "$(basename "$f")"
        grep -oiE '<form[^>]*>' "$f" | sed 's/^/  /'
        grep -oiE '<input[^>]*>' "$f" | sed 's/^/    /'
        grep -oiE '<select[^>]*>' "$f" | sed 's/^/    /'
        printf '\n'
    done

    printf 'SEITEN MIT BEZUG ZU FIRMWARE / NEUSTART\n'
    printf -- '---------------------------------------\n'
    grep -rliE 'firmware|upgrade|update|restart|reboot|save.*restart' \
        "${OUTDIR}/pages" 2>/dev/null | sed 's/^/  /'
    printf '\n'

    printf 'DATEI-UPLOAD-FELDER\n-------------------\n'
    grep -rhoiE '<input[^>]*type[[:space:]]*=[[:space:]]*"?file"?[^>]*>' \
        "${OUTDIR}/pages" 2>/dev/null | sort -u | sed 's/^/  /'
    printf '\n'

    printf 'VERSTECKTE FELDER (oft Sitzungskennungen)\n'
    printf -- '-----------------------------------------\n'
    grep -rhoiE '<input[^>]*type[[:space:]]*=[[:space:]]*"?hidden"?[^>]*>' \
        "${OUTDIR}/pages" 2>/dev/null | sort -u | sed 's/^/  /'
    printf '\n'

    printf 'ALLE GEFUNDENEN PFADE\n---------------------\n'
    sed 's/^/  /' "${OUTDIR}/links.txt"
} >"$SUM"
set -e

# ------------------------------------------------------------------------------
# Einstellungs-Sicherung
#
# Fuer CN2500/CN2510 gibt es kein Konfigurations-Exportformat. Die abgerufenen
# Seiten enthalten aber saemtliche aktuellen Werte in ihren Formularfeldern.
# Daraus entsteht hier eine lesbare Liste als Dokumentations-Backup.
# ------------------------------------------------------------------------------

# Holt den Wert eines Attributs aus einem HTML-Tag, mit oder ohne Anfuehrungszeichen
tag_attr() {
    local tag="$1" name="$2" v
    v=$(sed -nE "s/.*[[:space:]]${name}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/Ip" <<<"$tag")
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    v=$(sed -nE "s/.*[[:space:]]${name}[[:space:]]*=[[:space:]]*'([^']*)'.*/\1/Ip" <<<"$tag")
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    v=$(sed -nE "s/.*[[:space:]]${name}[[:space:]]*=[[:space:]]*([^\"'[:space:]>]+).*/\1/Ip" <<<"$tag")
    printf '%s' "$v"
}

extract_fields() {
    local f="$1" tag type name value state
    # Eingabefelder
    grep -oiE '<input[^>]*>' "$f" 2>/dev/null | while IFS= read -r tag; do
        type="$(tag_attr "$tag" type)"; type="${type:-text}"
        case "${type,,}" in submit|button|reset|image) continue ;; esac
        name="$(tag_attr "$tag" name)"
        [[ -n "$name" ]] || continue
        value="$(tag_attr "$tag" value)"
        case "${type,,}" in
            checkbox|radio)
                state="aus"
                grep -qi 'checked' <<<"$tag" && state="AN"
                printf '  %-32s %-6s [%s %s]\n' "$name" "$state" "$type" "$value"
                ;;
            password)
                printf '  %-32s (Passwortfeld, nicht auslesbar)\n' "$name"
                ;;
            *)
                printf '  %-32s %s\n' "$name" "${value:-(leer)}"
                ;;
        esac
    done
    # Auswahlfelder: aktuell gewaehlte Option
    local cur=""
    grep -oiE '<select[^>]*>|<option[^>]*>' "$f" 2>/dev/null | while IFS= read -r tag; do
        if grep -qiE '^<select' <<<"$tag"; then
            cur="$(tag_attr "$tag" name)"
        elif grep -qi 'selected' <<<"$tag" && [[ -n "$cur" ]]; then
            printf '  %-32s %s  [Auswahl]\n' "$cur" "$(tag_attr "$tag" value)"
        fi
    done
}

CFGDUMP="${OUTDIR}/EINSTELLUNGEN.txt"
set +e
{
    printf 'Moxa Einstellungs-Sicherung\n'
    printf '===========================\n'
    printf 'Geraet    : %s\n' "$DEVICE_IP"
    printf 'Zeitpunkt : %s\n' "$(date -Is)"
    printf '\nAusgelesen aus den Formularfeldern der Weboberflaeche.\n'
    printf 'Diese Baureihe kennt kein Import-Format: zum Zurueckspielen muessen\n'
    printf 'die Werte von Hand eingetragen werden.\n'
    printf 'Passwortfelder liefert das Geraet nicht aus.\n\n'

    for f in "${OUTDIR}"/pages/*; do
        [[ -f "$f" ]] || continue
        grep -qiE '<input|<select' "$f" || continue
        printf -- '=== %s ===\n' "$(basename "$f")"
        extract_fields "$f"
        printf '\n'
    done

    printf '=== Sichtbarer Text der Informationsseiten ===\n'
    printf '(Modell, Seriennummer und Firmwarestand stehen dort meist als Text)\n\n'
    for f in "${OUTDIR}"/pages/*; do
        [[ -f "$f" ]] || continue
        grep -qiE 'model|firmware|serial|mac address' "$f" || continue
        printf -- '--- %s ---\n' "$(basename "$f")"
        sed -e 's/<[^>]*>/ /g' -e 's/&nbsp;/ /g' "$f" \
            | tr -s ' \t' ' ' | grep -vE '^[[:space:]]*$' | sed 's/^ */  /'
        printf '\n'
    done
} >"$CFGDUMP"
set -e

log "Einstellungen   : ${CFGDUMP}"

log ""
log "Fertig."
log "Zusammenfassung : ${SUM}"
log "Rohseiten       : ${OUTDIR}/pages/"
log ""
log "Zum Verschicken einpacken:"
log "  tar czf ${OUTDIR}.tar.gz ${OUTDIR}"
