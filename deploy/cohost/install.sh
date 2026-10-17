#!/bin/bash
# Install the Day One keeper as its own systemd service on an existing host. Run as root with
# the bundle and the key file next to it:
#   sudo bash install.sh /tmp/dayone-keeper.tgz /tmp/dayone-testnet.key
# It touches nothing else on the host: its own user (dayone), /opt/dayone, /etc/dayone, its own
# Node under /opt, and one unit (dayone-keeper) capped at 200 MB and a quarter of a CPU.
# Rerunning it upgrades the code and restarts the service.
set -euo pipefail
BUNDLE=$1 KEYFILE=$2
NODE=v24.11.1
ARCH=$(uname -m); case $ARCH in aarch64) ARCH=arm64 ;; x86_64) ARCH=x64 ;; esac
NODEDIR=/opt/node-$NODE-linux-$ARCH
[ -x $NODEDIR/bin/node ] || curl -fsSL https://nodejs.org/dist/$NODE/node-$NODE-linux-$ARCH.tar.xz | tar -xJ -C /opt
id dayone >/dev/null 2>&1 || useradd --system --create-home --home-dir /opt/dayone --shell /sbin/nologin dayone
install -d -m 700 -o root -g root /etc/dayone
install -m 600 -o root -g root "$KEYFILE" /etc/dayone/key
shred -u "$KEYFILE" 2>/dev/null || rm -f "$KEYFILE"
rm -rf /opt/dayone/keeper /opt/dayone/out
tar -xzf "$BUNDLE" -C /opt/dayone
cd /opt/dayone && PATH=$NODEDIR/bin:$PATH npm ci --omit=dev --no-audit --no-fund --silent
chown -R dayone:dayone /opt/dayone

cat > /usr/local/libexec/dayone-env <<'SH'
#!/bin/bash
# The key goes to /run (memory) for the service; it stays root-only on disk in /etc/dayone.
set -euo pipefail
umask 077
mkdir -p /run/dayone
KEY=$(tr -d '[:space:]' < /etc/dayone/key)
case "$KEY" in 0x*) ;; *) KEY=0x$KEY ;; esac
printf 'PRIVATE_KEY=%s\n' "$KEY" > /run/dayone/env
SH
chmod 700 /usr/local/libexec/dayone-env

cat > /etc/systemd/system/dayone-keeper.service <<UNIT
[Unit]
Description=Day One keeper (HyperEVM testnet)
After=network-online.target
Wants=network-online.target

[Service]
User=dayone
WorkingDirectory=/opt/dayone
ExecStartPre=+/usr/local/libexec/dayone-env
EnvironmentFile=/opt/dayone/keeper.env
EnvironmentFile=/run/dayone/env
ExecStart=$NODEDIR/bin/node --disable-warning=ExperimentalWarning keeper/keeper.ts
Restart=always
RestartSec=5
MemoryMax=200M
CPUQuota=25%
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/opt/dayone
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable dayone-keeper >/dev/null
systemctl restart dayone-keeper
sleep 8
systemctl is-active dayone-keeper
journalctl -u dayone-keeper -n 5 --no-pager -o cat
