#!/system/bin/sh
# Magisk service.sh — PPPoE root 后台服务（整合版）
# 说明：
# 1) 仍通过 su 向 /data/local/tmp/pppoe_control 写入 "start"/"stop" 控制
# 2) 自动选择以太网接口；也可 echo iface > /data/local/tmp/pppoe_iface 手动覆盖
# 3) ip-up/ip-down 内置：加默认路由 & 注入 DNS（Android 属性）

set -eu
# 彻底屏蔽 termux-exec 注入（父、子两层都兜底）
unset LD_PRELOAD LD_LIBRARY_PATH
export LD_PRELOAD= LD_LIBRARY_PATH=

# ---------- 基础路径 ----------
MODDIR="${0%/*}"
MINIROOT="/data/adb/modules/pppoe-enabler/miniroot"
LINKER="/data/local/tmp/ppp_linker"
PPPD="/data/local/tmp/ppp_daemon"
cp -f "$MINIROOT/usr/lib/pppd/2.5.1/pppoe.so" "/data/local/tmp/pppoe.so"
chmod 0644 "/data/local/tmp/pppoe.so"
chcon u:object_r:exec_type:s0 "/data/local/tmp/pppoe.so" 2>/dev/null || true

LOG_FILE="/data/local/tmp/pppoe.log"
CONTROL_FILE="/data/local/tmp/pppoe_control"
USER_FILE="/data/local/tmp/pppoe_user"
PASS_FILE="/data/local/tmp/pppoe_pass"
IFACE_FILE="/data/local/tmp/pppoe_iface"

# ---------- 等系统就绪 ----------
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done


# ---------- 准备可执行（绕 noexec） ----------
cp -f "$MINIROOT/lib/ld-musl-aarch64.so.1" "$LINKER"
cp -f "$MINIROOT/usr/sbin/pppd" "$PPPD"
chmod 0755 "$LINKER" "$PPPD"
# SELinux 放行（允许失败不致命）
chcon -R u:object_r:exec_type:s0 "$MINIROOT" 2>/dev/null || true
chcon u:object_r:exec_type:s0 "$LINKER" "$PPPD" 2>/dev/null || true

# ---------- 初始化日志 ----------
echo "PPPoE Service Initialized at $(date)" >"$LOG_FILE"
echo "Ready for commands." >>"$LOG_FILE"
rm -f "$CONTROL_FILE" || true
# 让整个脚本的 stdout/stderr 都写入日志，并打开命令跟踪
exec >>"$LOG_FILE" 2>&1
set -x


