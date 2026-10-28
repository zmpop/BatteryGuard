#!/system/bin/sh
# Battery Guard - late_start service 阶段（开机完成后）
# 职责：等待开机完成 -> 确保节点已探测 -> 后台常驻拉起守护进程

[ -n "$MODDIR" ] || MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -f "$MODDIR/common/lib.sh" ] || MODDIR=/data/adb/modules/battery_guard
. "$MODDIR/common/lib.sh"

load_conf

# 1) 等待系统真正启动完成（最长 180s）
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 180 ]; do
  sleep 2
  i=$((i + 2))
done

# 2) 兜底：若 post-fs-data 阶段没能完成探测，这里补一次
[ -f "$NODES_FILE" ] || sh "$MODDIR/common/probe.sh" >/dev/null 2>&1

# 3) 后台常驻启动（守护循环内部有单实例保护，重复调用安全）
if [ "$ENABLED" != "1" ]; then
  log_print "service.sh: 总开关 ENABLED=0，不启动守护进程"
  exit 0
fi

log_print "service.sh: 开机完成（等待 ${i}s），启动守护循环"
/system/bin/sh "$MODDIR/common/supervisor.sh" >/dev/null 2>&1 &

exit 0
