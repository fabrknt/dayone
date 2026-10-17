#!/bin/bash
# Install or upgrade the Day One keeper as its own systemd service on an existing host. Run as
# root with the bundle and the SHA-256 that bundle.sh printed for it, and, on first install or to
# replace it, the key file:
#   sudo bash install.sh BUNDLE.tgz SHA256 [KEYFILE]
#
# Everything it creates is namespaced dayone-keeper and nothing else on the host is touched:
#   user dayone-keeper (no login), /opt/dayone-keeper (root-owned: releases, Node, a marker),
#   /etc/dayone-keeper/key (readable only by dayone-keeper), /etc/systemd/system/dayone-keeper.service
#
# - It refuses to run if any of those exist without its marker, so it never takes over
#   something another project made. The marker is written only after the first install has
#   started a healthy service; a first install that fails removes exactly what it created.
# - An upgrade stages a new release, then switches key, release link and unit. If anything fails
#   from the switch on, or the service does not stay up, all three are put back and the previous
#   service restarted.
# - Installs are serialised with a lock. Holding it, the key is read into a private copy in /run
#   (removed on every exit); the upload is never deleted by this script, so remove it yourself.
# - The bundle is read once into a private copy, which must match the SHA-256 given and is the
#   copy extracted; npm runs with --ignore-scripts.
set -euo pipefail
umask 022
BUNDLE=${1:?bundle}
BUNDLE_SHA256=${2:?sha256 of the bundle, as bundle.sh printed it}
KEYFILE=${3:-}
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
exists() { [ -e "$1" ] || [ -L "$1" ]; } # a dangling symlink counts

# State for cleanup: what this run created (first install) or switched (upgrade).
FIRST=0 CREATED_USER=0 CREATED_BASE=0 CREATED_ETC=0 CREATED_UNIT=0
SWITCHING=0 PREV= REL= STAGE= KEY_REPLACED=0 UNIT_SAVED=0 KEYTMP= BTMP=
rollback() {
  [ -n "$PREV" ] && { ln -sfn "$PREV" "$BASE/current.new"; mv -T "$BASE/current.new" "$BASE/current"; }
  [ $KEY_REPLACED = 1 ] && [ -e "$ETC/key.prev" ] && mv -f "$ETC/key.prev" "$ETC/key"
  [ $UNIT_SAVED = 1 ] && mv -f "$UNIT.prev" "$UNIT"
  [ -n "$REL" ] && [ "$(readlink -f "$BASE/current")" != "$REL" ] && rm -rf "$REL"
  systemctl daemon-reload || true
  systemctl restart $NAME || true
}
cleanup() {
  local rc=$?
  set +e
  [ -n "$STAGE" ] && rm -rf "$STAGE"
  if [ $rc -ne 0 ] && [ $FIRST = 1 ]; then
    if [ $CREATED_UNIT = 1 ]; then systemctl disable --now $NAME >/dev/null 2>&1; rm -f "$UNIT"; systemctl daemon-reload; fi
    [ $CREATED_ETC = 1 ] && rm -rf "$ETC"
    [ $CREATED_BASE = 1 ] && rm -rf "$BASE"
    [ $CREATED_USER = 1 ] && userdel $NAME
    echo "install.sh: first install failed; removed what it created" >&2
  elif [ $rc -ne 0 ] && [ $SWITCHING = 1 ]; then
    rollback
    echo "install.sh: upgrade failed; restored ${PREV:-the previous state}" >&2
  fi
  [ $rc -eq 0 ] && rm -f "$UNIT.prev" "$ETC/key.prev"
  # the private copy of the uploaded key never outlives the run
  [ -n "$KEYTMP" ] && { shred -u "$KEYTMP" 2>/dev/null || rm -f "$KEYTMP"; }
  [ -n "$BTMP" ] && rm -f "$BTMP"
}
trap cleanup EXIT

