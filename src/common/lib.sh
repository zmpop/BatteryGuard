#!/system/bin/sh
# Battery Guard - 公共函数库
# 被 post-fs-data.sh / service.sh / common/*.sh / uninstall.sh / action.sh 引用
# 注意：本文件只定义变量与函数，不执行任何动作

MODID=battery_guard

# ---------------- 路径 ----------------
PERSIST_DIR=/data/adb/battery-guard
CONF_FILE=$PERSIST_DIR/battery-guard.conf
LOG_FILE=$PERSIST_DIR/battery-guard.log
NODES_FILE=$PERSIST_DIR/nodes.conf
LOCK_DIR=$PERSIST_DIR/.lock
PID_FILE=$PERSIST_DIR/daemon.pid
DAEMON_SCRIPT=battery-guard-daemon.sh

# ---------------- 默认参数（会被配置文件覆盖） ----------------
ENABLED=1
UPPER_LIMIT=80
LOWER_LIMIT=40
POLL_INTERVAL=30
MIN_SWITCH_INTERVAL=120
CONFIRM_COUNT=1
REASSERT_SEC=120
ONLY_WHEN_PLUGGED=1
DRY_RUN=0
LOG_MAX_LINES=2000
LOG_HEARTBEAT=20
LOG_TO_LOGCAT=1
LOG_VERBOSE=1
PROBE_WRITE_TEST=1
CURRENT_LIMIT_VALUE=0
RESTART_DELAY=30
EARLY_START=0
TRUST_USB_ONLINE=0
TRUST_CHARGING_TYPE=1
TRUST_CHARGING_SOURCE=1
FORCE_NODE=""
NODE_PREFERENCE="direct,invert,current_limit"

umask 022
export PATH=/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:/sbin:/su/bin:/data/adb/ksu/bin:$PATH

# ---------------- 定位模块目录 ----------------
resolve_moddir() {
  if [ -n "$MODDIR" ] && [ -f "$MODDIR/module.prop" ]; then
    echo "$MODDIR"
    return 0
  fi
  d=""
  case "$0" in
    */*)
      d=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
      case "$d" in
        */common) d=$(cd "$d/.." 2>/dev/null && pwd) ;;
      esac
      ;;
  esac
  if [ -n "$d" ] && [ -f "$d/module.prop" ]; then
    echo "$d"
    return 0
  fi
  echo "/data/adb/modules/$MODID"
}
MODDIR=$(resolve_moddir)

mkdir -p "$PERSIST_DIR" 2>/dev/null
chmod 0755 "$PERSIST_DIR" 2>/dev/null

# ---------------- 配置 ----------------
ensure_conf() {
  if [ ! -f "$CONF_FILE" ] && [ -f "$MODDIR/common/battery-guard.conf" ]; then
    cp -f "$MODDIR/common/battery-guard.conf" "$CONF_FILE" 2>/dev/null
  fi
  chmod 0644 "$CONF_FILE" 2>/dev/null
}

load_conf() {
  ensure_conf
  if [ -f "$CONF_FILE" ]; then
    # 只接受 KEY=VALUE 行，避免注释/异常内容被解析
    safe_conf=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$CONF_FILE" 2>/dev/null)
    [ -n "$safe_conf" ] && eval "$safe_conf"
  fi
  # 参数合法性校正
  UPPER_LIMIT=$(echo "$UPPER_LIMIT" | tr -dc '0-9'); [ -n "$UPPER_LIMIT" ] || UPPER_LIMIT=80
  LOWER_LIMIT=$(echo "$LOWER_LIMIT" | tr -dc '0-9'); [ -n "$LOWER_LIMIT" ] || LOWER_LIMIT=40
  POLL_INTERVAL=$(echo "$POLL_INTERVAL" | tr -dc '0-9'); [ -n "$POLL_INTERVAL" ] || POLL_INTERVAL=30
  [ "$POLL_INTERVAL" -ge 5 ] || POLL_INTERVAL=5
  [ "$UPPER_LIMIT" -le 100 ] || UPPER_LIMIT=100
  [ "$LOWER_LIMIT" -ge 0 ] || LOWER_LIMIT=0
  # 下限必须小于上限，且至少留出 5% 滞回区间
  if [ "$LOWER_LIMIT" -gt $((UPPER_LIMIT - 5)) ]; then
    LOWER_LIMIT=$((UPPER_LIMIT - 5))
    [ "$LOWER_LIMIT" -ge 0 ] || LOWER_LIMIT=0
  fi
}

