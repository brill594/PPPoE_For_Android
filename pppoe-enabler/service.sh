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
umask 077
unset LD_PRELOAD LD_LIBRARY_PATH
export LD_PRELOAD= LD_LIBRARY_PATH=

MODDIR="${0%/*}"
MINIROOT="$MODDIR/miniroot"
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
  [ -d "$MINIROOT" ] || { log ERROR "event=binaries_missing"; return 1; }
  cp -f "$MINIROOT/lib/ld-musl-aarch64.so.1" "$LINKER" || return 1
  cp -f "$MINIROOT/usr/sbin/pppd" "$PPPD" || return 1
  cp -f "$PPPOE_PLUGIN" "/data/local/tmp/pppoe.so" || return 1
  chmod 0755 "$LINKER" "$PPPD" || return 1
  chmod 0644 "/data/local/tmp/pppoe.so"
  chcon -R u:object_r:exec_type:s0 "$MINIROOT" 2>/dev/null || true
  chcon u:object_r:exec_type:s0 "$LINKER" "$PPPD" 2>/dev/null || true
  chcon u:object_r:exec_type:s0 "/data/local/tmp/pppoe.so" 2>/dev/null || true
}

: >"$LOG_FILE"
chmod 0600 "$LOG_FILE"
rm -f "$CONTROL_FILE" || true
exec >>"$LOG_FILE" 2>&1
log() { local level="$1"; shift; printf '%s [%s] [module] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2; }
DAEMON_PID=""
log INFO "event=service_ready"

rotate_log() {
  local size
  size="$(wc -c < "$LOG_FILE")"
  [ "$size" -gt 1048576 ] || return 0
  # Preserve open append descriptors held by this service and pppd.
  if cp "$LOG_FILE" "$LOG_FILE.1"; then
    chmod 0600 "$LOG_FILE.1"
    : > "$LOG_FILE"
    log WARN "event=log_truncated archive=pppoe.log.1"
  else
    log ERROR "event=log_rotation_failed"
  fi
}

reap_daemon() {
  [ -n "$DAEMON_PID" ] || return 0
  owned_pid "$DAEMON_PID" && return 0
  local status=0
  wait "$DAEMON_PID" 2>/dev/null || status=$?
  log ERROR "event=daemon_exit pid=$DAEMON_PID exit=$status"
  DAEMON_PID=""
  cleanup_pppoe
}

read_number_file() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return; }
  tr -d '\r\n\t ' < "$f"
}

validate_range() {
  local v="$1" min="$2" max="$3"
  case "$v" in
    '' ) echo "";;
    *[!0-9]* ) echo "";;
    * ) if [ "${#v}" -gt 4 ] || [ "$v" -lt "$min" ] || [ "$v" -gt "$max" ]; then echo ""; else echo "$v"; fi ;;
  esac
}

