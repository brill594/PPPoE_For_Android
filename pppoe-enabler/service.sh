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
  HOOKDIR="$MODDIR/hooks"
  mkdir -p "$HOOKDIR"
  IP_UP="$HOOKDIR/ip-up.sh"
  IP_DOWN="$HOOKDIR/ip-down.sh"

  # ——注意：这里不要缩进 shebang——
# ip-up.sh
cat >"$IP_UP" <<'EOS'
#!/system/bin/sh
# $1=ifname, $DNS1/$DNS2 由 usepeerdns 注入
IF="$1"

# 1) 删掉非 ppp0 的默认路由（避免抢默认）
ip route | awk '/^default/ && !/ppp0/ {print}' | while read -r l; do ip route del $l 2>/dev/null; done

# 2) 顶上 PPP 默认路由 + 兜底策略路由（Android 环境必加）
ip route replace default dev "$IF" metric 0 2>/dev/null || ip route add default dev "$IF" metric 0 2>/dev/null
ip rule add pref 10000 lookup main 2>/dev/null || true
ip route flush cache

# 3) 注入 DNS 属性 + 写一份 resolv.conf（给部分程序用）
[ -n "$DNS1" ] && setprop net.dns1 "$DNS1"
[ -n "$DNS2" ] && setprop net.dns2 "$DNS2"
{
  [ -n "$DNS1" ] && echo "nameserver $DNS1"
  [ -n "$DNS2" ] && echo "nameserver $DNS2"
} > /data/local/tmp/resolv.conf
DNSMASQ="$MINIROOT/usr/sbin/dnsmasq"
DNSP=5353
UP1="${DNS1:-1.1.1.1}"
UP2="${DNS2:-8.8.8.8}"
IPT="$(command -v iptables || command -v iptables-nft || echo iptables)"

if [ -x "$DNSMASQ" ]; then
  # 停旧实例
  if [ -f /data/local/tmp/dnsmasq-pppoe.pid ]; then
    kill -TERM "$(cat /data/local/tmp/dnsmasq-pppoe.pid)" 2>/dev/null || true
    rm -f /data/local/tmp/dnsmasq-pppoe.pid
  fi

  # 用 musl 链接器启动 dnsmasq（保持和 pppd 一致的 loader + lib 路径）
  "$MINIROOT/lib/ld-musl-aarch64.so.1" \
    --library-path "$MINIROOT/lib:$MINIROOT/usr/lib" \
    "$DNSMASQ" \
      --no-resolv --server="$UP1" --server="$UP2" \
      --listen-address=127.0.0.1 --port=$DNSP --bind-interfaces \
      --user=nobody --group=nobody \
      --cache-size=500 --dns-forward-max=200 \
      --pid-file=/data/local/tmp/dnsmasq-pppoe.pid \
      --log-facility=/data/local/tmp/dnsmasq.log \
      --log-async=50 >/dev/null 2>&1 &

  # 把本机所有发往 :53 的流量重定向到 127.0.0.1:5353（排除 dnsmasq 自己以防自吃）
  NUID="$(id -u nobody 2>/dev/null || echo 9999)"
  $IPT -t nat -D OUTPUT -m owner --uid-owner "$NUID" -j RETURN 2>/dev/null || true
  $IPT -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports $DNSP 2>/dev/null || true
  $IPT -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports $DNSP 2>/dev/null || true

  if ! $IPT -t nat -A OUTPUT -m owner --uid-owner "$NUID" -j RETURN 2>/dev/null; then
    # 某些内核没 xt_owner：退化为放行 127.0.0.1
    $IPT -t nat -A OUTPUT -d 127.0.0.1/32 -p udp --dport 53 -j RETURN
    $IPT -t nat -A OUTPUT -d 127.0.0.1/32 -p tcp --dport 53 -j RETURN
  fi
  $IPT -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports $DNSP
  $IPT -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports $DNSP
fi

exit 0
EOS

# ip-down.sh
cat >"$IP_DOWN" <<'EOS'
#!/system/bin/sh
IF="$1"
ip route del default dev "$IF" 2>/dev/null || true
ip rule del pref 10000 lookup main 2>/dev/null || true
# 可选：清理 DNS 属性
setprop net.dns1 ""
setprop net.dns2 ""
exit 0
EOS
chmod 0755 "$IP_UP" "$IP_DOWN"
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
IPT="$(command -v iptables || command -v iptables-nft || echo iptables)"
NUID="$(id -u nobody 2>/dev/null || echo 9999)"
DNSP=5353
[ -f /data/local/tmp/dnsmasq-pppoe.pid ] && kill -TERM "$(cat /data/local/tmp/dnsmasq-pppoe.pid)" 2>/dev/null
rm -f /data/local/tmp/dnsmasq-pppoe.pid
$IPT -t nat -D OUTPUT -m owner --uid-owner "$NUID" -j RETURN 2>/dev/null || true
$IPT -t nat -D OUTPUT -d 127.0.0.1/32 -p udp --dport 53 -j RETURN 2>/dev/null || true
$IPT -t nat -D OUTPUT -d 127.0.0.1/32 -p tcp --dport 53 -j RETURN 2>/dev/null || true
$IPT -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports $DNSP 2>/dev/null || true
$IPT -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports $DNSP 2>/dev/null || true

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
  PIDFILE="/data/local/tmp/pppd-pppoe0.pid"
  # 1) 温柔结束
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE" 2>/dev/null || echo)
    [ -n "$PID" ] && kill -TERM "$PID" 2>/dev/null || true
    sleep 1
  fi
  # 2) 兜底砍掉
  killall -TERM ppp_daemon pppd 2>/dev/null || true
  sleep 1
  killall -KILL ppp_daemon pppd 2>/dev/null || true

  # 3) 删接口、清路由/规则/锁
  ip link del ppp0 2>/dev/null || true
  ip route flush cache
  rm -f "$PIDFILE"
  rm -rf /data/local/tmp/.pppoe.lock
  echo "Stop command sent." >> "$LOG_FILE"
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
