#!/system/bin/sh
# Battery Guard - 卸载清理
# 由 Magisk 在移除模块时执行。
# 本脚本保持"自包含"，不依赖 common/lib.sh，
# 以避免模块目录已被删除时无法完成复位。

umask 022
export PATH=/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:/sbin:$PATH

MODDIR=${MODDIR:-}
[ -n "$MODDIR" ] || MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/battery_guard

PERSIST_DIR=/data/adb/battery-guard
CONF_FILE=$PERSIST_DIR/battery-guard.conf
LOG_FILE=$PERSIST_DIR/battery-guard.log
NODES_FILE=$PERSIST_DIR/nodes.conf

echo "***********************************************"
echo "  Battery Guard 卸载清理"
echo "***********************************************"

# 0. 读取配置（current_limit 类型需要用到默认值）
[ -f "$CONF_FILE" ] && eval "$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$CONF_FILE" 2>/dev/null)"

# 1. 停止进程：先杀守护循环，防止它把守护进程重新拉起
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  [ -r "$p/cmdline" ] || continue
  cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$cmd" in
    *supervisor.sh*) kill -9 "$pid" 2>/dev/null ;;
  esac
done
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  [ -r "$p/cmdline" ] || continue
  cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$cmd" in
    *battery-guard-daemon.sh*) kill -9 "$pid" 2>/dev/null ;;
  esac
done
echo "  [1/4] 守护进程已停止"

# 2. 复位被选中的节点
if [ -f "$NODES_FILE" ]; then
  line=$(grep -v '^[[:space:]]*#' "$NODES_FILE" 2>/dev/null | head -n 1)
  set -- $line
  case "$1" in
    direct)        echo 1 > "$2" 2>/dev/null && echo "  [2/4] 复位正向节点 $2 = 1" ;;
    invert)        echo 0 > "$2" 2>/dev/null && echo "  [2/4] 复位反向节点 $2 = 0" ;;
    current_limit) [ -n "$3" ] && echo "$3" > "$2" 2>/dev/null && echo "  [2/4] 复位限流节点 $2 = $3" ;;
    *)             echo "  [2/4] 无有效节点记录，跳过" ;;
  esac
else
  echo "  [2/4] 无节点记录文件，跳过"
fi

# 3. 清扫所有候选节点，确保没有任何残留的停充状态
for p in /sys/class/power_supply/battery/charging_enabled \
         /sys/class/power_supply/battery/battery_charging_enabled \
         /sys/class/power_supply/battery/charge_enabled \
         /sys/class/power_supply/battery/charger_enabled \
         /sys/class/power_supply/battery/charging_switch \
         /sys/class/power_supply/battery/charger_enable; do
  if [ -w "$p" ]; then echo 1 > "$p" 2>/dev/null && echo "  [3/4] 清扫正向节点 $p = 1"; fi
done
for p in /sys/class/power_supply/battery/input_suspend \
         /sys/class/sec/battery/input_suspend \
         /sys/class/power_supply/battery/charge_suspend \
         /sys/class/power_supply/battery/batt_slate_mode \
         /sys/class/sec/battery/batt_slate_mode \
         /sys/class/power_supply/battery/slate_mode; do
  if [ -w "$p" ]; then echo 0 > "$p" 2>/dev/null && echo "  [3/4] 清扫反向节点 $p = 0"; fi
done
# 注1：batt_charging_source 是充电来源上报位，不参与清扫
# 注2：store_mode 是"单向开关"（写入任何值包括 0 都会变成 1），不能靠写 0 复位，
#      否则卸载完反而插电不充电。这里只检测不写入，卡住时靠重启清除
#      （Magisk 移除模块本身就会重启，届时自然恢复）。
for p in /sys/class/power_supply/battery/store_mode \
         /sys/class/sec/battery/store_mode; do
  if [ -r "$p" ]; then
    v=$(cat "$p" 2>/dev/null | tr -d '\r\n')
    if [ "$v" = "1" ]; then
      echo "  [3/4] 单向节点 $p = 1，重启后自动清除（本次卸载会重启，无需额外处理）"
    fi
  fi
done

# 4. 清理锁与 PID（保留配置与日志，方便重新安装后继续使用）
rm -rf "$PERSIST_DIR/.lock" 2>/dev/null
rm -rf "$PERSIST_DIR/.slock" 2>/dev/null
rm -f "$PERSIST_DIR/daemon.pid" 2>/dev/null
rm -f "$PERSIST_DIR/supervisor.pid" 2>/dev/null
rm -f "$NODES_FILE" 2>/dev/null
rm -f "$PERSIST_DIR/safe_nodes.conf" 2>/dev/null
echo "  [4/4] 锁与节点记录已清理"

echo "  系统默认充电行为已恢复"
echo "  （配置与日志保留在 $PERSIST_DIR ，可手动删除）"
echo "***********************************************"

ts=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$ts] 模块已卸载，充电行为恢复为系统默认" >> "$LOG_FILE" 2>/dev/null

exit 0
