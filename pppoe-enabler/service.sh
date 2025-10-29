#!/system/bin/sh
# Magisk service.sh — PPPoE root 后台服务（DNS 交给 App 的 VpnService）
# 支持：多网卡优先级、快速切换（含 Wi‑Fi/wlan0，只要上游 AP 透传 PPPoE）
#
# 控制示例：
#   echo start              > /data/local/tmp/pppoe_control
#   echo stop               > /data/local/tmp/pppoe_control
#   echo "switch wlan0"     > /data/local/tmp/pppoe_control   # 立即切到 wlan0 并重拨
#   echo cycle              > /data/local/tmp/pppoe_control   # 在列表中顺序切换
#
# 配置文件：
#   /data/local/tmp/pppoe_iface     # 单个接口名（优先级最高）
#   /data/local/tmp/pppoe_iflist    # 多个接口名，按行或空白分隔，按顺序优先（如: eth0\nusb0\nwlan0）
#   /data/local/tmp/pppoe_user      # 账号
#   /data/local/tmp/pppoe_pass      # 密码
#   /data/local/tmp/pppoe_mtu|mru   # MTU/MRU（数值，范围 576~1492）
#
set -eu
unset LD_PRELOAD LD_LIBRARY_PATH
export LD_PRELOAD= LD_LIBRARY_PATH=

MODDIR="${0%/*}"
MINIROOT="/data/adb/modules/pppoe-enabler/miniroot"
LINKER="/data/local/tmp/ppp_linker"
PPPD="/data/local/tmp/ppp_daemon"
PPPOE_PLUGIN="$MINIROOT/usr/lib/pppd/2.5.1/pppoe.so"

LOG_FILE="/data/local/tmp/pppoe.log"
CONTROL_FILE="/data/local/tmp/pppoe_control"
USER_FILE="/data/local/tmp/pppoe_user"
PASS_FILE="/data/local/tmp/pppoe_pass"
IFACE_FILE="/data/local/tmp/pppoe_iface"
IFLIST_FILE="/data/local/tmp/pppoe_iflist"
PIDFILE="/data/local/tmp/pppd-pppoe0.pid"
LOCKDIR="/data/local/tmp/.pppoe.lock"
PEER_ENV="/data/local/tmp/pppoe_peer.env"
MTU_FILE="/data/local/tmp/pppoe_mtu"
MRU_FILE="/data/local/tmp/pppoe_mru"

DEFAULT_MTU=1492
DEFAULT_MRU=1492
MTU_MIN=576
MTU_MAX=1492
MRU_MIN=576
MRU_MAX=1492

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done

prep_binaries() {
  [ -d "$MINIROOT" ] || { echo "[fatal] MINIROOT missing: $MINIROOT" >>"$LOG_FILE"; exit 1; }
  cp -f "$MINIROOT/lib/ld-musl-aarch64.so.1" "$LINKER"
  cp -f "$MINIROOT/usr/sbin/pppd" "$PPPD"
  cp -f "$PPPOE_PLUGIN" "/data/local/tmp/pppoe.so"
  chmod 0755 "$LINKER" "$PPPD"
  chmod 0644 "/data/local/tmp/pppoe.so"
  chcon -R u:object_r:exec_type:s0 "$MINIROOT" 2>/dev/null || true
  chcon u:object_r:exec_type:s0 "$LINKER" "$PPPD" 2>/dev/null || true
  chcon u:object_r:exec_type:s0 "/data/local/tmp/pppoe.so" 2>/dev/null || true
}

echo "PPPoE Service Initialized at $(date)" >"$LOG_FILE"
echo "Ready for commands." >>"$LOG_FILE"
rm -f "$CONTROL_FILE" || true
exec >>"$LOG_FILE" 2>&1
set -x

read_number_file() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return; }
  tr -d '\r\n\t ' < "$f" | sed 's/[^0-9]//g'
}

validate_range() {
  local v="$1" min="$2" max="$3"
  case "$v" in
    '' ) echo "";;
    *[!0-9]* ) echo "";;
    * ) if [ "$v" -lt "$min" ] || [ "$v" -gt "$max" ]; then echo ""; else echo "$v"; fi ;;
  esac
}

