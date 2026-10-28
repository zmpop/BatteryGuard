#!/system/bin/sh
# Battery Guard - 充电阈值守护进程
# 由 service.sh 拉起并常驻；也可手动执行：
#   adb shell su -c "sh /data/adb/modules/battery_guard/common/battery-guard-daemon.sh"
# 逻辑：
#   电量 >= 上限 且 充电器已连接 -> 停止充电
#   电量 <= 下限                 -> 恢复充电（重新充到上限后再次停止）
#   拔掉充电器                   -> 恢复系统默认充电行为
#   防抖：最小切换间隔 + 连续确认次数 + 滞回区间

. "$(dirname "$0")/lib.sh"

# ---------------- 单实例保护 ----------------
OWN_LOCK=0
if mkdir "$LOCK_DIR" 2>/dev/null; then
  OWN_LOCK=1
  echo $$ > "$PID_FILE"
else
  old=$(cat "$PID_FILE" 2>/dev/null | tr -dc '0-9')
  if [ -n "$old" ] && [ -d "/proc/$old" ] && \
     tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q "$DAEMON_SCRIPT"; then
    log_print "守护进程已在运行 (PID=$old)，本次不重复启动"
    exit 0
  fi
  log_print "发现残留锁但进程不存在，清理后接管"
  rm -rf "$LOCK_DIR" 2>/dev/null
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    OWN_LOCK=1
    echo $$ > "$PID_FILE"
  fi
fi
if [ "$OWN_LOCK" != "1" ]; then
  log_print "无法获取运行锁，退出"
  exit 1
fi