# ---------------- 日志 ----------------
log_print() {
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null
  if [ "$LOG_TO_LOGCAT" = "1" ]; then
    log -p i -t BatteryGuard "$*" 2>/dev/null
  fi
}

log_rotate() {
  max=${LOG_MAX_LINES:-2000}
  cnt=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -dc '0-9')
  [ -n "$cnt" ] || return 0
  [ "$cnt" -gt "$max" ] 2>/dev/null || return 0
  keep=$((max / 2))
  [ "$keep" -gt 0 ] 2>/dev/null || return 0

  # 轮转是唯一会覆盖写日志文件的操作，必须先校验临时文件确实是正确的裁剪结果，
  # 否则一旦 tail/wc 在某些内核上下文输出异常值，整个日志会被清成几字节
  old=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -dc '0-9')
  tail -n "$keep" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null
  new=$(wc -c < "$LOG_FILE.tmp" 2>/dev/null | tr -dc '0-9')
  head1=$(head -n 1 "$LOG_FILE.tmp" 2>/dev/null)

  if [ -n "$new" ] && [ -n "$old" ] &&
     [ "$new" -gt 100 ] 2>/dev/null &&
     [ "$new" -lt "$old" ] 2>/dev/null &&
     [ "${head1#[}" != "$head1" ]; then
    mv -f "$LOG_FILE.tmp" "$LOG_FILE"
    [ "$LOG_VERBOSE" = "1" ] && log_print "日志轮转：保留最近 $keep 行（${old} -> ${new} 字节）"
  else
    rm -f "$LOG_FILE.tmp"
    [ "$LOG_VERBOSE" = "1" ] && log_print "日志轮转已跳过：校验未通过（原 ${old:-?} 字节 / 裁剪后 ${new:-?} 字节）"
  fi
}

# ---------------- sysfs 读写 ----------------
node_read() {
  cat "$1" 2>/dev/null | tr -d '\r\n '
}

node_write() {
  # $1=节点路径 $2=写入值
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  if echo "$2" > "$1" 2>/dev/null; then
    return 0
  fi
  # 回退：另起一个 shell 写入（个别 ROM 上直接重定向被 selinux 拦截）
  /system/bin/sh -c "echo '$2' > '$1'" 2>/dev/null && return 0
  return 1
}

# ---------------- 节点状态载入 ----------------
# nodes.conf 中有效行格式：KIND PATH DEFAULT
load_node() {
  NODE_KIND=""
  NODE_PATH=""
  NODE_DEFAULT=""
  if [ -n "$FORCE_NODE" ]; then
    forced=${FORCE_NODE#*:}
    NODE_KIND=${FORCE_NODE%%:*}
    if [ -e "$forced" ]; then
      NODE_PATH=$forced
      NODE_DEFAULT=$(node_read "$forced")
      return 0
    fi
    log_print "警告: FORCE_NODE 指定的节点不存在 ($forced)，回退自动探测"
  fi
  [ -f "$NODES_FILE" ] || return 1
  line=$(grep -v '^[[:space:]]*#' "$NODES_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 1)
  [ -n "$line" ] || return 1
  set -- $line
  NODE_KIND=$1
  NODE_PATH=$2
  NODE_DEFAULT=$3
  [ -n "$NODE_KIND" ] && [ -n "$NODE_PATH" ] && return 0
  return 1
}

node_save() {
  # $1=KIND $2=PATH $3=DEFAULT
  {
    echo "# Battery Guard 节点探测结果（自动生成，勿手动编辑）"
    echo "# 格式: KIND PATH DEFAULT_VALUE"
    echo "$1 $2 $3"
  } > "$NODES_FILE" 2>/dev/null
  chmod 0644 "$NODES_FILE" 2>/dev/null
}

# ---------------- 充电动作 ----------------
charge_on() {
  # 恢复充电（系统默认行为）
  LAST_WRITE="-"
  case "$NODE_KIND" in
    invert)
      if node_write "$NODE_PATH" 0; then LAST_WRITE=0
      else log_print "警告: 写入 $NODE_PATH 失败（允许充电）"; fi ;;
    direct)
      if node_write "$NODE_PATH" 1; then LAST_WRITE=1
      else log_print "警告: 写入 $NODE_PATH 失败（允许充电）"; fi ;;
    current_limit)
      v=$NODE_DEFAULT
      if [ -z "$v" ]; then
        log_print "警告: 未记录电流默认值，跳过恢复（避免误写 0 导致停充）"
      elif node_write "$NODE_PATH" "$v"; then
        LAST_WRITE=$v
      else
        log_print "警告: 写入 $NODE_PATH 失败（允许充电）"
      fi ;;
    none|"") ;;
  esac
  return 0
}

