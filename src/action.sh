#!/system/bin/sh
# Battery Guard - Magisk 模块按钮（Action）
# 在 Magisk App 的模块卡片上点击"执行"按钮后显示当前状态与最近日志

[ -n "$MODDIR" ] || MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -f "$MODDIR/common/lib.sh" ] || MODDIR=/data/adb/modules/battery_guard
. "$MODDIR/common/lib.sh"

load_conf
load_node
CAP_NODE=$(find_cap_node)

CAP=$(read_capacity)
ST=$(read_batt_status)
PLUGGED=$(detect_plugged)
[ "$PLUGGED" = "1" ] && PLG="已连接" || PLG="未连接"

echo "[ Battery Guard v1.0 ]"
echo ""
echo "电量     : ${CAP}%   (${ST})"
echo "充电器   : ${PLG}"
echo "策略     : 上限 ${UPPER_LIMIT}% / 下限 ${LOWER_LIMIT}% / 轮询 ${POLL_INTERVAL}s"
echo "总开关   : $([ "$ENABLED" = "1" ] && echo 已启用 || echo 已关闭)"
echo ""
echo "控制节点 : ${NODE_KIND}  ${NODE_PATH}"
echo "节点当前 : $(daemon_state_text) (节点值=$(node_read "$NODE_PATH"))"
echo ""
if pid=$(is_daemon_running); then
  echo "守护进程 : 运行中 (PID=$pid)"
else
  echo "守护进程 : 未运行"
fi
if spid=$(is_supervisor_running); then
  echo "守护循环 : 运行中 (PID=$spid)"
else
  echo "守护循环 : 未运行"
fi
echo ""
echo "配置     : $CONF_FILE"
echo "日志     : $LOG_FILE"
echo ""
echo "-------- 最近日志 --------"
if [ -f "$LOG_FILE" ]; then
  tail -n 15 "$LOG_FILE"
else
  echo "尚无日志"
fi
echo ""
echo "手动启停："
echo "  su -c 'sh $MODDIR/common/supervisor.sh &'"
echo "  su -c 'kill \$(cat $PID_FILE)'"

exit 0
