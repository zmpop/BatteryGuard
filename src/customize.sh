#!/system/bin/sh
# Battery Guard - 安装定制脚本
# 由 Magisk 安装器 source 执行（可用变量：MODPATH / ZIPFILE / API / ARCH / ui_print）
# 注意：本脚本会被"source"，内部不要使用 exit

[ -n "$MODPATH" ] || MODPATH=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
. "$MODPATH/common/lib.sh"
MODDIR="$MODPATH"

ensure_conf
load_conf

# 修正权限（不同打包工具提取后的权限可能不一致）
chmod 0755 "$MODPATH/common/lib.sh" \
           "$MODPATH/common/probe.sh" \
           "$MODPATH/common/supervisor.sh" \
           "$MODPATH/common/battery-guard-daemon.sh" 2>/dev/null
chmod 0755 "$MODPATH/service.sh" \
           "$MODPATH/post-fs-data.sh" \
           "$MODPATH/uninstall.sh" \
           "$MODPATH/action.sh" \
           "$MODPATH/customize.sh" 2>/dev/null
chmod 0644 "$MODPATH/module.prop" \
           "$MODPATH/README.md" \
           "$MODPATH/common/battery-guard.conf" 2>/dev/null
chmod 0755 "$MODPATH/common" 2>/dev/null
chmod 0755 "$PERSIST_DIR" 2>/dev/null
chmod 0644 "$CONF_FILE" 2>/dev/null

ui_print "***************************************"
ui_print "  Battery Guard v1.0 - 充电阈值守护"
ui_print "***************************************"
ui_print "- 设备   : $(getprop ro.product.manufacturer) $(getprop ro.product.model)"
ui_print "- 系统   : Android $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
ui_print "- 配置   : $CONF_FILE"
ui_print "- 日志   : $LOG_FILE"
ui_print "- 默认策略: 上限 ${UPPER_LIMIT}% / 下限 ${LOWER_LIMIT}% / 轮询 ${POLL_INTERVAL}s"
ui_print "- 正在探测充电控制节点 ..."

out=$(sh "$MODPATH/common/probe.sh" 2>/dev/null)
if [ -n "$out" ]; then
  echo "$out" | while IFS= read -r l; do
    [ -n "$l" ] && ui_print "$l"
  done
else
  ui_print "  ! 探测脚本无输出，请安装后手动执行 probe.sh 查看日志"
fi

# 清理残锁后直接拉起守护进程，安装完立即生效，无需重启
clear_stale_locks
if [ "$ENABLED" = "1" ]; then
  /system/bin/sh "$MODPATH/common/supervisor.sh" >/dev/null 2>&1 &
  ui_print "- 守护进程已启动，立即生效（无需重启）"
fi

ui_print "- 点击模块的「执行」按钮可随时查看状态"
ui_print "***************************************"
