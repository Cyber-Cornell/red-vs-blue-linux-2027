#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || exit 1
. "$SCRIPT_DIR/../lib/portable.sh"
TCP=${CCDC_TCP_PORTS:-}
UDP=${CCDC_UDP_PORTS:-}
DESTINATIONS=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tcp-ports|--udp-ports|--allow-destinations)
      option=$1; shift; [ "$#" -gt 0 ] || die "$option requires a value"
      case "$option" in --tcp-ports) TCP=$1 ;; --udp-ports) UDP=$1 ;; *) DESTINATIONS=$1 ;; esac ;;
    --help|-h)
      printf 'Usage: %s [--tcp-ports LIST] [--udp-ports LIST] [--allow-destinations FILE]\n' "$0"
      printf '%s\n' 'LIST: reviewed listener ports/ranges separated by commas. Defaults: CCDC_TCP_PORTS/CCDC_UDP_PORTS.'
      printf '%s\n' 'Destination file: one exact numeric IP per line, in displayed form; comments allowed. No DNS or CIDR expansion.'
      printf '%s\n' 'Read-only, 60-second/128-socket cap (96 TCP/UDP plus 32 packet/raw). Exit 2 means incomplete coverage; leads are not verdicts.'
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
for ports in "$TCP" "$UDP"; do
  printf '%s\n' "$ports" | awk -F, '{for(i=1;i<=NF;i++){if($i=="")continue; n=split($i,a,"-"); if(n>2 || a[1]!~/^[0-9]+$/ || a[1]<1 || a[1]>65535)exit 1; if(n==2 && (a[2]!~/^[0-9]+$/ || a[2]<a[1] || a[2]>65535))exit 1}}' || die 'Invalid listener port list'
done
[ -z "$DESTINATIONS" ] || [ -f "$DESTINATIONS" ] || die 'Destination allowlist must be an existing local file'
have_cmd timeout || die 'timeout is required for bounded collection'
if [ "${CCDC_CONNECTION_RUNNING:-0}" != 1 ]; then
  export CCDC_CONNECTION_RUNNING=1
  set -- --tcp-ports "$TCP" --udp-ports "$UDP"
  [ -z "$DESTINATIONS" ] || set -- "$@" --allow-destinations "$DESTINATIONS"
  exec timeout 60 sh "$0" "$@"
fi
umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ccdc-connections.XXXXXX") || die 'Cannot allocate private socket workspace'
trap 'rm -f "$WORK"/*; rmdir "$WORK" 2>/dev/null || true' 0
trap 'exit 1' HUP INT TERM
: >"$WORK/allowed"
if [ -n "$DESTINATIONS" ]; then
  while IFS= read -r destination || [ -n "$destination" ]; do
    destination=$(printf '%s' "$destination" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | tr A-F a-f)
    [ -n "$destination" ] || continue
    case "$destination" in *[!0-9a-f:.]*|*[a-f]*.*) die 'Allowlist accepts exact numeric IP text only, not CIDR or names' ;; esac
    case "$destination" in *:*) ;; *.*.*.*) ;; *) die 'Invalid destination address' ;; esac
    printf '%s\n' "$destination" >>"$WORK/allowed"
  done <"$DESTINATIONS"
fi
PARTIAL=0
SOURCE=ss
if have_cmd ss && (ulimit -f 512; timeout 8 ss -H -O -n -t -u -a -p -e) >"$WORK/raw" 2>"$WORK/errors"; then
  [ "$(wc -l <"$WORK/raw")" -le 96 ] || { PARTIAL=2; printf '%s\n' 'COVERAGE socket line cap reached'; }
  awk 'NR<=96 && ($1=="tcp" || $1=="udp") {pid="unknown"; inode="unknown"; if(match($0,/pid=[0-9]+/))pid=substr($0,RSTART+4,RLENGTH-4); if(match($0,/ino:[0-9]+/))inode=substr($0,RSTART+4,RLENGTH-4); printf "%s\t%s\t%s\t%s\t%s\t%s\n",$1,$2,$5,$6,pid,inode}' "$WORK/raw" >"$WORK/rows"