# ---------- 工具：选择接口 ----------
choose_iface() {
  if [ -f "$IFACE_FILE" ]; then
    tr -d '\r\n ' < "$IFACE_FILE"
    return
  fi
  for n in /sys/class/net/*; do
    # type=1 表示以太网（排除 lo/wlan/rmnet/ccmni/tun 等）
    [ "$(cat "$n/type" 2>/dev/null || echo)" = "1" ] || continue
    bn="$(basename "$n")"
    echo "$bn" | grep -Eq '^(eth|en|usb|rndis|enx)' || continue
    echo "$bn"
    return
  done
  # 回退
  echo "eth0"
}

# ---------- 启动 PPPoE ----------
start_pppoe() {
  USERNAME="$(cat "$USER_FILE" 2>/dev/null || true)"
  PASSWORD="$(cat "$PASS_FILE" 2>/dev/null || true)"
  IFACE="$(choose_iface)"

  # 固定 PIDFILE（务必在任何引用前定义，配合 set -u）
  PIDFILE="/data/local/tmp/pppd-pppoe0.pid"

  # --- 互斥锁：只保护“启动前检查”，并处理陈旧锁 ---
  LOCKDIR="/data/local/tmp/.pppoe.lock"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    # 若有锁但没有活的 pppd，视为陈旧锁
    if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null; then
      rmdir "$LOCKDIR" 2>/dev/null || true
      mkdir "$LOCKDIR" 2>/dev/null || { echo "Start skipped: lock busy and cannot recover." >>"$LOG_FILE"; return; }
    else
      echo "Start skipped: another start is in progress." >> "$LOG_FILE"
      return
    fi
  fi

  # 避免多实例
  if [ -f "$PIDFILE" ]; then
    OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
      echo "pppd already running (pid=$OLD), skip." >> "$LOG_FILE"
      rmdir "$LOCKDIR" 2>/dev/null || true
      return
    fi
    rm -f "$PIDFILE"
  fi

  echo "Attempting to start PPPoE connection..." >>"$LOG_FILE"
  echo "Using interface: $IFACE" >>"$LOG_FILE"

  # 启动前清理旧进程
  killall ppp_daemon pppd 2>/dev/null || true

  # 洗环境（防 Termux 注入）
  unset LD_PRELOAD LD_LIBRARY_PATH
  export LD_PRELOAD=
  export LD_LIBRARY_PATH=

  # 接口置 UP（忽略失败即可）
  ip link set dev "$IFACE" up 2>/dev/null || true

  # 生成钩子脚本（放模块目录，便于迁移）
# ---------- 生成 ip-up / ip-down ----------
HOOKDIR="$MODDIR/hooks"
mkdir -p "$HOOKDIR"
IP_UP="$HOOKDIR/ip-up.sh"
IP_DOWN="$HOOKDIR/ip-down.sh"

# ip-up.sh
cat >"$IP_UP" <<'EOF'
#!/system/bin/sh
# $1=ifname；pppd（usepeerdns）会以环境变量提供 DNS1/DNS2
set -e
set +u

IF="$1"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"

# 1) 先清理其它默认路由，避免和 ppp0 抢默认
ip route | awk '/^default/ && !/ppp0/ {print}' | while read -r l; do ip route del $l 2>/dev/null; done

# 2) 尝试用 Android 的网络栈把 ppp0 设为默认网络，并注入 DNS
NETID=520   # 任选未用的 ID；ip-down 会清理
OK=0
if cmd network create $NETID 2>/dev/null; then
  cmd network interface add $NETID "$IF" 2>/dev/null || true
  if cmd network default $NETID 2>/dev/null; then
    # 注入 DNS 到该网络
    cmd netd resolver setnetdns $NETID "" "$DNS1" "$DNS2" 2>/dev/null || true
    OK=1
  fi
fi

# 3) 如果 netd 方法失败，则回退到路由层面设置默认路由 + 写系统属性 DNS
if [ "$OK" -ne 1 ]; then
  ip route replace default dev "$IF" metric 0 2>/dev/null || ip route add default dev "$IF" metric 0 2>/dev/null
  ip rule add pref 10000 lookup main 2>/dev/null || true
  ip route flush cache
  setprop net.dns1 "$DNS1"
  setprop net.dns2 "$DNS2"
fi

# 4) 给需要 resolv.conf 的程序一份兼容
{
  echo "nameserver $DNS1"
  echo "nameserver $DNS2"
} > /data/local/tmp/resolv.conf

set -u
exit 0

EOF

# ip-down.sh
cat >"$IP_DOWN" <<'EOF'
#!/system/bin/sh
set -e
set +u

IF="$1"
NETID=520

# 1) 恢复网络默认路由/默认网络
cmd network default 2>/dev/null || true
cmd network destroy $NETID 2>/dev/null || true

# 2) 路由/策略回收
ip route del default dev "$IF" 2>/dev/null || true
ip rule del pref 10000 lookup main 2>/dev/null || true
ip route flush cache

# 3) 清理 DNS 属性（可选）
setprop net.dns1 ""
setprop net.dns2 ""

set -u
exit 0

EOF

chmod 0755 "$IP_UP" "$IP_DOWN"
# ---------- 生成 pppd options 文件（只放 pppd 选项，禁止混入 shell） ----------
OPTFILE="/data/local/tmp/ppp.options"
cat >"$OPTFILE" <<EOF
# === pppd options (auto-generated) ===
plugin $MINIROOT/usr/lib/pppd/2.5.1/pppoe.so
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

mtu 1492
mru 1492

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


# 自检：把关键路径/文件状态写进日志
echo "[selfcheck] LINKER: $LINKER"  ; ls -l "$LINKER"  || true
echo "[selfcheck] PPPD  : $PPPD"    ; ls -l "$PPPD"    || true
echo "[selfcheck] PLUGIN: $MINIROOT/usr/lib/pppd/2.5.1/pppoe.so" ; ls -l "$MINIROOT/usr/lib/pppd/2.5.1/pppoe.so" || true
echo "[selfcheck] OPTS  : $OPTFILE" ; sed -n '1,80p' "$OPTFILE" || true
echo "[selfcheck] IFACE : $IFACE"
echo "[selfcheck] USER  : $( [ -n "$USERNAME" ] && echo ok || echo empty )"

# 用“手工成功”的方式启动（注意：所有输出已被上面的 exec >>$LOG_FILE 捕获进日志）
set +e
/system/bin/env -i \
  PATH=/system/bin:/system/xbin:/vendor/bin \
  HOME=/data/local/tmp TMPDIR=/data/local/tmp \
  LD_PRELOAD= LD_LIBRARY_PATH= \
  "$LINKER" --library-path "$MINIROOT/lib:$MINIROOT/usr/lib" \
  "$PPPD" file "$OPTFILE" &
RC=$?; PID=$!
echo "[exec] fork rc=$RC pid=$PID"
set -e

rmdir "$LOCKDIR" 2>/dev/null || true
[ $RC -ne 0 ] && { echo "[error] pppd exec failed (rc=$RC)"; return; }



}

# ---------- 停止 ----------
stop_pppoe() {
  set +e
  PIDFILE="/data/local/tmp/pppd-pppoe0.pid"
  NETID=520

  # 0) 先把默认网络切回系统并销毁我们创建的网络
  cmd network default 2>/dev/null
  cmd network destroy $NETID 2>/dev/null
  ndc network destroy $NETID 2>/dev/null

  # 1) 按 pidfile 杀
  if [ -f "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$PID" ] && kill -TERM "$PID" 2>/dev/null
  fi

  # 2) 兜底：按进程名杀 + 按命令行匹配杀
  killall -TERM ppp_daemon pppd 2>/dev/null
  pkill -f "/data/local/tmp/ppp_daemon" 2>/dev/null
  pkill -f "plugin .*pppoe.so" 2>/dev/null

  # 3) 最多等 3 秒，真的还不退就 KILL
  for i in 1 2 3; do
    sleep 1
    pgrep -f "/data/local/tmp/ppp_daemon|pppd" >/dev/null 2>&1 || break
  done
  pgrep -f "/data/local/tmp/ppp_daemon|pppd" >/dev/null 2>&1 && \
    killall -KILL ppp_daemon pppd 2>/dev/null

  # 4) 路由/规则/iptables 清理
  ip link del ppp0 2>/dev/null
  ip route del default dev ppp0 2>/dev/null
  ip rule del pref 10000 lookup main 2>/dev/null
  ip route flush cache

  # 5) DNS 劫持规则清理（有就删，没有就算了）
  IPT="$(command -v iptables || command -v iptables-nft || true)"
  if [ -n "$IPT" ]; then
    $IPT -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null
    $IPT -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null
    for u in 0 9999; do
      $IPT -t nat -D OUTPUT -m owner --uid-owner "$u" -j RETURN 2>/dev/null
    done
  fi

  # 6) dnsmasq（如有）停掉
  [ -f /data/local/tmp/dnsmasq-pppoe.pid ] && \
    kill -TERM "$(cat /data/local/tmp/dnsmasq-pppoe.pid 2>/dev/null)" 2>/dev/null
  rm -f /data/local/tmp/dnsmasq-pppoe.pid

  # 7) 文件/锁清理
  rm -f "$PIDFILE"
  rm -rf /data/local/tmp/.pppoe.lock
  setprop net.dns1 ""
  setprop net.dns2 ""
  echo "Stop command sent." >> "$LOG_FILE"
  set -e
}


# ---------- 主循环：等控制命令 ----------
while :; do
  if [ -f "$CONTROL_FILE" ]; then
    CMD="$(cat "$CONTROL_FILE" 2>/dev/null || echo)"
    rm -f "$CONTROL_FILE" || true
    case "$CMD" in
      start) start_pppoe ;;
      stop)  stop_pppoe  ;;
      *)     echo "Unknown command: $CMD" >>"$LOG_FILE" ;;
    esac
  fi
  sleep 1
done
