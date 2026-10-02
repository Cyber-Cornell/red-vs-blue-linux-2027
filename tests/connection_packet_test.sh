#!/bin/sh
set -eu
[ "${CCDC_RESIDUAL_TEST:-}" = 1 ] || exit 2
repo=${1:-/repo}
evidence=${2:-/evidence}
work=$(mktemp -d /tmp/packet-test.XXXXXX)
mkdir "$work/bin"
export PACKET_FIXTURE=$work
cat >"$work/bin/head" <<'EOF'
#!/bin/sh
last=
for arg do last=$arg; done
case "$last" in
  /proc/net/packet|/proc/net/raw|/proc/net/raw6) name=${last##*/}; /bin/busybox head -n 34 "$PACKET_FIXTURE/$name" ;;
  *) /bin/busybox head "$@" ;;
esac
EOF
cat >"$work/bin/ss" <<'EOF'
#!/bin/sh
if [ -f "$PACKET_FIXTURE/many" ]; then
  i=1
  while [ "$i" -le 140 ]; do
    printf 'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((fixture,pid=1,fd=9)) ino:1234\n'
    i=$((i+1))
  done
fi
EOF
cat >"$work/bin/find" <<'EOF'
#!/bin/sh
case "$1" in
  /proc/1/fd) printf '/proc/1/fd/999\n' ;;
  /proc/*/fd) : ;;
  *) /bin/busybox find "$@" ;;
esac
EOF
cat >"$work/bin/readlink" <<'EOF'
#!/bin/sh
case "$1" in /proc/1/fd/999) printf 'socket:[4242]\n' ;; *) /bin/busybox readlink "$@" ;; esac
EOF
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
printf 'sk RefCnt Type Proto Iface R Rmem User Inode\n0 1 3 0003 2 1 0 0 4242\n' >"$work/packet"
printf 'sl local_address rem_address st tx_queue rx_queue tr tm_when retrnsmt uid timeout inode\n0: 00000000:0001 00000000:0000 07 00000000:00000000 00:00000000 00000000 0 0 4243\n' >"$work/raw"
printf 'sl local_address rem_address st tx_queue rx_queue tr tm_when retrnsmt uid timeout inode\n0: 00000000000000000000000000000000:003A 00000000000000000000000000000000:0000 07 00000000:00000000 00:00000000 00000000 0 0 4244\n' >"$work/raw6"
sh -n "$repo/shell/tools/connection_hunt.sh"
status=0
sh "$repo/shell/tools/connection_hunt.sh" >"$work/packet-result" || status=$?
[ "$status" = 2 ]
grep -q 'SOCKET proto=packet .*pid=1 .*inode=4242 .*PACKET_OR_RAW_REVIEW' "$work/packet-result"
grep -q 'SOCKET proto=raw .*inode=4243 .*PACKET_OR_RAW_REVIEW' "$work/packet-result"
grep -q 'SOCKET proto=raw6 .*inode=4244 .*PACKET_OR_RAW_REVIEW' "$work/packet-result"
grep -q 'sockets=3 status=2' "$work/packet-result"
printf 'PASS packet/raw/raw6 metadata, packet inode-to-PID correlation, partial status 2\n'
touch "$work/many"
for table in packet raw raw6; do
  row=$(/bin/busybox tail -n 1 "$work/$table")
  i=1
  while [ "$i" -le 40 ]; do printf '%s\n' "$row" >>"$work/$table"; i=$((i+1)); done
done
status=0
sh "$repo/shell/tools/connection_hunt.sh" >"$work/cap-result" || status=$?
[ "$status" = 2 ]
[ "$(grep -c '^SOCKET ' "$work/cap-result")" -eq 128 ]
[ "$(grep -c '^SOCKET proto=packet ' "$work/cap-result")" -eq 10 ]
[ "$(grep -c '^SOCKET proto=raw ' "$work/cap-result")" -eq 11 ]
[ "$(grep -c '^SOCKET proto=raw6 ' "$work/cap-result")" -eq 11 ]
grep -q 'COVERAGE packet socket cap reached' "$work/cap-result"
printf 'PASS combined 128-socket cap: 96 TCP/UDP, 10 packet, 11 raw, 11 raw6\n'
mkdir -p "$evidence/packet-fixtures"
cp -R "$work/." "$evidence/packet-fixtures/"
