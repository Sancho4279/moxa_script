# moxa_setup.sh

Konfiguration und Firmware-Update fuer Moxa Terminal-/Device-Server unter Ubuntu Desktop.

## Was das Skript macht

1. Legt eine temporaere IP im Werksnetz `192.168.127.0/24` an, damit `192.168.127.254` erreichbar ist
2. Erkennt Modell und Firmwarestand (MCC-Tool, sonst SNMP, sonst Web-Fingerprint, sonst Auswahlmenue)
3. Berechnet den noetigen Upgrade-Pfad und spielt die Firmware in der richtigen Reihenfolge ein
4. Setzt Servername, IP, Netzmaske und Gateway
5. Prueft das Ergebnis unter der neuen IP und schreibt einen Bericht

Protokolliert wird doppelt: menschenlesbar unter `log/moxa-<lauf-id>.log` und maschinenlesbar als JSON-Lines unter `log/moxa-<lauf-id>.jsonl`.

## Einrichtung

```bash
# 1. Abhaengigkeiten
sudo apt install iputils-ping iproute2 curl whiptail snmp unzip

# 2. MCC-Tool von Moxa herunterladen und entpacken
./moxa_setup.sh --install-mcc ~/Downloads/moxa-cli-configuration-tool-linux-utility-v1.6.zip
# Das Linux-ZIP enthaelt selbst wieder .tar.gz-Archive, je Architektur eines.
# Das Skript loest die Verschachtelung auf, waehlt die zu "uname -m" passende
# Variante und meldet den Pfad der Binaerdatei fuer moxa_setup.conf.

# 3. Firmware in ./firmware/ ablegen und manifest.csv pflegen
sha256sum firmware/*.rom      # Pruefsummen in manifest.csv eintragen
```

## Benutzung

```bash
# Interaktiv mit Dialogfuehrung
./moxa_setup.sh

# Testlauf, veraendert nichts
./moxa_setup.sh --dry-run --name ts-rack12-a --ip 10.20.30.41 \
     --mask 255.255.255.0 --gw 10.20.30.1

# Vollautomatisch
./moxa_setup.sh -y --name ts-rack12-a --ip 10.20.30.41 \
     --mask 255.255.255.0 --gw 10.20.30.1

# Nur Firmwarestand ablesen
./moxa_setup.sh --detect

# Werksnetz nach Geraeten absuchen
./moxa_setup.sh --discover

# Adresse setzen und stehen lassen, um im Browser weiterzuarbeiten
./moxa_setup.sh --net-up
xdg-open http://192.168.127.254
./moxa_setup.sh --net-down

# Konfiguration exportieren, um die INI-Schluesselnamen zu pruefen
./moxa_setup.sh --export-config
```

## Feldnamen der Konfigurationsdatei

Die exportierte Datei benutzt `Feldname=Wert` mit Leerzeichen im Feldnamen.
Das Skript vergleicht deshalb exakt und sucht nicht per Regex - in derselben
Datei stehen Felder wie `GSM Netmask`, `V.92 Modem Netmask`,
`IPv4 DNS Server 1`, `Model Name` und `UDP Dest. IP Range Begin #1`, die eine
unscharfe Suche mit erwischen wuerde.

| Rolle | NPort 6000 (am Geraet verifiziert) | NPort 5400 (noch ungeprueft) |
|---|---|---|
| Servername | `Server Name` | `Server Name` |
| IP-Adresse | `IPv4 Address` und `IP Address` | `IP Address` |
| Netzmaske | `IPv4 Netmask` | `Netmask` |
| Gateway | `IPv4 Gateway` | `Gateway` |
| statische IP | `IPv4 Configuration=0` | `IP Configuration=0` |

Wenn eine der Rollen NAME, IP, MASK oder GW in der Exportdatei nicht gefunden
wird, bricht `cfg_patch` ab, statt eine halbe Konfiguration einzuspielen.
Abweichende Namen in `cfg_keys_for_family()` ergaenzen.

