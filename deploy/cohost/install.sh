#!/bin/bash
# Install or upgrade the Day One keeper as its own systemd service on an existing host. Run as
# root with the bundle (from bundle.sh) and, on first install or to replace it, the key file:
#   sudo bash install.sh BUNDLE.tgz [KEYFILE]
#
# Everything it creates is namespaced dayone-keeper and nothing else on the host is touched:
#   user dayone-keeper (no login), /opt/dayone-keeper (root-owned: releases, Node, a marker),
#   /etc/dayone-keeper/key (readable only by dayone-keeper), /etc/systemd/system/dayone-keeper.service
#
# - It refuses to run if any of those exist without its marker, so it never takes over
#   something another project made. The marker is written only after the first install has
#   started a healthy service; a first install that fails removes everything it created.
# - An upgrade stages a new release, switches to it, and checks the service stays up. If it
#   does not, the previous release and key are put back and the old service restarted.
# - Installs are serialised with a lock.
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

exec 9>/run/$NAME.install.lock
flock -n 9 || die "another install is running"

# 1. Only proceed on a clean host or on our own committed install.
FIRST=0
if [ -e "$MARKER" ]; then
  [ "$(stat -c %u "$MARKER")" = 0 ] || die "$MARKER is not root-owned"
  [ -e "$ETC/key" ] || [ -n "$KEYFILE" ] || die "no key installed; pass the key file"
else
  for p in "$BASE" "$ETC" "$UNIT"; do [ -e "$p" ] && die "$p exists but was not made by this script"; done
  id "$NAME" >/dev/null 2>&1 && die "user $NAME exists but was not made by this script"
  [ -n "$KEYFILE" ] || die "first install needs the key file"
  FIRST=1
fi
[ -z "$KEYFILE" ] || [ -s "$KEYFILE" ] || die "key file $KEYFILE is empty or missing"
ARCH=$(uname -m); case $ARCH in aarch64) ARCH=arm64 ;; x86_64) ARCH=x64 ;; *) die "unsupported arch $ARCH" ;; esac

# On any failure of a first install, remove everything it created; the host is as before.
STAGE=
cleanup() {
  local rc=$?
  [ -n "$STAGE" ] && rm -rf "$STAGE"
  # the uploaded key never stays where it was uploaded, whatever happened (rerun with a new copy)
  [ -n "$KEYFILE" ] && { shred -u "$KEYFILE" 2>/dev/null || rm -f "$KEYFILE"; }
  if [ $rc -ne 0 ] && [ $FIRST = 1 ]; then
    systemctl disable --now $NAME >/dev/null 2>&1 || true
    rm -f "$UNIT"; systemctl daemon-reload || true
    rm -rf "$BASE" "$ETC"
    id $NAME >/dev/null 2>&1 && userdel $NAME || true
    echo "install.sh: first install failed; removed what it created" >&2
  fi
}
trap cleanup EXIT

umask 022
install -d -m 755 -o root -g root "$BASE" "$BASE/releases"
[ $FIRST = 0 ] || useradd --system --no-create-home --home-dir /nonexistent --shell /sbin/nologin $NAME

# 2. Our own Node, root-owned, checksum verified.
NODEDIR=$BASE/node-$NODE-linux-$ARCH
if [ ! -x "$NODEDIR/bin/node" ]; then
  T=$(mktemp -d)
  curl -fsSL -o "$T/node.tgz" "https://nodejs.org/dist/$NODE/node-$NODE-linux-$ARCH.tar.gz"
  echo "${NODE_SHA256[$ARCH]}  $T/node.tgz" | sha256sum -c --quiet - || { rm -rf "$T"; die "Node checksum mismatch"; }
  tar -xzf "$T/node.tgz" -C "$T"
  chown -R root:root "$T/node-$NODE-linux-$ARCH"
  mv -T "$T/node-$NODE-linux-$ARCH" "$NODEDIR"
  rm -rf "$T"
fi

# 3. Stage the new release under a unique name; nothing live changes until it is complete.
STAGE=$(mktemp -d "$BASE/releases/.stage.XXXXXX")
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
chown -R root:root "$STAGE"
chmod -R u=rwX,go=rX "$STAGE" # mktemp makes the top dir 0700
chmod 755 "$STAGE/run.sh"
REL=$BASE/releases/$(date -u +%Y%m%dT%H%M%SZ)-${STAGE##*.stage.}
mv -T "$STAGE" "$REL"
STAGE=

# 4. Switch: key (keeping the old one), release link, unit. Remember what to restore.
PREV=$(readlink "$BASE/current" 2>/dev/null || true)
install -d -m 500 -o $NAME -g $NAME "$ETC"
if [ -n "$KEYFILE" ]; then
  [ -e "$ETC/key" ] && cp -p "$ETC/key" "$ETC/key.prev"
  install -m 400 -o $NAME -g $NAME "$KEYFILE" "$ETC/key.new"
  mv -f "$ETC/key.new" "$ETC/key"
fi
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
systemctl enable $NAME >/dev/null

# 5. Healthy = active and not restarted for 15 s after the restart.
healthy() {
  systemctl restart $NAME || return 1
  sleep 15
  [ "$(systemctl is-active $NAME)" = active ] && [ "$(systemctl show $NAME -p NRestarts --value)" = 0 ]
}
if ! healthy; then
  journalctl -u $NAME -n 10 --no-pager -o cat >&2 || true
  if [ $FIRST = 1 ]; then die "the new keeper did not stay up"; fi
  if [ -n "$PREV" ]; then
    ln -sfn "$PREV" "$BASE/current.new"; mv -T "$BASE/current.new" "$BASE/current"
  fi
  [ -n "$KEYFILE" ] && [ -e "$ETC/key.prev" ] && mv -f "$ETC/key.prev" "$ETC/key"
  rm -rf "$REL"
  systemctl restart $NAME || true
  die "the new keeper did not stay up; rolled back to ${PREV:-nothing}"
fi

# 6. Committed: mark the install ours, drop the uploaded and previous keys, prune old releases.
touch "$MARKER"
rm -f "$ETC/key.prev"
CUR=$(readlink -f "$BASE/current")
ls -1d "$BASE"/releases/2*/ 2>/dev/null | sort | head -n -2 | while read -r old; do
  [ "${old%/}" = "$CUR" ] || rm -rf "$old"
done
systemctl is-active $NAME
journalctl -u $NAME -n 5 --no-pager -o cat
echo "rollback: ln -sfn <older release> $BASE/current && systemctl restart $NAME"
