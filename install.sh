#!/bin/bash
# Installiert die Ölzähler-Kamera auf einem Raspberry Pi (Raspberry Pi OS / Debian 13).
# Aufruf auf dem Pi im Repo-Verzeichnis, als Benutzer mit sudo-Rechten: ./install.sh
# Mehrfach ausführbar; eine vorhandene /etc/morgenfoto.conf bleibt unverändert.
set -euo pipefail
cd "$(dirname "$0")"

# Die systemd-Units laufen als Benutzer flo (User= in systemd/*.service), der
# für den Kamerazugriff in der Gruppe video sein muss.
getent passwd flo >/dev/null || { echo "Benutzer flo fehlt – User= in systemd/*.service anpassen." >&2; exit 1; }
id -nG flo | grep -qw video || { echo "Benutzer flo ist nicht in der Gruppe video." >&2; exit 1; }

sudo apt-get install -y rpicam-apps rsync

sudo install -m 0755 -o root -g root bin/morgenfoto /usr/local/bin/morgenfoto
sudo install -m 0644 -o root -g root systemd/morgenfoto.service systemd/morgenfoto.timer \
    systemd/kamera-stream.service /etc/systemd/system/
if [ ! -e /etc/morgenfoto.conf ]; then
    sudo install -m 0644 -o root -g root config/morgenfoto.conf.example /etc/morgenfoto.conf
    echo "/etc/morgenfoto.conf angelegt – RSYNC_TARGET und PHOTO_OPTS anpassen (siehe README)."
fi

# Der Pi 3 hat keine Echtzeituhr: Ohne diesen Dienst starten Timer vor der
# NTP-Synchronisation, und der Uhrsprung beim Booten löst sie sofort aus.
sudo systemctl enable systemd-time-wait-sync.service
sudo systemctl daemon-reload
sudo systemctl enable --now morgenfoto.timer
systemctl list-timers morgenfoto.timer --no-pager
