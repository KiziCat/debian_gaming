#!/usr/bin/env bash
# Installs Handheld Daemon (hhd) into /opt/hhd. Run as a separate process so `set -e` really applies.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
USERNAME=${1:?usage: hhd.sh <username>}

# cmake + pkg-config: some of hhd's Python dependencies are compiled from source at pip install time
apt-get install -y python3-venv python3-pip python3-dev libudev-dev libusb-1.0-0-dev build-essential cmake pkg-config
python3 -m venv /opt/hhd
/opt/hhd/bin/pip install --no-input hhd adjustor
ln -sf /opt/hhd/bin/hhd /usr/local/bin/hhd

base=https://raw.githubusercontent.com/hhd-dev/hhd/master/usr/lib
curl -fsSL "$base/udev/rules.d/83-hhd.rules" -o /etc/udev/rules.d/83-hhd.rules
curl -fsSL "$base/udev/hwdb.d/83-hhd.hwdb"   -o /etc/udev/hwdb.d/83-hhd.hwdb || true

cat > /etc/systemd/system/hhd@.service <<'UNIT'
[Unit]
Description=Handheld Daemon for %i

[Service]
Type=simple
ExecStart=/usr/local/bin/hhd --user %i
Nice=-12
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable "hhd@${USERNAME}.service"
