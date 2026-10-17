#!/bin/bash
# Install the Day One keeper as its own systemd service on an existing host. Run as root with
# the bundle and the key file next to it:
#   sudo bash install.sh /tmp/dayone-keeper.tgz /tmp/dayone-testnet.key
# It touches nothing else on the host: its own user (dayone), /opt/dayone, /etc/dayone (the key,
# readable only by dayone), its own
# Node under /opt, and one unit (dayone-keeper) capped at 200 MB and a quarter of a CPU.
# Rerunning it upgrades the code and restarts the service.
set -euo pipefail
BUNDLE=$1 KEYFILE=$2
NODE=v24.11.1
ARCH=$(uname -m); case $ARCH in aarch64) ARCH=arm64 ;; x86_64) ARCH=x64 ;; esac
NODEDIR=/opt/node-$NODE-linux-$ARCH
[ -x $NODEDIR/bin/node ] || curl -fsSL https://nodejs.org/dist/$NODE/node-$NODE-linux-$ARCH.tar.gz | tar -xz -C /opt
id dayone >/dev/null 2>&1 || useradd --system --create-home --home-dir /opt/dayone --shell /sbin/nologin dayone
install -d -m 500 -o dayone -g dayone /etc/dayone
install -m 400 -o dayone -g dayone "$KEYFILE" /etc/dayone/key
shred -u "$KEYFILE" 2>/dev/null || rm -f "$KEYFILE"
rm -rf /opt/dayone/keeper /opt/dayone/out
tar -xzf "$BUNDLE" -C /opt/dayone
cd /opt/dayone && PATH=$NODEDIR/bin:$PATH npm ci --omit=dev --no-audit --no-fund --silent
chown -R dayone:dayone /opt/dayone

# The key is readable only by the dayone user (and root); run.sh puts it in the keeper's
# environment and nowhere else.
cat > /opt/dayone/run.sh <<'SH'
#!/bin/bash
set -euo pipefail
KEY=$(tr -d '[:space:]' < /etc/dayone/key)
case "$KEY" in 0x*) ;; *) KEY=0x$KEY ;; esac
export PRIVATE_KEY=$KEY
exec "$NODE_BIN" --disable-warning=ExperimentalWarning keeper/keeper.ts
SH
chmod 755 /opt/dayone/run.sh
rm -f /usr/local/libexec/dayone-env

cat > /etc/systemd/system/dayone-keeper.service <<UNIT
[Unit]
Description=Day One keeper (HyperEVM testnet)
After=network-online.target
Wants=network-online.target

[Service]
User=dayone
WorkingDirectory=/opt/dayone
EnvironmentFile=/opt/dayone/keeper.env
Environment=NODE_BIN=$NODEDIR/bin/node
ExecStart=/opt/dayone/run.sh
Restart=always
RestartSec=5
MemoryMax=200M
CPUQuota=25%
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/opt/dayone
InaccessiblePaths=-/root -/home
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