charge_off() {
  # 停止充电
  LAST_WRITE="-"
  case "$NODE_KIND" in
    invert)
      if node_write "$NODE_PATH" 1; then LAST_WRITE=1
      else log_print "警告: 写入 $NODE_PATH 失败（停止充电）"; fi ;;
    direct)
      if node_write "$NODE_PATH" 0; then LAST_WRITE=0
      else log_print "警告: 写入 $NODE_PATH 失败（停止充电）"; fi ;;
    current_limit)
      if node_write "$NODE_PATH" "$CURRENT_LIMIT_VALUE"; then LAST_WRITE=$CURRENT_LIMIT_VALUE
      else log_print "警告: 写入 $NODE_PATH 失败（停止充电）"; fi ;;
    none|"") ;;
  esac
  return 0
}

# ---------------- 电量/充电状态 ----------------
find_cap_node() {
  for c in /sys/class/power_supply/battery/capacity \
           /sys/class/power_supply/Battery/capacity \
           /sys/class/power_supply/batt/capacity \
           /sys/class/sec/battery/capacity; do
    if [ -r "$c" ]; then echo "$c"; return 0; fi
  done
  echo "/sys/class/power_supply/battery/capacity"
}

read_capacity() {
  v=$(cat "$CAP_NODE" 2>/dev/null | tr -dc '0-9')
  [ -n "$v" ] || v=0
  # 防越界
  [ "$v" -ge 0 ] 2>/dev/null || v=0
  [ "$v" -le 100 ] 2>/dev/null || v=100
  echo "$v"
}

read_batt_status() {
  cat /sys/class/power_supply/battery/status 2>/dev/null | tr -d '\r\n'
}