resolve_mtu_mru() {
  local mtu_raw mru_raw mtu mru
  mtu_raw="$(read_number_file "$MTU_FILE")"
  mru_raw="$(read_number_file "$MRU_FILE")"
  mtu="$(validate_range "${mtu_raw:-}" "$MTU_MIN" "$MTU_MAX")"
  mru="$(validate_range "${mru_raw:-}" "$MRU_MIN" "$MRU_MAX")"
  [ -z "$mtu" ] && mtu="$DEFAULT_MTU" && echo "[warn] invalid/absent MTU, fallback $mtu"
  [ -z "$mru" ] && mru="$DEFAULT_MRU" && echo "[warn] invalid/absent MRU, fallback $mru"
  if [ "$mru" -gt "$mtu" ]; then echo "[warn] MRU($mru) > MTU($mtu), clamp MRU to $mtu"; mru="$mtu"; fi
  echo "$mtu $mru"
}

# 返回所有候选接口（去重）：
# 1) pppoe_iface 指定的单个接口（若存在）
# 2) pppoe_iflist 中的接口们（若存在）
# 3) 自动发现的有线/USB/Wi‑Fi（type==1）
list_ifaces() {
  local seen="/data/local/tmp/.pppoe-seen.$$"
  : > "$seen"
  add() { local x="$1"; [ -n "$x" ] || return; [ -d "/sys/class/net/$x" ] || return; grep -qxF "$x" "$seen" || { echo "$x"; echo "$x" >>"$seen"; }; }

  if [ -f "$IFACE_FILE" ]; then add "$(tr -d '\r\n ' < "$IFACE_FILE")"; fi

  if [ -f "$IFLIST_FILE" ]; then
    tr ' \t' '\n' < "$IFLIST_FILE" | sed '/^$/d' | while read -r i; do add "$i"; done
  fi

  for n in /sys/class/net/*; do
    [ "$(cat "$n/type" 2>/dev/null || echo)" = "1" ] || continue
    bn="$(basename "$n")"
    echo "$bn" | grep -Eq '^(eth|en|usb|rndis|enx|wlan)' || continue
    add "$bn"
  done

  rm -f "$seen"
}
choose_iface() {
  for i in $(list_ifaces); do
    log "[probe] candidate: $i"
    [ "$i" = "lo" ] && continue
    [ -d "/sys/class/net/$i" ] || continue
    if [ -d "/sys/class/net/$i/wireless" ]; then
      log "[note] $i is Wi-Fi; PPPoE 取决于 AP 是否透传。"
    fi
    ip link set dev "$i" up 2>/dev/null || true
    for t in 0 1 2 3 4 5; do
      state="$(cat /sys/class/net/$i/operstate 2>/dev/null || echo unknown)"
      [ "$state" = "up" ] && break
      sleep 1
    done
    printf '%s\n' "$i"   # ← 只输出接口名
    return 0
  done
  printf '%s\n' "eth0"
}


make_hooks() {
  local HOOKDIR="$MODDIR/hooks"
  mkdir -p "$HOOKDIR"
  local IP_UP="$HOOKDIR/ip-up.sh"
  local IP_DOWN="$HOOKDIR/ip-down.sh"

  cat >"$IP_UP" <<'EOF'
#!/system/bin/sh
set -e
set +u
IF="$1"; IPLOCAL="$4"; IPREMOTE="$5"; DNS1="$6"; DNS2="$7"

{
  echo "IF=$IF"
  echo "IPLOCAL=$IPLOCAL"
  echo "IPREMOTE=$IPREMOTE"
  [ -n "$DNS1" ] && echo "DNS1=$DNS1" || true
  [ -n "$DNS2" ] && echo "DNS2=$DNS2" || true
} >/data/local/tmp/pppoe_peer.env.tmp 2>/dev/null || true
mv -f /data/local/tmp/pppoe_peer.env.tmp /data/local/tmp/pppoe_peer.env 2>/dev/null || true
chmod 0644 /data/local/tmp/pppoe_peer.env 2>/dev/null || true

ip route | awk '/^default/ && !/ppp0/ {print}' | while read -r l; do ip route del $l 2>/dev/null; done
ip route replace default dev "$IF" metric 0 2>/dev/null || ip route add default dev "$IF" metric 0 2>/dev/null
ip rule add pref 10000 lookup main 2>/dev/null || true
ip route flush cache

set -u
exit 0
EOF

  cat >"$IP_DOWN" <<'EOF'
#!/system/bin/sh
set -e
set +u
IF="$1"
ip route del default dev "$IF" 2>/dev/null || true
ip rule del pref 10000 lookup main 2>/dev/null || true
ip route flush cache
echo "IF=" >/data/local/tmp/pppoe_peer.env.tmp 2>/dev/null || true
mv -f /data/local/tmp/pppoe_peer.env.tmp /data/local/tmp/pppoe_peer.env 2>/dev/null || true
chmod 0644 /data/local/tmp/pppoe_peer.env 2>/dev/null || true
set -u
exit 0
EOF

  chmod 0755 "$IP_UP" "$IP_DOWN"
  echo "$IP_UP" "$IP_DOWN"
}

start_pppoe_with_iface() {
  local IFACE="$1"
  echo "[DEBUG start_iface] Received IFACE='$IFACE'" # <-- 新日志 1
  prep_binaries

  USERNAME="$(cat "$USER_FILE" 2>/dev/null || true)"
  PASSWORD="$(cat "$PASS_FILE" 2>/dev/null || true)"
  MTU_MRU="$(resolve_mtu_mru)"
  MTU="$(echo "$MTU_MRU" | awk '{print $1}')"
  MRU="$(echo "$MTU_MRU" | awk '{print $2}')"
  echo "[DEBUG start_iface] Checking existence of /sys/class/net/$IFACE" # <-- 新日志 2
  if [ ! -d "/sys/class/net/$IFACE" ]; then
    echo "[DEBUG start_iface] Directory check FAILED for '$IFACE'" # <-- 新日志 3
    echo "[error] iface not found: $IFACE"
    return 1
  fi
  echo "[DEBUG start_iface] Directory check PASSED for '$IFACE'" # <-- 新日志 4
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null; then
      rmdir "$LOCKDIR" 2>/dev/null || true
      mkdir "$LOCKDIR" 2>/dev/null || { echo "Start skipped: lock busy and cannot recover."; return 1; }
    else
      echo "Start skipped: already running."
      return 0
    fi
  fi

  if [ -f "$PIDFILE" ]; then
    OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
      echo "pppd already running (pid=$OLD), skip."
      rmdir "$LOCKDIR" 2>/dev/null || true
      return 0
    fi
    rm -f "$PIDFILE"
  fi

  echo "Attempting to start PPPoE connection on $IFACE ..."
  echo "Using MTU/MRU  : $MTU/$MRU"

  killall ppp_daemon pppd 2>/dev/null || true
  ip link set dev "$IFACE" up 2>/dev/null || true

  HOOKS="$(make_hooks)"
  IP_UP="$(echo "$HOOKS" | awk '{print $1}')"
  IP_DOWN="$(echo "$HOOKS" | awk '{print $2}')"

  OPTFILE="/data/local/tmp/ppp.options"
  cat >"$OPTFILE" <<EOF
plugin $PPPOE_PLUGIN
nic-$IFACE

linkname pppoe0
ifname ppp0
unit 0
name $USERNAME
user $USERNAME
password $PASSWORD

noauth
defaultroute
replacedefaultroute
usepeerdns

mtu $MTU
mru $MRU

lcp-echo-interval 10
lcp-echo-failure 3

pppoe-verbose 2
debug

ip-up-script $IP_UP
ip-down-script $IP_DOWN
logfile $LOG_FILE

persist
maxfail 0
holdoff 5
EOF
  chmod 0600 "$OPTFILE"

  : > "$PEER_ENV" 2>/dev/null || true
  chmod 0644 "$PEER_ENV" 2>/dev/null || true

  /system/bin/env -i \
    PATH=/system/bin:/system/xbin:/vendor/bin \
    HOME=/data/local/tmp TMPDIR=/data/local/tmp \
    LD_PRELOAD= LD_LIBRARY_PATH= \
    "$LINKER" --library-path "$MINIROOT/lib:$MINIROOT/usr/lib" \
    "$PPPD" file "$OPTFILE" &

  local RC=$?; local PID=$!
  echo "[exec] fork rc=$RC pid=$PID"
  rmdir "$LOCKDIR" 2>/dev/null || true
  [ $RC -ne 0 ] && { echo "[error] pppd exec failed (rc=$RC)"; return 1; }
  return 0
}

start_pppoe() {
  # 优先使用 choose_iface 选出的接口
  local picked
  picked="$(choose_iface)"
  echo "[choose] $picked"
  start_pppoe_with_iface "$picked" || return 1
}

stop_pppoe() {
  echo "[DEBUG] Entering stop_pppoe" >> "$LOG_FILE" 2>&1 # <--- 添加
  set +e
  echo "[DEBUG] Step 1: Checking PID file" >> "$LOG_FILE" 2>&1 # <--- 添加
  if [ -f "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$PID" ] && kill -TERM "$PID" 2>/dev/null
  fi
  echo "[DEBUG] Step 2: Running killall/pkill TERM" >> "$LOG_FILE" 2>&1 # <--- 添加
  killall -TERM ppp_daemon pppd 2>/dev/null
  pkill -f "/data/local/tmp/ppp_daemon" 2>/dev/null
  pkill -f "plugin .*pppoe.so" 2>/dev/null
  echo "[DEBUG] Step 3: Entering wait loop" >> "$LOG_FILE" 2>&1 # <--- 添加

  for i in 1 2 3; do
    sleep 1
    pgrep -f "/data/local/tmp/ppp_daemon|pppd" >/dev/null 2>&1 || break
  done
  echo "[DEBUG] Step 4: Checking pgrep before KILL" >> "$LOG_FILE" 2>&1 # <--- 添加
  pgrep -f "/data/local/tmp/pppoe_daemon|pppd" >/dev/null 2>&1 && \
    killall -KILL ppp_daemon pppd 2>/dev/null && echo "[DEBUG] Step 5: Running killall KILL" >> "$LOG_FILE" 2>&1 && killall -KILL ... # <--- 添加

  echo "[DEBUG] Step 6: Running ip cleanup" >> "$LOG_FILE" 2>&1 # <--- 添加
  ip link del ppp0 2>/dev/null
  ip route del default dev ppp0 2>/dev/null
  ip rule  del pref 10000 lookup main 2>/dev/null
  ip route flush cache
  echo "[DEBUG] Step 7: Running file cleanup" >> "$LOG_FILE" 2>&1 # <--- 添加
  rm -f "$PIDFILE"
  rm -rf "$LOCKDIR"
  echo "IF=" > "$PEER_ENV" 2>/dev/null || true
  chmod 0644 "$PEER_ENV" 2>/dev/null || true
  echo "[DEBUG] Step 8: Logging Stop command sent" >> "$LOG_FILE" 2>&1 # <--- 添加
  echo "Stop command sent."
  echo "[DEBUG] Exiting stop_pppoe successfully" >> "$LOG_FILE" 2>&1 # <--- 添加
  set -e
}

cycle_iface() {
  # 根据 list_ifaces 顺序，将第一个接口移动到末尾，并写回 pppoe_iface 作为当前选中
  local list new_first rest
  list="$(list_ifaces | tr '\n' ' ')"
  [ -z "$list" ] && { echo "[cycle] no iface candidates"; return; }
  new_first="$(echo "$list" | awk '{print $2}')"
  [ -z "$new_first" ] && new_first="$(echo "$list" | awk '{print $1}')"
  echo "$new_first" > "$IFACE_FILE"
  echo "[cycle] switch to $new_first"
}

main_loop() {
  while :; do
    if [ -f "$CONTROL_FILE" ]; then
      CMD="$(cat "$CONTROL_FILE" 2>/dev/null || echo)"
      rm -f "$CONTROL_FILE" || true
      case "$CMD" in
        start) start_pppoe || true ;;
        stop)  stop_pppoe  || true ;;
        cycle) stop_pppoe || true; cycle_iface; start_pppoe || true ;;
        switch\ *)
          tgt="$(echo "$CMD" | awk '{print $2}')"
          if [ -n "$tgt" ]; then
            stop_pppoe
            echo "$tgt" > "$IFACE_FILE"
            echo "[switch] to $tgt"
            start_pppoe
          else
            echo "[switch] no target"
          fi
          ;;
        *) echo "Unknown command: $CMD" ;;
      esac
    fi
    sleep 1
  done
}

main_loop
