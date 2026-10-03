#!/usr/bin/env bash
# ==============================================================================
#  moxa_telnetdump.sh - Einstellungen alter Moxa-Geraete ueber Telnet sichern
# ------------------------------------------------------------------------------
#  Fuer Geraete ohne Weboberflaeche (CN2500, CN2510 und aehnliche). Diese
#  Baureihen kennen kein Konfigurations-Exportformat. Moeglich ist:
#
#    1. SNMP-Abzug, sofern der Agent laeuft - maschinenlesbar, das beste Backup
#    2. Aufzeichnung einer menuegefuehrten Telnet-Sitzung als Protokoll
#
#  Das Skript zeichnet nur auf. Es tippt nichts von sich aus ins Menue und
#  loest keine Aktion am Geraet aus - navigiert wird von Hand.
# ==============================================================================

set -Eeuo pipefail

DEVICE_IP="${1:-}"
OUTDIR="${2:-}"
SNMP_COMMUNITY="${MOXA_SNMP_COMMUNITY:-public}"

if [[ -z "$DEVICE_IP" ]]; then
    cat <<EOF
Aufruf: ${0##*/} <ip-adresse> [ausgabeverzeichnis]

Beispiel:
  ${0##*/} 192.168.118.44

Umgebung:
  MOXA_SNMP_COMMUNITY   SNMP-Community (Vorgabe: public)
EOF
    exit 2
fi

OUTDIR="${OUTDIR:-telnetdump-${DEVICE_IP//./_}-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTDIR"

log()  { printf '%s\n' "$*" >&2; }
head2() { printf '\n=== %s ===\n' "$*" >&2; }

# ------------------------------------------------------------------------------
# 1. Erreichbarkeit
# ------------------------------------------------------------------------------
head2 "Erreichbarkeit"
if ping -c 2 -W 2 -n "$DEVICE_IP" >/dev/null 2>&1; then
    log "Ping: Geraet antwortet."
else
    log "Ping: keine Antwort. Liegt eine Adresse im selben Netz auf diesem Rechner?"
    log "  ip -4 addr show | grep inet"
fi

if timeout 4 bash -c "exec 3<>/dev/tcp/${DEVICE_IP}/23" 2>/dev/null; then
    log "Telnet (23): offen."
else
    log "Telnet (23): geschlossen. Ohne Telnet bleibt nur die serielle Konsole."
    log "Dafuer ein Nullmodemkabel an den Konsolenport, dann z.B.:"
    log "  screen /dev/ttyUSB0 19200"
    exit 1
fi

# Datenports der seriellen Schnittstellen zaehlen: 4001 aufwaerts
head2 "Serielle Datenports"
{
    printf 'Offene Datenports (4001 aufwaerts, einer je serieller Schnittstelle):\n'
    found=0
    for ((p = 4001; p <= 4032; p++)); do
        if timeout 1 bash -c "exec 3<>/dev/tcp/${DEVICE_IP}/${p}" 2>/dev/null; then
            printf '  %s\n' "$p"
            found=$((found + 1))
        fi
    done
    printf 'Summe: %s Port(s) - das entspricht der Portzahl des Geraets.\n' "$found"
} | tee "${OUTDIR}/datenports.txt" >&2

# ------------------------------------------------------------------------------
# 2. SNMP-Abzug, falls moeglich
# ------------------------------------------------------------------------------
head2 "SNMP"
if command -v snmpwalk >/dev/null 2>&1; then
    log "Frage SNMP-Agent ab (Community '${SNMP_COMMUNITY}') ..."
    if snmpwalk -v1 -c "$SNMP_COMMUNITY" -t 3 -r 1 -On "$DEVICE_IP" .1.3.6.1 \
        >"${OUTDIR}/snmpwalk.txt" 2>"${OUTDIR}/snmpwalk.err"; then
        log "SNMP-Abzug: $(wc -l <"${OUTDIR}/snmpwalk.txt") Zeilen in ${OUTDIR}/snmpwalk.txt"
        log "Das ist der maschinenlesbare Teil der Sicherung."
        # Systembeschreibung herausziehen
        grep -m1 '1.3.6.1.2.1.1.1.0' "${OUTDIR}/snmpwalk.txt" 2>/dev/null \
            | sed 's/^/  /' >&2 || true
    else
        rm -f "${OUTDIR}/snmpwalk.txt"
        log "Kein SNMP-Agent erreichbar oder andere Community."
        log "Community pruefen mit: MOXA_SNMP_COMMUNITY=<name> ${0##*/} ${DEVICE_IP}"
    fi
else
    log "snmpwalk ist nicht installiert - SNMP-Abzug entfaellt."
    log "Nachinstallieren mit: sudo apt install snmp"
fi

# ------------------------------------------------------------------------------
# 3. Aufgezeichnete Telnet-Sitzung
# ------------------------------------------------------------------------------
RAW="${OUTDIR}/telnet-roh.log"
CLEAN="${OUTDIR}/TELNET-MITSCHNITT.txt"

command -v telnet >/dev/null 2>&1 || {
    log ""
    log "telnet fehlt. Nachinstallieren mit: sudo apt install telnet"
    exit 1
}
command -v script >/dev/null 2>&1 || {
    log ""
    log "script fehlt (Paket bsdextrautils bzw. util-linux)."
    exit 1
}

cat >&2 <<EOF

=== Telnet-Sitzung ===

Es wird gleich eine Verbindung zu ${DEVICE_IP} aufgebaut und alles
mitgeschnitten. Navigiere von Hand durch die Menuepunkte; jeder Bildschirm,
den du aufrufst, landet im Protokoll.

Sinnvolle Reihenfolge:
  1. Server settings / Basic settings   Name, Zeitzone, Passwort-Einstellung
  2. Network settings                   IP, Netzmaske, Gateway, DNS
  3. Serial settings                    je Port: Baudrate, Datenbits, Parity,
                                        Stopbits, Flusskontrolle
  4. Operating settings                 je Port: Betriebsart und deren Parameter
  5. Accessible IP settings             Zugriffsfilter
  6. Auto warning settings              Alarmierung
  7. Monitor / System status            Firmwarestand, Seriennummer, MAC

FINGER WEG von:
  - Load factory default
  - Restart / Save and restart
  - allem unter Firmware upgrade

Beenden: im Menue "Exit" waehlen, oder Strg-] und dann "quit".

EOF
read -r -p "Mit Enter starten (Strg-C bricht ab) ..." _ </dev/tty || true

set +e
script -q -c "telnet ${DEVICE_IP}" "$RAW"
RC=$?
set -e

# ------------------------------------------------------------------------------
# 4. Protokoll lesbar machen
# ------------------------------------------------------------------------------
if [[ -s "$RAW" ]]; then
    # Steuerzeichen der Vollbildmenues entfernen: ANSI-Sequenzen, Rueckschritte,
    # Wagenruecklauf. Uebrig bleibt der lesbare Text.
    sed -e 's/\x1B\[[0-9;?]*[A-Za-z]//g' \
        -e 's/\x1B[()][A-Z0-9]//g' \
        -e 's/\x1B[=>]//g' \
        -e 's/\x0f//g' -e 's/\x0e//g' \
        -e 's/\r$//' "$RAW" \
        | cat -v | sed -e 's/\^\[//g' -e 's/\^M//g' \
        | grep -vE '^[[:space:]]*$' >"$CLEAN" || true

    {
        printf '\nMoxa Telnet-Mitschnitt\n'
        printf 'Geraet    : %s\n' "$DEVICE_IP"
        printf 'Zeitpunkt : %s\n' "$(date -Is)"
        printf 'Rohdatei  : %s\n' "$RAW"
    } >>"$CLEAN"

    log ""
    log "Mitschnitt : ${CLEAN}  ($(wc -l <"$CLEAN") Zeilen)"
    log "Rohfassung : ${RAW}"
else
    log ""
    log "Es wurde nichts aufgezeichnet (Exit-Code ${RC})."
fi

log ""
log "Alles zusammen einpacken:"
log "  tar czf ${OUTDIR}.tar.gz ${OUTDIR}"
