#!/bin/bash
# Install or upgrade the Day One keeper as its own systemd service on an existing host. Run as
# root with the bundle (from bundle.sh) and, on first install or to replace it, the key file:
#   sudo bash install.sh BUNDLE.tgz [KEYFILE]
#
# Everything it creates is namespaced dayone-keeper and nothing else on the host is touched:
#   user dayone-keeper (no login), /opt/dayone-keeper (root-owned: releases, Node, a marker),
#   /etc/dayone-keeper/key (readable only by dayone-keeper), /etc/systemd/system/dayone-keeper.service
# It refuses to run if any of those exist without its marker, so it never takes over something
# another project made. An upgrade stages a new release and switches to it only once it is
# complete; a failed upgrade leaves the running release and its files as they were.
set -euo pipefail
BUNDLE=${1:?bundle}
KEYFILE=${2:-}
NAME=dayone-keeper
BASE=/opt/$NAME
ETC=/etc/$NAME
UNIT=/etc/systemd/system/$NAME.service
MARKER=$BASE/.installed-by-dayone
NODE=v24.11.1
declare -A NODE_SHA256=( # from https://nodejs.org/dist/v24.11.1/SHASUMS256.txt
  [arm64]=0dc93ec5c798b0d347f068db6d205d03dea9a71765e6a53922b682b91265d71f
  [x64]=58a5ff5cc8f2200e458bea22e329d5c1994aa1b111d499ca46ec2411d58239ca
)
die() { echo "install.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

# 1. Only proceed on a clean host or on our own earlier install.
if [ -e "$MARKER" ]; then
  [ "$(stat -c %u "$MARKER")" = 0 ] || die "$MARKER is not root-owned"
else
  for p in "$BASE" "$ETC" "$UNIT"; do [ -e "$p" ] && die "$p exists but was not made by this script"; done
  id "$NAME" >/dev/null 2>&1 && die "user $NAME exists but was not made by this script"
  [ -n "$KEYFILE" ] || die "first install needs the key file"
fi
[ -z "$KEYFILE" ] || [ -s "$KEYFILE" ] || die "key file $KEYFILE is empty or missing"

ARCH=$(uname -m); case $ARCH in aarch64) ARCH=arm64 ;; x86_64) ARCH=x64 ;; *) die "unsupported arch $ARCH" ;; esac
umask 022
install -d -m 755 -o root -g root "$BASE" "$BASE/releases"
[ -e "$MARKER" ] || { id "$NAME" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /sbin/nologin "$NAME"; touch "$MARKER"; }

# 2. Our own Node, root-owned, checksum verified.
NODEDIR=$BASE/node-$NODE-linux-$ARCH
if [ ! -x "$NODEDIR/bin/node" ]; then
  T=$(mktemp -d)
  curl -fsSL -o "$T/node.tgz" "https://nodejs.org/dist/$NODE/node-$NODE-linux-$ARCH.tar.gz"
  echo "${NODE_SHA256[$ARCH]}  $T/node.tgz" | sha256sum -c --quiet - || { rm -rf "$T"; die "Node checksum mismatch"; }
  tar -xzf "$T/node.tgz" -C "$T"
  chown -R root:root "$T/node-$NODE-linux-$ARCH"
  mv "$T/node-$NODE-linux-$ARCH" "$NODEDIR"
  rm -rf "$T"
fi

# 3. Stage the new release; nothing live changes until it is complete.
REL=$BASE/releases/$(date -u +%Y%m%dT%H%M%SZ)
STAGE=$REL.partial
rm -rf "$STAGE"
install -d -m 755 -o root -g root "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$BUNDLE" -C "$STAGE" --no-same-owner
[ -f "$STAGE/keeper/keeper.ts" ] && [ -f "$STAGE/keeper.env" ] && [ -f "$STAGE/out/LaunchPool.sol/LaunchPool.json" ] || die "bundle is incomplete"
(cd "$STAGE" && HOME=/nonexistent npm_config_cache="$STAGE/.npm" PATH="$NODEDIR/bin:$PATH" npm ci --omit=dev --no-audit --no-fund --silent)
rm -rf "$STAGE/.npm"
cat > "$STAGE/run.sh" <<SH
#!/bin/bash
# The key is readable only by $NAME; it goes into the keeper's environment and nowhere else.
set -euo pipefail
KEY=\$(tr -d '[:space:]' < $ETC/key)
case "\$KEY" in 0x*) ;; *) KEY=0x\$KEY ;; esac
export PRIVATE_KEY=\$KEY
exec $NODEDIR/bin/node --disable-warning=ExperimentalWarning keeper/keeper.ts
SH
chmod 755 "$STAGE/run.sh"
chown -R root:root "$STAGE"
chmod -R u=rwX,go=rX "$STAGE" # the bundle's top dir comes from mktemp (0700)
mv "$STAGE" "$REL"
trap - EXIT

# 4. The key: replaced atomically, the uploaded copy removed.
if [ -n "$KEYFILE" ]; then
  install -d -m 500 -o "$NAME" -g "$NAME" "$ETC"
  install -m 400 -o "$NAME" -g "$NAME" "$KEYFILE" "$ETC/key.new"
  mv -f "$ETC/key.new" "$ETC/key"
  shred -u "$KEYFILE" 2>/dev/null || rm -f "$KEYFILE"
fi

# 5. Switch to the new release atomically, then (re)start.
ln -sfn "$REL" "$BASE/current.new"
mv -T "$BASE/current.new" "$BASE/current"
cat > "$UNIT.new" <<UNIT
[Unit]
Description=Day One keeper (HyperEVM testnet)
After=network-online.target
Wants=network-online.target

[Service]
User=$NAME
Group=$NAME
WorkingDirectory=$BASE/current
EnvironmentFile=$BASE/current/keeper.env
ExecStart=$BASE/current/run.sh
Restart=always
RestartSec=5
MemoryMax=200M
CPUQuota=25%
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
UMask=077

[Install]
WantedBy=multi-user.target
UNIT
mv -f "$UNIT.new" "$UNIT"
systemctl daemon-reload
systemctl enable "$NAME" >/dev/null
systemctl restart "$NAME"

# Keep the two newest releases (the running one and the one before it, for rollback).
ls -1d "$BASE"/releases/*/ 2>/dev/null | sort | head -n -2 | while read -r old; do
  [ "$(readlink -f "$BASE/current")/" = "$old" ] || rm -rf "$old"
done

sleep 8
systemctl is-active "$NAME"
journalctl -u "$NAME" -n 5 --no-pager -o cat
echo "rollback: ln -sfn <older release> $BASE/current && systemctl restart $NAME"