Feldnamen eines neuen Modells ermitteln:

```bash
./moxa_setup.sh --export-config
```

## Geraetefamilien

| Familie | Modelle | Weg |
|---|---|---|
| `NPORT6000` | NPort 6610-8/-16/-32, NPort 6650-8/-16/-32 | MCC-Tool ab FW v1.13, darunter Web |
| `NPORT5400` | NPort 5410/5430/5450 | MCC-Tool ab FW v3.13, darunter Web |
| `CN2500` | CN2510-8/-16, CN2500-16 | immer gefuehrt ueber Web bzw. Telnet-Menue |

CN2510 und CN2500 stehen nicht in der Supportliste des MCC-Tools (Manual v2.5, Abschnitt "Supported Models"). Fuer diese Geraete fuehrt das Skript durch die Weboberflaeche, statt einen Automatismus vorzutaeuschen, der nicht funktioniert.

## Wichtige Herstellerregeln, die im Skript verdrahtet sind

- NPort 6000: v1.21 ist Pflichtschritt vor v2.0 und hoeher
- NPort 6000: ab v2.1 sperrt das Geraet Downgrades unter v2.1
- Beim Config-Import darf `-n` nicht gesetzt werden, sonst behaelt das Geraet seine alten Netzwerkparameter und die neue IP greift nicht
- MCC-Fehlercode -16 bedeutet: Firmware zu alt fuer das Tool, erst ueber Web anheben
- MCC-Fehlercode -17 bedeutet: Geraet noch im Auslieferungszustand, erst Passwort setzen

## Wenn das Geraet nicht antwortet

Das Skript fuehrt durch den Hardware-Reset: Reset-Taster mit einer Bueroklammer ca. 5 Sekunden halten, bis die Ready-LED blinkt. Danach ist das Geraet wieder unter `192.168.127.254` erreichbar, Login `admin` / `moxa`. Der Reset loescht die gesamte Konfiguration.

## Pruefung

```bash
bash -n moxa_setup.sh
shellcheck -s bash moxa_setup.sh
```

## Pruefung nach dem Neustart

Nach dem Import liegt das Geraet in einem anderen Subnetz. Dieser Rechner hat
dort in aller Regel keine Adresse und damit keinen Weg dorthin - ein Ping
schlaegt fehl, obwohl die Konfiguration sitzt.

Das Skript geht deshalb in drei Stufen vor:

1. Erst pruefen, ob schon eine Route ins Zielnetz existiert (Firmennetz,
   zweite Netzwerkkarte). Dann reicht ein Ping.
2. Sonst voruebergehend eine freie Adresse im Zielnetz auf dasselbe
   Interface legen. Netz- und Broadcastadresse, die neue Geraete-IP und das
   Gateway sind ausgenommen; jeder Kandidat wird vorher angepingt, damit
   keine belegte Adresse doppelt vergeben wird. Die Praefixlaenge kommt aus
   der eingegebenen Netzmaske, funktioniert also auch bei /22 oder /26.
3. Gegenprobe ueber das MCC-Tool: antwortet unter der neuen Adresse
   dasselbe Geraet? Verglichen wird die MAC-Adresse, zusaetzlich wird der
   Servername gegen die Eingabe geprueft.

Die Pruefadresse wird danach wieder entfernt, auch bei einem Abbruch. Mit
`--no-verify` laesst sich der ganze Schritt ueberspringen.

## Firmware-Update ist optional

Stellt das Skript fest, dass ein neuerer Stand vorliegt, fragt es nach - und
zwar einmal, bevor irgendein Zweig anlaeuft. Auch der gefuehrte Weg ueber die
Weboberflaeche wird sonst angestossen, ohne dass jemand gefragt wurde.

Bei "Nein" bleibt die Firmware unangetastet und der Ablauf geht direkt zur
Konfiguration weiter. Nicht-interaktiv:

```bash
./moxa_setup.sh --no-firmware --name ts-rack12-a --ip 10.20.30.41 \
     --mask 255.255.255.0 --gw 10.20.30.1
```

`-y` bejaht die Frage wie alle anderen auch; `--no-firmware` ueberstimmt das.
Der Bericht haelt in `Firmware-Schritt` fest, was passiert ist: aktualisiert,
abgelehnt, uebersprungen oder gar nicht erst geprueft.

## Geraete ohne Weboberflaeche

Nicht jedes CN2500/CN2510 hat einen Webserver. Erst pruefen, was ueberhaupt
offen ist:

```bash
nmap 192.168.118.44
sudo nmap -sU -p 161 192.168.118.44     # SNMP liegt auf UDP
```

Typisches Bild eines Geraets ohne Weboberflaeche: Port 23 offen (menuegefuehrte
Konsole), dazu 4001 aufwaerts als Datenports der seriellen Schnittstellen -
einer je Port. Kein Port 80 heisst: `moxa_webdump.sh` laeuft hier ins Leere.

Dann stattdessen:

```bash
./moxa_telnetdump.sh 192.168.118.44
```

Das Werkzeug prueft die Erreichbarkeit, zaehlt die offenen Datenports (daraus
ergibt sich die Portzahl des Geraets), zieht einen SNMP-Abzug sofern ein Agent
laeuft, und zeichnet anschliessend eine Telnet-Sitzung mit. Navigiert wird von
Hand - das Skript tippt nichts von sich aus ins Menue. Aus dem Rohmitschnitt
entsteht eine von Steuerzeichen befreite Textfassung.

| Datei | Inhalt |
|---|---|
| `snmpwalk.txt` | maschinenlesbarer Abzug, sofern SNMP laeuft |
| `TELNET-MITSCHNITT.txt` | lesbarer Mitschnitt aller aufgerufenen Menuebildschirme |
| `telnet-roh.log` | Rohfassung mit Steuerzeichen |
| `datenports.txt` | offene Datenports |

## CN2500/CN2510 mit Weboberflaeche: Einstellungen sichern

Diese Baureihe kennt kein Konfigurations-Exportformat, und das MCC-Tool
unterstuetzt sie nicht. Moeglich ist eine vollstaendige Dokumentation aller
Einstellungen; zurueckspielen muss man sie von Hand.

```bash
sudo ip addr add 192.168.118.10/24 dev enp0s31f6     # Adresse im Geraetenetz
./moxa_webdump.sh 192.168.118.44
sudo ip addr del 192.168.118.10/24 dev enp0s31f6
```

`moxa_webdump.sh` stellt ausschliesslich lesende GET-Anfragen und veraendert
nichts. Es entstehen:

| Datei | Inhalt |
|---|---|
| `EINSTELLUNGEN.txt` | alle Formularwerte als lesbare Liste - das eigentliche Backup |
| `ZUSAMMENFASSUNG.txt` | Formularziele, Feldnamen, Upload- und versteckte Felder |
| `pages/` | die Rohseiten, falls in der Auswertung etwas fehlt |
| `headers/` | HTTP-Kopfzeilen, u.a. zur Art der Anmeldung |

Passwortfelder liefert das Geraet nicht aus - die muessen getrennt notiert
werden. Braucht die Oberflaeche eine Anmeldung:

```bash
MOXA_WEB_USER=admin MOXA_WEB_PASS=moxa ./moxa_webdump.sh 192.168.118.44
```

## Rechte: sudo wird kaum gebraucht

Erhoehte Rechte braucht das Skript ausschliesslich fuer drei Aufrufe:
`ip addr add`, `ip addr del` und `ip link set up`. MCC-Tool, Ping, Export und
alle Dateizugriffe laufen unprivilegiert.