else
  SOURCE=proc
  PARTIAL=2
  printf '%s\n' 'COVERAGE ss unavailable/failed; proc fallback has no reliable PID ownership correlation'
  : >"$WORK/rows"
  for table in tcp tcp6 udp udp6; do
    [ -r "/proc/net/$table" ] || { printf 'COVERAGE missing /proc/net/%s\n' "$table"; continue; }
    head -n 26 "/proc/net/$table" | awk -v proto="${table%6}" '
      function hex(s, i,n){n=0; s=toupper(s); for(i=1;i<=length(s);i++)n=n*16+index("0123456789ABCDEF",substr(s,i,1))-1; return n}
      function rev(s){return substr(s,7,2) substr(s,5,2) substr(s,3,2) substr(s,1,2)}
      function addr(s, x,i,out){if(length(s)==8)return hex(substr(s,7,2))"."hex(substr(s,5,2))"."hex(substr(s,3,2))"."hex(substr(s,1,2)); x=""; for(i=1;i<=32;i+=8)x=x rev(substr(s,i,8)); out=""; for(i=1;i<=32;i+=4)out=out (i>1?":":"") tolower(substr(x,i,4)); return "["out"]"}
      NR>1 && NR<=25 {split($2,l,":");split($3,r,":"); state=($4=="0A"?"LISTEN":($4=="01"?"ESTAB":($4=="07"?"UNCONN":"OTHER"))); printf "%s\t%s\t%s:%d\t%s:%d\tunknown\t%s\n",proto,state,addr(l[1]),hex(l[2]),addr(r[1]),hex(r[2]),$10}
      NR==26 {print "limit" >"/dev/stderr"}
    ' >>"$WORK/rows" 2>/dev/null
  done
fi
# Reserve socket budget for packet/raw sockets, which ss -tu does not cover.
: >"$WORK/packet-raw"
for table in packet raw raw6; do
  [ -r "/proc/net/$table" ] || { printf 'COVERAGE missing /proc/net/%s\n' "$table"; PARTIAL=2; continue; }
  head -n 34 "/proc/net/$table" | awk -v table="$table" '
    NR>1 && table=="packet" && $3~/^[0-9]+$/ && $4~/^[0-9A-Fa-f]+$/ && $5~/^[0-9]+$/ && $8~/^[0-9]+$/ && $9~/^[0-9]+$/ {
      printf "packet\tuid=%s,type=%s\tiface=%s,ethproto=%s\tnot-applicable\tunknown\t%s\n",$8,$3,$5,$4,$9
    }
    NR>1 && table!="packet" && $2~/^[0-9A-Fa-f:]+$/ && $3~/^[0-9A-Fa-f:]+$/ && $8~/^[0-9]+$/ && $10~/^[0-9]+$/ {
      printf "%s\tuid=%s\t%s\t%s\tunknown\t%s\n",table,$8,$2,$3,$10
    }
  ' >"$WORK/table-$table"
  case "$table" in packet) budget=10 ;; *) budget=11 ;; esac
  if [ "$(wc -l <"$WORK/table-$table")" -gt "$budget" ]; then
    printf 'COVERAGE %s socket cap reached\n' "$table"; PARTIAL=2
  fi
  head -n "$budget" "$WORK/table-$table" >>"$WORK/packet-raw"
done
if [ "$(wc -l <"$WORK/packet-raw")" -gt 32 ]; then
  printf '%s\n' 'COVERAGE packet/raw socket cap reached'; PARTIAL=2