[ "$(id -u)" = 0 ] || die "run as root"
if [ -n "$KEYFILE" ]; then
  [ -f "$KEYFILE" ] && [ -s "$KEYFILE" ] || die "key file $KEYFILE is empty or missing"
  # never accept the installed key (or an alias of it) as the new one: pass the uploaded copy
  case "$(readlink -f "$KEYFILE")" in "$ETC"/*) KEYFILE=; die "pass an uploaded copy, not the installed key" ;; esac
  if [ -e "$ETC/key" ] && [ "$(stat -c %d:%i "$KEYFILE")" = "$(stat -c %d:%i "$ETC/key")" ]; then
    KEYFILE=; die "pass an uploaded copy, not the installed key"
  fi
fi

exec 9>/run/$NAME.install.lock
flock -n 9 || die "another install is running"

# 1. Only proceed on a clean host or on our own committed install.
if [ -e "$MARKER" ]; then
  [ "$(stat -c %u "$MARKER")" = 0 ] || die "$MARKER is not root-owned"
  # a committed install is complete; anything else is refused rather than half-rolled-back
  # (current a symlink to a release under releases/, key and unit plain files, not symlinks)
  CURT=$(readlink -f "$BASE/current" 2>/dev/null || true)
  [ -L "$BASE/current" ] && [ -d "$CURT" ] && [ "${CURT%/*}" = "$BASE/releases" ] \
    && [ -f "$ETC/key" ] && [ ! -L "$ETC/key" ] && [ -f "$UNIT" ] && [ ! -L "$UNIT" ] \
    || die "the existing install is incomplete or altered (current, key or unit); repair it by hand"
else
  for p in "$BASE" "$ETC" "$UNIT"; do exists "$p" && die "$p exists but was not made by this script"; done
  id "$NAME" >/dev/null 2>&1 && die "user $NAME exists but was not made by this script"
  [ -n "$KEYFILE" ] || die "first install needs the key file"
  FIRST=1
fi
ARCH=$(uname -m); case $ARCH in aarch64) ARCH=arm64 ;; x86_64) ARCH=x64 ;; *) die "unsupported arch $ARCH" ;; esac
# The bundle is read once into a private copy, which is what gets hashed and extracted.
[[ "$BUNDLE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "the SHA-256 must be 64 lowercase hex characters"
BTMP=$(umask 077; mktemp /run/$NAME.bundle.XXXXXX)
cat -- "$BUNDLE" > "$BTMP"
[ "$(sha256sum < "$BTMP" | cut -d' ' -f1)" = "$BUNDLE_SHA256" ] || die "bundle does not match the SHA-256 given"
# Only now, holding the lock and past every refusal, read the key into a 0600 copy in /run. It must
# look like a key, so a path pointing at some other file installs nothing. The upload itself is
# left for the person who uploaded it to remove: a root script never deletes a path it was handed.
if [ -n "$KEYFILE" ]; then
  KEYTMP=$(umask 077; mktemp /run/$NAME.key.XXXXXX)
  head -c 200 -- "$KEYFILE" | tr -d '[:space:]' > "$KEYTMP"
  grep -qxE '(0x)?[0-9a-fA-F]{64}' "$KEYTMP" || die "the key file does not hold a private key (64 hex characters)"
  KEYFILE=$KEYTMP
fi

if [ $FIRST = 1 ]; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /sbin/nologin $NAME; CREATED_USER=1
  install -d -m 755 -o root -g root "$BASE"; CREATED_BASE=1
fi
install -d -m 755 -o root -g root "$BASE/releases"

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
tar -xzf "$BTMP" -C "$STAGE" --no-same-owner
[ -f "$STAGE/keeper/keeper.ts" ] && [ -f "$STAGE/keeper.env" ] && [ -f "$STAGE/out/LaunchPool.sol/LaunchPool.json" ] || die "bundle is incomplete"
# --ignore-scripts: no package code runs as root at install; package-lock pins every tarball's hash
(cd "$STAGE" && HOME=/nonexistent npm_config_cache="$STAGE/.npm" PATH="$NODEDIR/bin:$PATH" npm ci --omit=dev --ignore-scripts --no-audit --no-fund --silent)
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

# 4. Switch key, release link and unit, keeping what was there; any failure from here rolls back.
PREV=$(readlink "$BASE/current" 2>/dev/null || true)
[ $FIRST = 1 ] || SWITCHING=1
if [ ! -d "$ETC" ]; then install -d -m 500 -o $NAME -g $NAME "$ETC"; [ $FIRST = 1 ] && CREATED_ETC=1; fi
if [ -n "$KEYFILE" ]; then
  [ -e "$ETC/key" ] && cp -p "$ETC/key" "$ETC/key.prev"
  install -m 400 -o $NAME -g $NAME "$KEYFILE" "$ETC/key.new"
  mv -f "$ETC/key.new" "$ETC/key"
  KEY_REPLACED=1
fi
ln -sfn "$REL" "$BASE/current.new"
mv -T "$BASE/current.new" "$BASE/current"
if [ -e "$UNIT" ]; then
  cp -p "$UNIT" "$UNIT.prev" || die "could not save the current unit"
  UNIT_SAVED=1
fi
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
[ $FIRST = 1 ] && CREATED_UNIT=1
systemctl daemon-reload
systemctl enable $NAME >/dev/null

# 5. Healthy = active and not restarted for 15 s after the restart. Not healthy -> exit non-zero,
# and cleanup() rolls back (upgrade) or removes everything (first install).
systemctl restart $NAME
sleep 15
if [ "$(systemctl is-active $NAME)" != active ] || [ "$(systemctl show $NAME -p NRestarts --value)" != 0 ]; then
  journalctl -u $NAME -n 10 --no-pager -o cat >&2 || true
  die "the new keeper did not stay up"
fi

# 6. Committed: mark the install ours and prune old releases (the running one is never removed).
touch "$MARKER"
SWITCHING=0
CUR=$(readlink -f "$BASE/current")
ls -1d "$BASE"/releases/2*/ 2>/dev/null | sort | head -n -2 | while read -r old; do
  [ "${old%/}" = "$CUR" ] || rm -rf "$old"
done
systemctl is-active $NAME
journalctl -u $NAME -n 5 --no-pager -o cat
echo "rollback: ln -sfn <older release> $BASE/current && systemctl restart $NAME"
