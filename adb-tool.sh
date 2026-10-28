#!/usr/bin/env bash
# ============================================================
#  Battery Guard - 电脑端一键无线安装 / 调试助手
#  在 Git Bash / WSL / Linux / macOS 上执行（需要 adb 在 PATH 中）
#
#  用法：
#    ./adb-tool.sh                     连接设备 -> 推送 -> 安装 -> 重启
#    ./adb-tool.sh install             同上，但不重启
#    ./adb-tool.sh log                 实时查看模块日志
#    ./adb-tool.sh status              查看电量 / 节点 / 守护状态
#    ./adb-tool.sh probe               重新执行一次节点探测
#    ./adb-tool.sh switch              查看所有状态切换记录
#    ./adb-tool.sh set 85 45           把上限改成 85%、下限改成 45%
#    ./adb-tool.sh 192.168.1.20:5555   指定其它设备地址
# ============================================================

set -u

# Git Bash / MSYS 会把 /sdcard/... 这类参数当成宿主机路径转换掉，必须关闭
export MSYS_NO_PATHCONV=1

DEFAULT_DEVICE="192.168.8.176:5555"
ZIP="BatteryGuard-v1.0.zip"
ZIP_DIR=$(cd "$(dirname "$0")" && pwd)
LOG="/data/adb/battery-guard/battery-guard.log"
CONF="/data/adb/battery-guard/battery-guard.conf"
MODDIR="/data/adb/modules/battery_guard"

DEVICE="$DEFAULT_DEVICE"
CMD="install-reboot"

for a in "$@"; do
  case "$a" in
    *:*)          DEVICE="$a" ;;
    install|log|status|probe|switch|set|uninstall|purge|restart) CMD="$a" ;;
  esac
done

if ! command -v adb >/dev/null 2>&1; then
  echo "错误: 未找到 adb，请先安装 platform-tools 并加入 PATH"
  exit 1
fi

echo "==> 连接设备 $DEVICE"
adb connect "$DEVICE" >/dev/null
if ! adb -s "$DEVICE" shell true >/dev/null 2>&1; then
  echo "错误: 无法通过 adb 访问 $DEVICE"
  echo "     请确认：开发者选项 → 无线调试 已开启，且已允许本机调试（adb devices 不显示 unauthorized）"
  exit 1
fi
echo "    已连接: $(adb -s "$DEVICE" shell getprop ro.product.model | tr -d '\r')"

if ! adb -s "$DEVICE" shell su -c "id" 2>/dev/null | grep -q "uid=0"; then
  echo "错误: 无法获取 root 权限（su 不可用或未授予）"
  exit 1
fi
echo "    root 权限: OK"

A="adb -s $DEVICE shell"

case "$CMD" in
  install-reboot|install)
    echo "==> 推送安装包"
    adb -s "$DEVICE" push "$ZIP_DIR/$ZIP" /sdcard/Download/ >/dev/null
    echo "==> 安装模块"
    OUT=$($A su -c "magisk --install-module /sdcard/Download/$ZIP" 2>&1)
    if echo "$OUT" | grep -qi "not found\|not exist"; then
      OUT=$($A su -c "/data/adb/magisk/magisk --install-module /sdcard/Download/$ZIP" 2>&1)
    fi
    echo "$OUT" | sed 's/^/    /'
    if [ "$CMD" = "install-reboot" ]; then
      echo "==> 重启设备"
      $A su -c reboot
      echo "==> 等待重启完成..."
      adb -s "$DEVICE" wait-for-device
      sleep 25
      echo "==> 重启后的日志："
      $A su -c "cat $LOG" 2>&1 | tail -n 25 | sed 's/^/    /'
    else
      echo "    安装完成，请手动重启：adb -s $DEVICE shell su -c reboot"
    fi
    ;;
  log)
    echo "==> 实时日志（Ctrl+C 退出）"
    $A su -c "tail -f $LOG"
    ;;
  status)
    echo "==> 当前状态"
    $A su -c "cat /sys/class/power_supply/battery/capacity" | tr -d '\r' | sed 's/^/    电量: /'
    $A su -c "cat /sys/class/power_supply/battery/status"   | tr -d '\r' | sed 's/^/    电池状态: /'
    $A su -c "cat /data/adb/battery-guard/nodes.conf"       | tr -d '\r' | sed 's/^/    节点: /'
    $A su -c "cat /data/adb/battery-guard/daemon.pid"       | tr -d '\r' | sed 's/^/    守护PID: /'
    echo "==> 最近日志"
    $A su -c "tail -n 20 $LOG" 2>&1 | sed 's/^/    /'
    ;;
  restart)
    echo "==> 重启守护进程（用最新的脚本与配置）"
    $A su -c "for p in /proc/[0-9]*; do c=\$(tr '\0' ' ' < \$p/cmdline 2>/dev/null); case \"\$c\" in *supervisor.sh*|*battery-guard-daemon.sh*) kill -9 \${p#/proc/};; esac; done" 2>&1 | sed 's/^/    /'
    sleep 2
    $A su -c "rm -rf /data/adb/battery-guard/.lock /data/adb/battery-guard/.slock /data/adb/battery-guard/daemon.pid /data/adb/battery-guard/supervisor.pid" >/dev/null 2>&1
    $A su -c "magisk --install-module /sdcard/Download/$ZIP" 2>&1 | grep -E "守护|Done" | sed 's/^/    /'
    ;;
  probe)
    echo "==> 重新探测节点"
    $A su -c "sh $MODDIR/common/probe.sh" 2>&1 | sed 's/^/    /'
    ;;
  switch)
    echo "==> 状态切换记录"
    $A su -c "grep 状态切换 $LOG" 2>&1 | sed 's/^/    /'
    ;;
  set)
    U=${2:-80}; L=${3:-40}
    echo "==> 设置上限 ${U}% 下限 ${L}%（热生效，无需重启）"
    $A su -c "sed -i -e 's/^UPPER_LIMIT=.*/UPPER_LIMIT=$U/' -e 's/^LOWER_LIMIT=.*/LOWER_LIMIT=$L/' $CONF"
    ;;
  uninstall)
    echo "==> 先执行卸载清理（立即恢复系统默认充电行为）"
    $A su -c "sh $MODDIR/uninstall.sh" 2>&1 | sed 's/^/    /'
    echo "==> 标记为待移除（Magisk 标准流程，重启后模块彻底消失）"
    $A su -c "touch $MODDIR/remove" >/dev/null 2>&1
    $A su -c "rm -rf /data/adb/modules_update/battery_guard" >/dev/null 2>&1
    echo "    已恢复充电。重启后模块将从 Magisk 中消失。"
    echo "    （不想重启也想立即移除：adb shell su -c \"rm -rf $MODDIR\"）"
    ;;
  purge)
    echo "==> 连同配置与日志一并删除"
    $A su -c "sh $MODDIR/uninstall.sh" 2>&1 | sed 's/^/    /'
    $A su -c "touch $MODDIR/remove" >/dev/null 2>&1
    $A su -c "rm -rf /data/adb/battery-guard /data/adb/modules_update/battery_guard" >/dev/null 2>&1
    echo "    配置、日志、节点记录已全部清除，重启后模块消失"
    ;;
esac