fi
head -n 32 "$WORK/packet-raw" >>"$WORK/rows"
: >"$WORK/socket-owners"
if [ -s "$WORK/packet-raw" ]; then
  printf '%s\n' 'COVERAGE packet/raw owner correlation is partial: 8s, 128 processes, 64 descriptors/process; one observed owner per inode, current network namespace only.'
  PARTIAL=2
  (ulimit -f 256; timeout -s TERM -k 1 8 sh -c '
    processes=0
    for process in /proc/[0-9]*; do
      processes=$((processes+1)); [ "$processes" -le 128 ] || break
      pid=${process##*/}
      find "$process/fd" -maxdepth 1 -type l -print 2>/dev/null | head -n 64 |
      while IFS= read -r descriptor; do
        target=$(readlink "$descriptor" 2>/dev/null) || continue
        case "$target" in socket:\[*\]) inode=${target#socket:[}; inode=${inode%]}; case "$inode" in ""|*[!0-9]*) continue ;; esac; printf "%s\t%s\n" "$inode" "$pid" ;; esac
      done
    done
  ') >"$WORK/socket-owners" 2>/dev/null || true
fi
port_allowed() {
  case "$1" in tcp) _list=$TCP ;; *) _list=$UDP ;; esac
  printf '%s\n' "$_list" | awk -F, -v p="$2" '{for(i=1;i<=NF;i++){n=split($i,a,"-"); if((n==1 && a[1]==p)||(n==2 && p>=a[1] && p<=a[2]))found=1}} END {exit !found}'
}
host_of() { printf '%s' "${1%:*}" | tr -d '[]' | tr A-F a-f; }
loopback() { case "$1" in 127.*|::1|0000:0000:0000:0000:0000:0000:0000:0001) return 0 ;; *) return 1 ;; esac; }
public_candidate() {
  _address=${1#::ffff:}
  printf '%s\n' "$_address" | awk -F. '/:/ {exit !($0~/^[23][0-9a-f]*:/)} NF==4 {a=$1;b=$2; exit !(a>0 && a<224 && a!=10 && a!=127 && !(a==172&&b>=16&&b<=31) && !(a==192&&b==168) && !(a==169&&b==254) && !(a==100&&b>=64&&b<=127))} NF!=4 {exit 1}'
}
safe() { printf '%s' "$1" | tr '[:cntrl:]' '?' | cut -c 1-240; }
SELF_NS=$(readlink /proc/self/ns/net 2>/dev/null || printf unknown)
printf 'CONNECTION REVIEW source=%s reviewed_tcp=%s reviewed_udp=%s\n' "$SOURCE" "${TCP:-none}" "${UDP:-none}"
printf '%s\n' 'Only current network namespace is enumerated. Public peers are outbound candidates, not proof of direction or C2. No active probes or name resolution.'
printf '%s\n' 'Packet/raw rows are review leads, including legitimate capture/diagnostic tools. Raw addresses/protocol IDs stay in kernel hexadecimal form; no payloads are read.'
COUNT=0
while IFS="$(printf '\t')" read -r protocol state local peer pid inode; do
  [ -n "$protocol" ] || continue
  COUNT=$((COUNT + 1))
  local_host=$(host_of "$local")
  peer_host=$(host_of "$peer")
  local_port=${local##*:}
  labels=''
  case "$protocol" in
    packet|raw|raw6)
      labels='PACKET_OR_RAW_REVIEW,'
      owner=$(awk -v inode="$inode" '$1==inode {print $2; exit}' "$WORK/socket-owners")
      [ -z "$owner" ] || pid=$owner ;;
  esac
  case "$state" in LISTEN|UNCONN)
    if ! loopback "$local_host" && ! port_allowed "$protocol" "$local_port"; then labels="${labels}UNREVIEWED_EXTERNAL_LISTENER,"; fi ;;
  esac
  if [ "$state" = ESTAB ] && public_candidate "$peer_host" && ! grep -F -x "$peer_host" "$WORK/allowed" >/dev/null 2>&1; then
    labels="${labels}UNREVIEWED_PUBLIC_PEER,"
    port_allowed "$protocol" "$local_port" || labels="${labels}OUTBOUND_CANDIDATE,"
  fi
  exe=unknown; comm=unknown; hash=unknown
  if [ "$pid" != unknown ] && [ -d "/proc/$pid" ]; then
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null || printf unknown)
    comm=$(head -c 64 "/proc/$pid/comm" 2>/dev/null || printf unknown)
    case "$exe" in *' (deleted)'|/memfd:*) labels="${labels}DELETED_OR_MEMORY_OWNER," ;; esac
    ns=$(readlink "/proc/$pid/ns/net" 2>/dev/null || printf unknown)
    if [ "$ns" = unknown ]; then labels="${labels}UNKNOWN_OWNER_NAMESPACE,"; PARTIAL=2
    elif [ "$ns" != "$SELF_NS" ]; then labels="${labels}OWNER_NAMESPACE_MISMATCH,"; fi
    if [ -f "$WORK/hash-$pid" ]; then hash=$(cat "$WORK/hash-$pid")
    else
      size=$(stat -Lc %s "/proc/$pid/exe" 2>/dev/null || printf 0)
      if [ "$size" -gt 0 ] 2>/dev/null && [ "$size" -le 16777216 ] 2>/dev/null && have_cmd sha256sum; then
        digest=$(timeout 3 sha256sum "/proc/$pid/exe" 2>/dev/null) && hash=${digest%% *}
      fi
      printf '%s\n' "$hash" >"$WORK/hash-$pid"
    fi
  fi
  if [ "$exe" = unknown ]; then labels="${labels}UNKNOWN_OWNER,"; PARTIAL=2; fi
  printf 'SOCKET proto=%s state=%s local=%s peer=%s pid=%s comm=%s exe=%s sha256=%s inode=%s leads=%s evidence=/proc/%s\n' "$protocol" "$state" "$(safe "$local")" "$(safe "$peer")" "$pid" "$(safe "$comm")" "$(safe "$exe")" "$hash" "$inode" "${labels:-none-observed}" "$pid"
done <"$WORK/rows"
printf 'COVERAGE sockets=%s status=%s; absence of leads does not prove connections authorized\n' "$COUNT" "$PARTIAL"
exit "$PARTIAL"