detect_plugged() {
  # 注意：三星平板上 /sys/class/power_supply/usb/online 常年为 1（即使没插充电器），
  # 直接采信会造成"未插电却判定已连接"，进而误写停充节点。故按可信度分层判定。
  BAT=/sys/class/power_supply/battery

  # 1) Mains / Wireless / Dock：确定性证据
  for d in /sys/class/power_supply/*; do
    t=$(cat "$d/type" 2>/dev/null | tr -d '\r\n')
    case "$t" in
      *Mains*|*Wireless*|*Wipower*|*Dock*)
        o=$(cat "$d/online" 2>/dev/null | tr -d '\r\n')
        if [ "$o" = "1" ]; then echo 1; return 0; fi ;;
    esac
  done

  # 2) 三星 charging_type：Tab S7+ 实测 未插电=NONE，接 PD 充电器=PDIC
  if [ "$TRUST_CHARGING_TYPE" = "1" ]; then
    v=$(cat "$BAT/charging_type" 2>/dev/null | tr -d '\r\n' | tr 'a-z' 'A-Z')
    case "$v" in
      ""|NONE|NA|N/A|UNKNOWN) ;;
      *) echo 1; return 0 ;;
    esac
  fi

  # 3) 三星 batt_charging_source：位掩码，Tab S7+ 实测 未插电=1，接 PD=19
  if [ "$TRUST_CHARGING_SOURCE" = "1" ]; then
    v=$(cat "$BAT/batt_charging_source" 2>/dev/null | tr -dc '0-9')
    if [ -n "$v" ] && [ "$v" -gt 1 ]; then echo 1; return 0; fi
  fi

  # 4) USB：默认不信（三星常驻 1），需要时把 TRUST_USB_ONLINE 改为 1
  if [ "$TRUST_USB_ONLINE" = "1" ]; then
    for d in /sys/class/power_supply/*; do
      t=$(cat "$d/type" 2>/dev/null | tr -d '\r\n')
      case "$t" in
        *USB*|*USB_*|*USB-C*)
          o=$(cat "$d/online" 2>/dev/null | tr -d '\r\n')
          if [ "$o" = "1" ]; then echo 1; return 0; fi ;;
      esac
    done
  fi

  echo 0
}

# 开机时把节点恢复到"允许充电"的默认值，清除探测写测试 / 异常退出留下的残留。
# 只清扫 safe_nodes.conf 中记录的节点——即探测阶段已验证"可双向读写"的那些，
# 绝不碰疑似单向的节点（三星 store_mode 写任何值都会变成 1，碰了就插电不充电）。
reset_all_nodes() {
  f=$PERSIST_DIR/safe_nodes.conf
  [ -s "$f" ] || return 0
  cnt=0
  while read -r kind path; do
    [ -n "$path" ] || continue
    case "$kind" in
      direct)
        if [ -w "$path" ] && echo 1 > "$path" 2>/dev/null; then
          cnt=$((cnt + 1))
          [ "$LOG_VERBOSE" = "1" ] && log_print "  复位 正向 $path = 1"
        fi ;;
      invert)
        if [ -w "$path" ] && echo 0 > "$path" 2>/dev/null; then
          cnt=$((cnt + 1))
          [ "$LOG_VERBOSE" = "1" ] && log_print "  复位 反向 $path = 0"
        fi ;;
    esac
  done < "$f"
  if [ "$cnt" -gt 0 ]; then
    log_print "开机复位：已把 $cnt 个节点恢复为允许充电的默认值"
  fi
}

# ---------------- 进程管理 ----------------
# 清理跨重启残留的锁：PID 文件里的进程若已不是本模块的进程，就当作陈旧锁清掉
# （否则开机后守护循环会误判"已在运行"而拒绝启动）
clear_stale_locks() {
  # 守护进程锁
  p=$(cat "$PID_FILE" 2>/dev/null | tr -dc '0-9')
  if [ -n "$p" ]; then
    [ -r "/proc/$p/cmdline" ] || continue
    c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$c" in
      *$DAEMON_SCRIPT*) ;;
      *) rm -f "$PID_FILE" 2>/dev/null; rm -rf "$LOCK_DIR" 2>/dev/null ;;
    esac
  else
    rm -rf "$LOCK_DIR" 2>/dev/null
  fi
  # 守护循环锁
  SP=$PERSIST_DIR/supervisor.pid
  SL=$PERSIST_DIR/.slock
  p=$(cat "$SP" 2>/dev/null | tr -dc '0-9')
  if [ -n "$p" ]; then
    [ -r "/proc/$p/cmdline" ] || continue
    c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$c" in
      *supervisor.sh*) ;;
      *) rm -f "$SP" 2>/dev/null; rm -rf "$SL" 2>/dev/null ;;
    esac
  else
    rm -rf "$SL" 2>/dev/null
  fi
}

# 遍历 /proc，避免依赖 ps/pgrep（部分 ROM 未自带）
kill_all() {
  # 第一轮：先杀守护循环（否则它会在守护进程被杀后立刻拉起）
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ "$pid" = "$$" ] && continue
    [ -r "$p/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$cmd" in
      *supervisor.sh*) kill -9 "$pid" 2>/dev/null ;;
    esac
  done
  # 第二轮：再杀守护进程本身（EXIT trap 会恢复默认充电行为，故用 SIGKILL 由调用方统一复位）
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ "$pid" = "$$" ] && continue
    [ -r "$p/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$cmd" in
      *$DAEMON_SCRIPT*) kill -9 "$pid" 2>/dev/null ;;
    esac
  done
  # 兜底复查
  sleep 1
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "$p/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$cmd" in
      *supervisor.sh*|*$DAEMON_SCRIPT*) kill -9 "$pid" 2>/dev/null ;;
    esac
  done
}

is_daemon_running() {
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "$p/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$cmd" in
      *$DAEMON_SCRIPT*) echo "$pid"; return 0 ;;
    esac
  done
  return 1
}

is_supervisor_running() {
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "$p/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$cmd" in
      *supervisor.sh*) echo "$pid"; return 0 ;;
    esac
  done
  return 1
}

daemon_state_text() {
  # 依据实际节点值判断当前策略，避免与内核状态不一致
  case "$NODE_KIND" in
    invert)
      v=$(node_read "$NODE_PATH")
      if [ "$v" = "1" ] || [ "$v" = "2" ]; then echo "停止充电"; else echo "允许充电"; fi ;;
    direct)
      v=$(node_read "$NODE_PATH")
      if [ "$v" = "0" ]; then echo "停止充电"; else echo "允许充电"; fi ;;
    current_limit)
      v=$(node_read "$NODE_PATH")
      if [ "$v" = "$CURRENT_LIMIT_VALUE" ]; then echo "停止充电(限流)"; else echo "允许充电"; fi ;;
    *) echo "未控制(无可用节点)" ;;
  esac
}