Deshalb das Skript **nicht** mit `sudo` starten. Es erhebt diese drei Aufrufe
selbst und fragt bei Bedarf einmal nach dem Passwort:

```bash
./moxa_setup.sh --detect
```

Wer es ganz ohne Rechte will, vergibt die Adresse einmalig dauerhaft und
schaltet die Netzverwaltung im Skript ab:

```bash
sudo nmcli con add type ethernet ifname enp0s31f6 con-name moxa-staging \
     ip4 192.168.127.10/24
./moxa_setup.sh --no-net-setup --no-verify
```

Alternativ eine minimale sudoers-Regel, die nur diese drei Befehle
passwortfrei erlaubt:

```bash
./moxa_setup.sh --print-sudoers | sudo tee /etc/sudoers.d/moxa-setup
sudo visudo -c
```

Wird das Skript trotzdem mit `sudo` gestartet, gehoeren `log/` und `work/`
sonst root. Das Skript gibt sie deshalb am Ende an `$SUDO_USER` zurueck und
weist einmalig darauf hin, dass root nicht noetig ist.

Ohne `--no-net-setup` und ohne Rechte laesst sich die Pruefadresse im
Zielnetz nicht anlegen - die Verifikation nach dem Neustart entfaellt dann.

## Staging-Adresse

Das Skript legt beim Start `192.168.127.10/24` auf dem Kabel-Interface an und
entfernt sie am Ende wieder. Innerhalb des Laufs ist das Geraet damit
erreichbar, danach nicht mehr.

Fuer manuelles Arbeiten am Geraet - Browser, Telnet, eigenes Ping - deshalb:

```bash
./moxa_setup.sh --net-up      # Adresse setzen und stehen lassen
./moxa_setup.sh --net-down    # wieder entfernen
```

`--keep-ip` bewirkt dasselbe fuer einen normalen Lauf. Bei gefuehrten
Web-Schritten setzt das Skript das selbst, sonst waere die Oberflaeche nach
dem Lauf nicht mehr erreichbar.

Kein Ping und keine Webseite trotz gesteckter Kabel? Dann zuerst `ip a`
pruefen: hat das Kabel-Interface eine `inet`-Zeile im `192.168.127.0/24`?
Wenn nicht, fehlt nur die Route, und das Geraet ist voellig in Ordnung.

## Sicherungen gegen falsche Konfiguration

Der Export laeuft in ein leeres Verzeichnis `work/export-<lauf-id>/` und es
gibt keinen Rueckgriff auf aeltere Dateien. Zusaetzlich prueft das Skript vor
dem Patchen, ob `Model Name` und `IP Address` der Exportdatei zum erkannten
Geraet passen, und der Import nimmt nur Dateien aus dem laufenden Durchgang
an. Damit kann die Konfiguration eines Geraets nicht auf einem anderen landen.

Die exportierte Datei hat DOS-Zeilenenden. Das Skript erkennt das und
behaelt sie bei - sonst haetten die geaenderten Zeilen ein anderes
Zeilenende als der Rest der Datei.

## Anmeldung am Geraet

Aeltere NPort-6000-Staende kennen keinen Benutzernamen, nur ein Passwort.
Das MCC-Tool meldet das im Feld `User` als leer (nachgewiesen an einem
NPort 6610-8 mit Firmware v1.17). Wird trotzdem `-u admin` mitgeschickt,
scheitert die Anmeldung mit Fehlercode -2.

Welche Form ein Geraet erwartet, laesst sich vorher nicht ablesen - die
Spalte `User` der Geraeteliste ist dafuer kein Beleg, sie gehoert zur Liste,
die man fuer Stapelverarbeitung selbst befuellt.