resolve_mtu_mru() {
  local mtu_raw mru_raw mtu mru
  mtu_raw="$(read_number_file "$MTU_FILE")"
  mru_raw="$(read_number_file "$MRU_FILE")"
  mtu="$(validate_range "${mtu_raw:-}" "$MTU_MIN" "$MTU_MAX")"
  mru="$(validate_range "${mru_raw:-}" "$MRU_MIN" "$MRU_MAX")"
  [ -n "$mtu" ] || { mtu="$DEFAULT_MTU"; [ -z "$mtu_raw" ] || log WARN "event=invalid_mtu fallback=$mtu"; }
  [ -n "$mru" ] || { mru="$DEFAULT_MRU"; [ -z "$mru_raw" ] || log WARN "event=invalid_mru fallback=$mru"; }
  if [ "$mru" -gt "$mtu" ]; then log WARN "event=mru_clamped mtu=$mtu mru=$mru"; mru="$mtu"; fi
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
    [ "$i" = "lo" ] && continue
    [ -d "/sys/class/net/$i" ] || continue
    if [ -d "/sys/class/net/$i/wireless" ]; then
      log INFO "event=wifi_candidate iface=$i requires_ap_passthrough=true"
    fi
    ip link set dev "$i" up 2>/dev/null || true
    for t in 0 1 2 3 4 5; do
      state="$(cat /sys/class/net/$i/operstate 2>/dev/null || echo unknown)"
      [ "$state" = "up" ] && break
      sleep 1
    done
    [ "$state" = "up" ] || [ "$state" = "unknown" ] || continue
    printf '%s\n' "$i"
    return 0
  done
  log ERROR "event=no_active_interface"
  return 1
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
IF="$1"; IPLOCAL="$4"; IPREMOTE="$5"
DNS1="${DNS1:-}"; DNS2="${DNS2:-}"
log() { local level="$1"; shift; printf '%s [%s] [module] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >> /data/local/tmp/pppoe.log; }

if ! ip route replace default dev "$IF" table 10000; then
  log ERROR "event=route_setup_failed step=route iface=$IF"
  exit 1
fi
# An existing identical rule is expected after a reconnect.
if ! ip rule show | grep -Eq '^10000:[[:space:]]+from all lookup 10000[[:space:]]*$'; then
  if ! ip rule add pref 10000 lookup 10000; then
    log ERROR "event=route_setup_failed step=rule iface=$IF"
    ip route del default dev "$IF" table 10000 || true
    exit 1
  fi
fi
ip route flush cache 2>/dev/null || log WARN "event=route_cache_flush_failed iface=$IF"

if ! {
  echo "IF=$IF"
  echo "IPLOCAL=$IPLOCAL"
  echo "IPREMOTE=$IPREMOTE"
  [ -n "$DNS1" ] && echo "DNS1=$DNS1" || true
  [ -n "$DNS2" ] && echo "DNS2=$DNS2" || true
} >/data/local/tmp/pppoe_peer.env.tmp; then
  log ERROR "event=peer_state_write_failed iface=$IF"
  exit 1
fi
if ! chmod 0644 /data/local/tmp/pppoe_peer.env.tmp || ! mv -f /data/local/tmp/pppoe_peer.env.tmp /data/local/tmp/pppoe_peer.env; then
  log ERROR "event=peer_state_publish_failed iface=$IF"
  exit 1
fi
log INFO "event=peer_up iface=$IF local=$IPLOCAL remote=$IPREMOTE dns1=$DNS1 dns2=$DNS2"

set -u
exit 0
EOF

  cat >"$IP_DOWN" <<'EOF'
#!/system/bin/sh
set -e
set +u
IF="$1"
log() { local level="$1"; shift; printf '%s [%s] [module] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >> /data/local/tmp/pppoe.log; }
# pppd/kernel may already have removed the route when the link went down.
if [ -n "$(ip route show table 10000 default dev "$IF")" ]; then
  ip route del default dev "$IF" table 10000 || log WARN "event=route_cleanup_failed step=route iface=$IF"
fi
if ip rule show | grep -Eq '^10000:[[:space:]]+from all lookup 10000[[:space:]]*$'; then
  ip rule del pref 10000 lookup 10000 || log WARN "event=route_cleanup_failed step=rule iface=$IF"
fi
ip route flush cache 2>/dev/null || true
echo "IF=" >/data/local/tmp/pppoe_peer.env.tmp 2>/dev/null || true
mv -f /data/local/tmp/pppoe_peer.env.tmp /data/local/tmp/pppoe_peer.env 2>/dev/null || true
chmod 0644 /data/local/tmp/pppoe_peer.env 2>/dev/null || true
log INFO "event=peer_down iface=$IF"
set -u
exit 0
EOF

  chmod 0755 "$IP_UP" "$IP_DOWN"
  echo "$IP_UP" "$IP_DOWN"
}

start_pppoe_with_iface() {
  local IFACE="$1"
  case "$IFACE" in ''|*[!a-zA-Z0-9_.:-]*) log ERROR "event=invalid_interface"; return 1 ;; esac
  USERNAME="$(cat "$USER_FILE" 2>/dev/null || true)"
  PASSWORD="$(cat "$PASS_FILE" 2>/dev/null || true)"
  case "$USERNAME$PASSWORD" in
    *'
'*) log ERROR "event=invalid_credentials reason=multiline"; return 1 ;;
  esac
  MTU_MRU="$(resolve_mtu_mru)"
  MTU="$(echo "$MTU_MRU" | awk '{print $1}')"
  MRU="$(echo "$MTU_MRU" | awk '{print $2}')"
  if [ ! -d "/sys/class/net/$IFACE" ]; then
    log ERROR "event=interface_missing iface=$IFACE"
    return 1
  fi
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    if [ ! -f "$PIDFILE" ] || ! owned_pid "$(cat "$PIDFILE" 2>/dev/null || true)"; then
      rmdir "$LOCKDIR" 2>/dev/null || true
      mkdir "$LOCKDIR" 2>/dev/null || { log ERROR "event=start_lock_busy"; return 1; }
    else
      log INFO "event=start_skipped reason=already_running"
      return 0
    fi
  fi

  if [ -f "$PIDFILE" ]; then
    OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
    if owned_pid "$OLD"; then
      log INFO "event=start_skipped reason=already_running pid=$OLD"
      rmdir "$LOCKDIR" 2>/dev/null || true
      return 0
    fi
    rm -f "$PIDFILE"
  fi

  if ! prep_binaries; then
    rmdir "$LOCKDIR" 2>/dev/null || true
    log ERROR "event=binaries_prepare_failed"
    return 1
  fi

  log INFO "event=daemon_start iface=$IFACE mtu=$MTU mru=$MRU"

  ip link set dev "$IFACE" up 2>/dev/null || true

  HOOKS="$(make_hooks)"
  IP_UP="$(echo "$HOOKS" | awk '{print $1}')"
  IP_DOWN="$(echo "$HOOKS" | awk '{print $2}')"

  # pppd parses its own option syntax; shell quoting does not apply here.
  USERNAME="$(printf '%s' "$USERNAME" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  PASSWORD="$(printf '%s' "$PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  OPTFILE="/data/local/tmp/ppp.options"
  rm -f "$OPTFILE"
  cat >"$OPTFILE" <<EOF
plugin $PPPOE_PLUGIN
nic-$IFACE

linkname pppoe0
ifname ppp0
unit 0
name "$USERNAME"
user "$USERNAME"
password "$PASSWORD"

noauth
nodefaultroute
nodetach
usepeerdns

mtu $MTU
mru $MRU

lcp-echo-interval 10
lcp-echo-failure 3

ip-up-script $IP_UP
ip-down-script $IP_DOWN
logfd 2

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

  local PID=$!
  printf '%s\n' "$PID" > "$PIDFILE"
  DAEMON_PID="$PID"
  log INFO "event=daemon_started pid=$PID"
  rmdir "$LOCKDIR" 2>/dev/null || true
  sleep 1
  if ! owned_pid "$PID"; then
    reap_daemon
    return 1
  fi
  return 0
}

start_pppoe() {
  local picked
  picked="$(choose_iface)" || return 1
  log INFO "event=interface_selected iface=$picked"
  start_pppoe_with_iface "$picked" || return 1
}

# Never signal a PID unless it still belongs to our private daemon/options.
owned_pid() {
  local pid="${1:-}" args
  case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
  [ -r "/proc/$pid/cmdline" ] || return 1
  args="$(tr '\000' '\n' < "/proc/$pid/cmdline")"
  printf '%s\n' "$args" | grep -qxF "$PPPD" || return 1
  printf '%s\n' "$args" | grep -qxF "/data/local/tmp/ppp.options" || return 1
  kill -0 "$pid" 2>/dev/null
}

cleanup_pppoe() {
  ip route del default dev ppp0 table 10000 2>/dev/null || true
  ip rule del pref 10000 lookup 10000 2>/dev/null || true
  ip route flush cache 2>/dev/null || true
  rm -f "$PIDFILE" /data/local/tmp/ppp.options
  rmdir "$LOCKDIR" 2>/dev/null || true
  echo "IF=" > "$PEER_ENV.tmp"
  chmod 0644 "$PEER_ENV.tmp"
  mv -f "$PEER_ENV.tmp" "$PEER_ENV"
}

stop_pppoe() {
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if owned_pid "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5; do
      owned_pid "$pid" || break
      sleep 1
    done
    if owned_pid "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
    wait "$pid" 2>/dev/null || true
  fi
  cleanup_pppoe
  DAEMON_PID=""
  log INFO "event=stopped"
}

cycle_iface() {
  local list new_first rest
  list="$(list_ifaces | tr '\n' ' ')"
  [ -z "$list" ] && { log ERROR "event=no_interface_candidates"; return; }
  new_first="$(echo "$list" | awk '{print $2}')"
  [ -z "$new_first" ] && new_first="$(echo "$list" | awk '{print $1}')"
  echo "$new_first" > "$IFACE_FILE"
  log INFO "event=interface_cycle iface=$new_first"
}

main_loop() {
  while :; do
    rotate_log
    reap_daemon
    if [ -f "$CONTROL_FILE" ]; then
      # Claim a complete command before reading; a new command can arrive safely.
      if ! mv -f "$CONTROL_FILE" "$CONTROL_FILE.processing" 2>/dev/null; then continue; fi
      CMD="$(cat "$CONTROL_FILE.processing" 2>/dev/null || true)"
      rm -f "$CONTROL_FILE.processing"
      case "$CMD" in
        start) log INFO "event=command action=start"; start_pppoe || true ;;
        stop) log INFO "event=command action=stop"; stop_pppoe || true ;;
        cycle) log INFO "event=command action=cycle"; stop_pppoe || true; cycle_iface; start_pppoe || true ;;
        switch\ *)
          log INFO "event=command action=switch"
          tgt="$(echo "$CMD" | awk '{print $2}')"
          if [ -n "$tgt" ]; then
            stop_pppoe
            echo "$tgt" > "$IFACE_FILE"
            log INFO "event=interface_switch"
            start_pppoe || true
          else
            log ERROR "event=invalid_command reason=missing_interface"
          fi
          ;;
        *) log WARN "event=invalid_command" ;;
      esac
    fi
    sleep 1
  done
}

main_loop
