#!/system/bin/sh
# Battery Guard - post-fs-data 阶段（开机早期）
# 职责：自动探测当前设备可用的充电控制节点并写入 nodes.conf
#       （可选）如 EARLY_START=1，则在开机动画阶段就拉起守护进程

[ -n "$MODDIR" ] || MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -f "$MODDIR/common/lib.sh" ] || MODDIR=/data/adb/modules/battery_guard
. "$MODDIR/common/lib.sh"

load_conf

# 开机早期先清掉跨重启残留的锁，否则守护循环会误判为"已在运行"
clear_stale_locks

# 开机早期：先完成节点探测，结果供后续守护进程使用
sh "$MODDIR/common/probe.sh" >/dev/null 2>&1

# 探测过程会做写测试，这里把结果清扫一遍，避免任何节点停留在"停充"值
reset_all_nodes

if [ "$EARLY_START" = "1" ]; then
  if [ "$ENABLED" = "1" ]; then
    log_print "post-fs-data: EARLY_START=1，提前启动守护循环"
    /system/bin/sh "$MODDIR/common/supervisor.sh" >/dev/null 2>&1 &
  fi
fi

exit 0
