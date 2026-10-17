#!/bin/bash
# install.sh scenarios, run inside a throwaway Amazon Linux 2023 container with systemd (never on a
# real host): needs /root/install.sh, /root/dayone-keeper.tgz, /root/bad-runtime.tgz (a bundle whose
# keeper.ts throws) and /root/good.key (a testnet key). See docs/testnet.md.
I=/root/install.sh; G=/root/dayone-keeper.tgz; B=/root/bad-runtime.tgz
state() { echo "  user:$(id -u dayone-keeper 2>/dev/null || echo none) base:$(ls -A /opt/dayone-keeper 2>/dev/null | tr '\n' ' ') etc:$(ls /etc/dayone-keeper 2>/dev/null | tr '\n' ' ') unit:$(test -e /etc/systemd/system/dayone-keeper.service && echo yes || echo no) active:$(systemctl is-active dayone-keeper) root:$(ls /root | tr '\n' ' ') run:$(ls /run | grep dayone | tr '\n' ' ')"; }

echo "== dangling unit symlink is a collision"
ln -s /nonexistent /etc/systemd/system/dayone-keeper.service
echo x > /root/k; bash $I $G /root/k 2>&1 | tail -1
unlink /etc/systemd/system/dayone-keeper.service; state

echo "== bad key, first install"
echo nothex > /root/k; bash $I $G /root/k 2>&1 | tail -1; state

echo "== good first install"
cp /root/good.key /root/k; bash $I $G /root/k 2>&1 | grep -E '^active|install.sh'; state

echo "== the live key (or an alias) as KEYFILE is refused and kept"
bash $I $G /etc/dayone-keeper/key 2>&1 | tail -1
ln -s /etc/dayone-keeper/key /root/alias; bash $I $G /root/alias 2>&1 | tail -1; unlink /root/alias
ls -l /etc/dayone-keeper/

echo "== daemon-reload fails mid-upgrade with a new key"
K=$(sha256sum /etc/dayone-keeper/key); P=$(readlink /opt/dayone-keeper/current)
mv /usr/bin/systemctl /usr/bin/systemctl.real
cat > /usr/bin/systemctl <<'EOF'
#!/bin/bash
if [ "$1" = daemon-reload ] && [ ! -e /root/once ]; then touch /root/once; exit 1; fi
exec /usr/bin/systemctl.real "$@"
EOF
chmod +x /usr/bin/systemctl
cp /root/good.key /root/k2; bash $I $G /root/k2 2>&1 | tail -1
mv -f /usr/bin/systemctl.real /usr/bin/systemctl
[ "$(readlink /opt/dayone-keeper/current)" = "$P" ] && echo "  link restored"
[ "$(sha256sum /etc/dayone-keeper/key)" = "$K" ] && echo "  key restored"
echo "  leftover .prev files: $(ls /etc/dayone-keeper /etc/systemd/system | grep -c prev)"
sleep 6; echo "  active: $(systemctl is-active dayone-keeper)"; echo "  releases: $(ls /opt/dayone-keeper/releases | tr '\n' ' ')"

echo "== a release that fails at start rolls back"
bash $I $B 2>&1 | tail -1; sleep 6; echo "  active: $(systemctl is-active dayone-keeper)"; echo "  releases: $(ls /opt/dayone-keeper/releases | tr '\n' ' ')"

echo "== lock contention leaves the upload untouched"
cp /root/good.key /root/k3
( exec 9>/run/dayone-keeper.install.lock; flock 9; sleep 5 ) & sleep 1
bash $I $G /root/k3 2>&1 | tail -1; ls /root/k3 >/dev/null 2>&1 && echo "  upload kept"; wait; unlink /root/k3

echo "== an incomplete committed install is refused"
mv /opt/dayone-keeper/current /opt/dayone-keeper/current.hidden
bash $I $G 2>&1 | tail -1
mv /opt/dayone-keeper/current.hidden /opt/dayone-keeper/current

echo "== current as a plain directory is refused"
L=$(readlink /opt/dayone-keeper/current); unlink /opt/dayone-keeper/current; cp -a "$L" /opt/dayone-keeper/current
bash $I $G 2>&1 | tail -1
mv /opt/dayone-keeper/current /opt/dayone-keeper/current.plain; ln -s "$L" /opt/dayone-keeper/current

echo "== unit as a symlink is refused"
mv /etc/systemd/system/dayone-keeper.service /root/unit.real; ln -s /root/unit.real /etc/systemd/system/dayone-keeper.service
bash $I $G 2>&1 | tail -1
unlink /etc/systemd/system/dayone-keeper.service; mv /root/unit.real /etc/systemd/system/dayone-keeper.service

echo "== key upgrade succeeds, upload and private copy gone"
cp /root/good.key /root/k4; bash $I $G /root/k4 2>&1 | grep -E '^active|install.sh'
ls /root/k4 >/dev/null 2>&1 || echo "  upload removed"; echo "  run files: $(ls /run | grep dayone | tr '\n' ' ')"

echo "== lock file mode"; stat -c '%a %n' /run/dayone-keeper.install.lock
state