Das Skript startet deshalb mit der eingestellten Kombination und probiert
bei Fehlercode -2 oder -17 die in `DEVICE_PASS_LIST` hinterlegten Passwoerter
durch, jeweils mit und ohne Benutzernamen. Die funktionierende Kombination
gilt fuer den Rest des Laufs. Andere Fehlercodes werden nicht wiederholt -
ein fehlender Dateipfad wird nicht besser, wenn man ihn mit anderen
Zugangsdaten nochmal versucht.

Passwoerter landen nicht im Protokoll, nur ihre Position in der Liste.

**Kontosperre:** Ab Firmware v2.0 kann nach mehreren Fehlversuchen eine
Sperre greifen. Bei drei Passwoertern und zwei Anmeldeformen sind es
maximal sechs Versuche. Mit `--no-probe` bleibt es bei einem.

## Fehlercode -17: Auslieferungszustand

Laut Manual v2.5 bedeutet -17, dass am Geraet noch kein Passwort gesetzt ist.
Export und Import verweigert das MCC-Tool dann, unabhaengig davon, welches
Passwort man schickt. Andere Zugangsdaten helfen hier nicht.

Bei fabrikneuen Geraeten ist das der Normalfall. Das Skript setzt deshalb
ohne Rueckfrage `INITIAL_USER` / `INITIAL_PASS` aus `moxa_setup.conf`
(Vorgabe `admin` / `moxa`) und wiederholt die Aktion einmal. Ueberschreiben
mit `--initial-pass`. Von Hand:

```bash
mcc/*/mcc_tool -pw -ch -i 192.168.127.254 -u admin -p '' -npw 'IhrPasswort'
```

Nur `-2` ("Passwort oder Benutzername stimmt nicht") loest das Durchprobieren
der `DEVICE_PASS_LIST` aus.

## Kein stiller Ausweich ins Web

Der gefuehrte Weg ueber die Weboberflaeche greift nur, wenn das MCC-Tool das
Geraet gar nicht bedienen kann (CN2500/CN2510, fehlendes MCC-Tool) oder wenn
er mit `--web` ausdruecklich angefordert wird.

Ein technischer Fehler auf dem CLI-Weg - Anmeldung, Export, Import - fuehrt
nicht mehr in den Browser, sondern bricht mit einer Meldung ab. Ein
fehlgeschlagener Export ist ein Problem, das behoben gehoert, kein Grund fuer
einen Umweg.

## Dialoge und Rueckgabewerte

whiptail zeichnet sein Fenster auf STDOUT und liefert das Ergebnis auf
STDERR. Alle `ui_*`-Funktionen lenken das Fenster deshalb ausdruecklich nach
`/dev/tty`. Sonst landet die komplette Bildschirmausgabe im Rueckgabewert,
sobald eine Funktion mit Rueckfrage innerhalb einer Kommandosubstitution
aufgerufen wird.

Aus demselben Grund gibt `cfg_export` den Dateipfad ueber die Variable
`CFG_EXPORT_FILE` zurueck und nicht ueber STDOUT.

## Wenn das MCC-Tool nicht startet

Das Skript testet die Binaerdatei beim Start mit einem Probelauf und meldet die
Ursache im Klartext, statt sie erst mitten im Export auftauchen zu lassen.

| Exit-Code | Bedeutung | Pruefen |
|---|---|---|
| 126 | gefunden, aber nicht ausfuehrbar | `file`, `chmod +x`, `noexec`-Mount, 32/64-Bit |
| 127 | Bibliothek fehlt | `ldd` auf die Binaerdatei |

```bash
file  mcc/mcc_tool_x64_*/mcc_tool     # Architektur pruefen
ldd   mcc/mcc_tool_x64_*/mcc_tool     # fehlende Bibliotheken
findmnt -no OPTIONS .                 # auf noexec pruefen
```

Die Plugin-Dateien `dsci_mcc.so`, `mxio_mcc.so` und `mgci_mcc.so` muessen neben
der Binaerdatei liegen. Das Skript setzt `LD_LIBRARY_PATH` automatisch auf
dieses Verzeichnis.

