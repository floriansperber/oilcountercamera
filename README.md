# oilcountercamera

Ein Raspberry Pi fotografiert einmal täglich das Rollenzählwerk eines Heizöl-Zählers und überträgt das Foto per rsync über SSH an ein Zielsystem, das den Zählerstand ausliest.

- Aufnahme täglich um **10:00** (systemd-Timer)
- Licht über eine Shelly-Steckdose, nur während der Aufnahme
- Zuschnitt direkt in der Kamera auf das Zählwerk: ~150 KB statt ~1,1 MB pro Foto
- Jedes Foto wird **genau einmal** übertragen; was wegen eines Fehlers nicht ankommt, wird beim nächsten Lauf nachgeholt
- Livestream auf Abruf (VLC) zum Ausrichten der Kamera

Die Namen `morgenfoto` und `kamera-stream` stammen aus der ersten Version (Aufnahme um 07:00) und wurden beibehalten.

## Hardware

| Teil | Hinweis |
|---|---|
| Raspberry Pi 3 Model B | 15-poliger Kameraanschluss; das Kabel der Kamera passt direkt. Pi 5 und Zero brauchen ein 22-poliges Adapterkabel. |
| Raspberry Pi Camera Module 3 (12 MP, Sensor IMX708) | Kabel nur stromlos stecken, beim Pi 3 zeigen die Kontakte zum HDMI-Anschluss. |
| Lampe an einer Shelly-Steckdose (getestet: Shelly Plug S Gen3) | Ohne Licht ist das Foto schwarz und der Autofokus findet nichts. Gemessen am Zähler: 0,4 Lux ohne Licht, 60–260 Lux mit Lampe. Siehe [Licht](#licht). |

Die Kamera stellt ab etwa 8–10 cm scharf. Liegt sie zu nah am Zähler, bleibt das Objektiv am Nahanschlag (`LensPosition` 12) und die Ziffern werden weich.

## Software

Getestet mit Raspberry Pi OS auf Basis von Debian 13 (trixie), `rpicam-apps` 1.13 und `rsync` 3.5. In `/boot/firmware/config.txt` muss `camera_auto_detect=1` stehen (Standard). Prüfen:

```bash
rpicam-still --list-cameras      # erwartet: 0 : imx708 [4608x2592 ...]
```

## Dateien

| Im Repo | Auf dem Pi | Zweck |
|---|---|---|
| `bin/morgenfoto` | `/usr/local/bin/morgenfoto` | Foto aufnehmen, übertragen, lokal aufräumen |
| `config/morgenfoto.conf.example` | `/etc/morgenfoto.conf` | Einstellungen: Ziel, SSH-Schlüssel, Ausschnitt, Licht, Aufbewahrung |
| `systemd/morgenfoto.service` | `/etc/systemd/system/` | führt das Skript einmal als Benutzer `flo` aus |
| `systemd/morgenfoto.timer` | `/etc/systemd/system/` | startet den Dienst täglich um 10:00 |
| `systemd/kamera-stream.service` | `/etc/systemd/system/` | Livestream zum Ausrichten, nur auf Abruf |
| `install.sh` | – | installiert alles oben Genannte |

Laufzeitdaten auf dem Pi:

```
/var/lib/morgenfoto/            noch nicht übertragene Fotos (JJJJ-MM-TT_HHMM.jpg)
/var/lib/morgenfoto/gesendet/   übertragene Fotos, werden nach KEEP_DAYS Tagen gelöscht
```

## Installation

1. Kamera anschließen, Pi starten, Kamera mit `rpicam-still --list-cameras` prüfen.
2. Repo auf den Pi holen und installieren:
   ```bash
   git clone https://github.com/floriansperber/oilcountercamera.git
   cd oilcountercamera
   ./install.sh
   ```
   Die Units laufen als Benutzer `flo`. Wer einen anderen Benutzer verwendet, passt `User=`/`Group=` in `systemd/*.service` und `SSH_KEY` in der Konfiguration an.
3. Kamera ausrichten (siehe [Livestream](#livestream)) und den [Bildausschnitt bestimmen](#bildausschnitt-bestimmen).
4. [Zielsystem einrichten](#zielsystem) und `RSYNC_TARGET` in `/etc/morgenfoto.conf` eintragen, ebenso `LIGHT_URL` für das [Licht](#licht).
5. Testlauf:
   ```bash
   sudo systemctl start morgenfoto.service
   journalctl -u morgenfoto.service -n 20
   ```

## Zielsystem

Das Zielsystem braucht:

- **rsync**: rsync startet über SSH einen zweiten rsync-Prozess auf dem Ziel. Fehlt er, scheitert die Übertragung mit `rsync: command not found`.
- **Einen Benutzer mit Heimatverzeichnis** für `~/.ssh/authorized_keys`. Systembenutzer haben oft `/nonexistent` als Heimatverzeichnis; dann `sudo usermod -d /home/<benutzer> <benutzer>` und `sudo mkhomedir_helper <benutzer>`.
- **Einen Eingangsordner**, in den dieser Benutzer schreiben darf.

Schlüssel auf dem Pi erzeugen und übertragen (ohne Passphrase, damit der Timer ohne Eingabe läuft):

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id -i ~/.ssh/id_ed25519.pub <benutzer>@<zielserver>
```

`SSH_KEY` in `/etc/morgenfoto.conf` muss auf genau den übertragenen Schlüssel zeigen. Weil der Schlüssel keine Passphrase hat, empfiehlt es sich, ihn auf dem Ziel mit `rrsync` (Teil des rsync-Pakets) auf den Eingangsordner zu beschränken.

### Warum jedes Foto nur einmal übertragen wird

Das Zielsystem holt die Fotos aus dem Eingangsordner ab und verschiebt sie nach der Verarbeitung. Ein Abgleich des ganzen lokalen Archivs würde deshalb jeden Tag alle Fotos erneut einliefern. Das Skript macht es so:

1. Vor der Übertragung bekommt jedes noch nicht gesendete Foto einen **Hardlink** in `gesendet/`. Das ist ein zweiter Name für dieselbe Datei und kostet keinen Platz.
2. `rsync --remove-source-files` entfernt jedes Foto erst nach **seiner** erfolgreichen Übertragung aus dem Hauptordner. Was nicht ankommt, bleibt dort und geht beim nächsten Lauf mit.
3. rsync schreibt auf dem Ziel zuerst in eine versteckte Temp-Datei (`.name.XXXXXX`) und benennt sie am Ende um. Ein Programm, das den Ordner überwacht und versteckte Dateien ignoriert, sieht daher nie ein halbes Foto.

## Licht

Das Skript schaltet vor der Aufnahme eine Lampe über die lokale HTTP-API einer Shelly-Steckdose (Gen2/Gen3) ein und danach wieder aus. In `/etc/morgenfoto.conf`:

```bash
LIGHT_URL=http://shellyplugsg3-xxxxxxxxxxxx.lan   # leer = Licht nicht schalten
LIGHT_WARMUP=2                                    # Sekunden zwischen Licht an und Aufnahme
```

- **Hostname statt IP:** Die Steckdose bezieht ihre IPv4-Adresse per DHCP. Unter ihrem Namen (`shellyplug…` plus lokale Domain, z. B. `.lan` oder `.fritz.box`) bleibt sie auch nach einem Adresswechsel erreichbar.
- **Zustand wird respektiert:** Brennt das Licht schon (jemand ist im Raum), schaltet das Skript es weder ein noch aus.
- **Sicherheitsnetz:** Eingeschaltet wird mit `Switch.Set?id=0&on=true&toggle_after=120`, die Steckdose schaltet also spätestens nach 120 s selbst ab, auch wenn das Skript abbricht. Das reguläre Ausschalten erledigt ein `trap` beim Skriptende.
- **Steckdose nicht erreichbar:** Es gibt eine Warnung im Journal, fotografiert wird trotzdem.
- Die Lampe schräg von der Seite auf das Zählwerk richten, sonst spiegelt sie sich in der gewölbten Abdeckung über den Ziffern.

Prüfen, ob der Pi die Steckdose erreicht:

```bash
curl "$LIGHT_URL/rpc/Switch.GetStatus?id=0"     # "output":true/false
```

Für den Livestream oder das Kalibrieren des Ausschnitts wird das Licht nicht automatisch geschaltet; dafür die Lampe per Shelly-App oder Weboberfläche einschalten.

## Livestream

Zum Ausrichten der Kamera:

```bash
sudo systemctl start kamera-stream     # einschalten
sudo systemctl stop kamera-stream      # ausschalten
```

In VLC (*Ablage → Netzwerk öffnen*): `tcp/h264://<pi>:8888`. Mit weniger Verzögerung: `vlc --network-caching=300 tcp/h264://<pi>:8888`.

- Der Stream zeigt das ganze Bild im selben Ausschnitt wie das unbeschnittene Foto (`--mode 2304:1296` nutzt den ganzen Sensor).
- Ein Zuschauer zur Zeit; nach dem Trennen ist der Stream nach etwa einer Sekunde wieder bereit.
- Kein Autostart. `Conflicts=morgenfoto.service` beendet den Stream automatisch, bevor das Foto aufgenommen wird, denn die Kamera kann nur ein Programm gleichzeitig nutzen.
- Unverschlüsselt und ohne Passwort; nur kurzzeitig im Heimnetz verwenden.

## Bildausschnitt bestimmen

`PHOTO_OPTS` schneidet das Foto in der Kamera zu. `--roi x,y,breite,höhe` gibt den Ausschnitt als Anteil des ganzen Sensorbilds (4608×2592) an; `--width`/`--height` sind die Pixelmaße desselben Ausschnitts, damit nichts skaliert wird. Nach jedem Verschieben der Kamera neu bestimmen:

1. **Licht einschalten.** Im Dunkeln wird das Bild schwarz und der Autofokus bleibt auf unendlich.
2. Stream beenden und ein Vollbild ohne Zuschnitt aufnehmen:
   ```bash
   sudo systemctl stop kamera-stream
   rpicam-still -n -t 3000 --autofocus-on-capture -o /tmp/vollbild.jpg
   ```
3. Im Vollbild die Pixelkoordinaten der fünf Ziffernfenster ablesen und großzügig Rand zugeben (bewährt: ~300 px seitlich, ~250 px oben und unten), damit ein leichtes Verrutschen keine Ziffern abschneidet.
4. In Anteile umrechnen, z. B. für den Ausschnitt x=1048, y=1350, 2016×832 px:
   ```bash
   python3 -c "print('%.4f,%.4f,%.4f,%.4f' % (1048/4608, 1350/2592, 2016/4608, 832/2592))"
   ```
   ergibt `PHOTO_OPTS="--roi 0.2274,0.5208,0.4375,0.3210 --width 2016 --height 832 --quality 80"`.
5. Testen, ohne dass das Foto ins Archiv oder ans Ziel geht:
   ```bash
   printf '. /etc/morgenfoto.conf\nPHOTO_DIR=/tmp/roitest\nRSYNC_TARGET=\n' > /tmp/roitest.conf
   MORGENFOTO_CONF=/tmp/roitest.conf /usr/local/bin/morgenfoto
   ```

`PHOTO_OPTS` gilt nur für das Foto, `RPICAM_OPTS` für Foto **und** Stream (z. B. `--rotation 180`). Größenangaben gehören nicht in `RPICAM_OPTS`: Der Stream setzt `--width`/`--height` selbst, und `rpicam-vid` bricht ab, wenn eine Option doppelt angegeben ist.

## Betrieb

```bash
systemctl list-timers morgenfoto.timer     # nächster Lauf
journalctl -u morgenfoto.service           # Ausgaben und Fehler
ls /var/lib/morgenfoto/                    # noch nicht übertragene Fotos
```

Uhrzeit ändern: `OnCalendar=` in `/etc/systemd/system/morgenfoto.timer`, danach `sudo systemctl daemon-reload && sudo systemctl restart morgenfoto.timer`. Für einen einmaligen Test eignet sich eine Zusatzdatei `/etc/systemd/system/morgenfoto.timer.d/test.conf` mit `OnCalendar=` (leer, setzt zurück) und `OnCalendar=*-*-* HH:MM:00`, die nach dem Test wieder gelöscht wird.

### Stolpersteine

- **Keine Echtzeituhr:** Der Pi 3 bootet mit der Uhrzeit des letzten Herunterfahrens. Springt die Uhr durch NTP über die Aufnahmezeit, startet der Timer sofort. `install.sh` aktiviert deshalb `systemd-time-wait-sync.service`, das Timer bis zur Synchronisation zurückhält.
- **Kein `Persistent=true` im Timer:** War der Pi zur Aufnahmezeit aus, wird das Foto bewusst nicht beim Hochfahren zu einer beliebigen Uhrzeit nachgeholt.
- **Fehlerhafte Läufe** enden mit Exit-Code ≠ 0; der Dienst steht dann in `systemctl --failed`, die Fotos bleiben erhalten.