# ---------------- 退出时恢复默认充电行为 ----------------
cleanup() {
  if [ "$OWN_LOCK" = "1" ]; then
    log_print "守护进程退出(PID=$$)，恢复系统默认充电行为"
    charge_on
    rm -f "$PID_FILE" 2>/dev/null
    rm -rf "$LOCK_DIR" 2>/dev/null
    OWN_LOCK=0
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 0' TERM INT HUP

# ---------------- 初始化 ----------------
load_conf

if ! load_node; then
  log_print "未找到节点配置，立即执行自动探测"
  sh "$MODDIR/common/probe.sh" >/dev/null 2>&1
  load_node
fi

CAP_NODE=$(find_cap_node)
if [ "$NODE_KIND" = "none" ] || [ -z "$NODE_PATH" ]; then
  log_print "警告: 无可用充电控制节点，本次运行仅记录电量日志"
fi

NOW=$(date +%s | tr -dc '0-9'); [ -n "$NOW" ] || NOW=0
STATE=0
CONFIRM=0
LAST_SWITCH=$((NOW - MIN_SWITCH_INTERVAL))
LAST_REASSERT=$NOW
CYCLE=0
CONF_MTIME=$(stat -c %Y "$CONF_FILE" 2>/dev/null | tr -dc '0-9')
WARNED_DISABLED=0

# 启动时先确保为"允许充电"，避免上一次异常退出留下停充状态
# 同时清扫其它候选节点，清掉探测写测试或异常留下的残留
charge_on
reset_all_nodes
PREV_RAW=$(detect_plugged)

log_print "=== 守护进程启动 PID=$$ ==="
log_print "策略: 上限=${UPPER_LIMIT}% 下限=${LOWER_LIMIT}% 轮询=${POLL_INTERVAL}s 最小切换间隔=${MIN_SWITCH_INTERVAL}s 连续确认=${CONFIRM_COUNT}"
log_print "节点: 类型=${NODE_KIND} 路径=${NODE_PATH} 默认值=${NODE_DEFAULT}"
log_print "电量: 读取自 ${CAP_NODE}"
log_print "初始策略: 允许充电"

# ---------------- 主循环 ----------------
while true; do
  NOW=$(date +%s | tr -dc '0-9'); [ -n "$NOW" ] || NOW=0

  # 配置文件热重载
  mt=$(stat -c %Y "$CONF_FILE" 2>/dev/null | tr -dc '0-9')
  if [ -n "$mt" ] && [ "$mt" != "$CONF_MTIME" ]; then
    OU=$UPPER_LIMIT; OL=$LOWER_LIMIT; OP=$POLL_INTERVAL
    CONF_MTIME=$mt
    load_conf
    log_print "配置热重载: 上限 ${OU}%->${UPPER_LIMIT}% 下限 ${OL}%->${LOWER_LIMIT}% 轮询 ${OP}s->${POLL_INTERVAL}s"
  fi

  if [ "$ENABLED" != "1" ]; then
    if [ "$WARNED_DISABLED" = "0" ]; then
      log_print "总开关 ENABLED=0，当前只记录日志不控制充电"
      WARNED_DISABLED=1
    fi
    sleep "$POLL_INTERVAL"
    continue
  fi
  WARNED_DISABLED=0

  CAP=$(read_capacity)
  ST=$(read_batt_status)
  PLUGGED=$(detect_plugged)

  # 1) 充电器判定
  #    关键：写入停充节点后，三星驱动会把 charging_type 上报为 NONE（伪装成没插充电器）。
  #    若据此判定"已拔掉"就会立刻恢复充电 -> 又检测到充电器 -> 再停充，形成 30 秒自激振荡。
  #    因此：停充状态下读不到充电证据时，一律视为"充电器还插着"。
  RAW=$(detect_plugged)
  if [ "$RAW" = "1" ]; then
    if [ "$STATE" = "1" ]; then
      # 停充状态下又看到充电器：说明刚被插上，或节点被内核复位。开启新的充电会话
      charge_on
      STATE=0
      LAST_SWITCH=$((NOW - MIN_SWITCH_INTERVAL))
      log_print "充电器已连接 | 电量=${CAP}% 新充电会话：先恢复默认充电行为，再按阈值重新判定"
    else
      if [ "$PREV_RAW" != "1" ]; then
        log_print "充电器已连接 | 电量=${CAP}% 当前策略=允许充电"
      fi
    fi
    PLUGGED=1
  else
    if [ "$STATE" = "0" ]; then
      if [ "$PREV_RAW" = "1" ]; then
        log_print "充电器已断开 | 电量=${CAP}% 当前策略=允许充电"
      fi
      PLUGGED=0
    else
      # 停充中读不到证据，是自身控制造成的，不能当作拔掉
      PLUGGED=1
    fi
  fi
  PREV_RAW=$RAW

  # 2) 滞回判定（带连续确认计数）
  if [ "$STATE" = "0" ]; then
    if [ "$CAP" -ge "$UPPER_LIMIT" ] && [ "$PLUGGED" = "1" ]; then
      CONFIRM=$((CONFIRM + 1))
    else
      CONFIRM=0
    fi
  else
    if [ "$CAP" -le "$LOWER_LIMIT" ]; then
      CONFIRM=$((CONFIRM + 1))
    else
      CONFIRM=0
    fi
  fi

  # 3) 满足确认次数且已过最小切换间隔 -> 执行切换
  if [ "$CONFIRM" -ge "$CONFIRM_COUNT" ] && [ $((NOW - LAST_SWITCH)) -ge "$MIN_SWITCH_INTERVAL" ]; then
    if [ "$STATE" = "0" ]; then
      charge_off
      STATE=1
      log_print "状态切换: 允许充电 -> 停止充电 | 电量=${CAP}% (>=上限${UPPER_LIMIT}%) 充电器=已连接 电池状态=${ST} 写入[${NODE_PATH}]=${LAST_WRITE} 距上次切换=$((NOW - LAST_SWITCH))s"
    else
      charge_on
      STATE=0
      if [ "$PLUGGED" = "1" ]; then
        log_print "状态切换: 停止充电 -> 允许充电 | 电量=${CAP}% (<=下限${LOWER_LIMIT}%) 充电器=已连接 电池状态=${ST} 写入[${NODE_PATH}]=${LAST_WRITE} 距上次切换=$((NOW - LAST_SWITCH))s"
      else
        log_print "状态切换: 停止充电 -> 允许充电 | 电量=${CAP}% (<=下限${LOWER_LIMIT}%) 充电器=未连接 电池状态=${ST} 写入[${NODE_PATH}]=${LAST_WRITE} 距上次切换=$((NOW - LAST_SWITCH))s"
      fi
    fi
    CONFIRM=0
    LAST_SWITCH=$NOW
    LAST_REASSERT=$NOW
  fi

  # 4) 定期重断言（部分内核会自行复位节点）
  if [ $((NOW - LAST_REASSERT)) -ge "$REASSERT_SEC" ] && [ "$NODE_KIND" != "none" ]; then
    if [ "$STATE" = "1" ]; then
      charge_off
    else
      charge_on
    fi
    LAST_REASSERT=$NOW
  fi

  # 5) 心跳 + 日志滚动
  CYCLE=$((CYCLE + 1))
  if [ "$CYCLE" -ge "$LOG_HEARTBEAT" ]; then
    CYCLE=0
    if [ "$STATE" = "1" ]; then
      POL="停止充电"
    else
      POL="允许充电"
    fi
    if [ "$PLUGGED" = "1" ]; then
      PLG="已连接"
    else
      PLG="未连接"
    fi
    log_print "心跳: 电量=${CAP}% 电池状态=${ST} 充电器=${PLG} 当前策略=${POL} 节点值=$(node_read "$NODE_PATH" 2>/dev/null)"
    log_rotate
  fi

  sleep "$POLL_INTERVAL"
done
