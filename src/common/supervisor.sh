#!/system/bin/sh
# Battery Guard - 守护循环
# 负责在守护进程异常退出后自动拉起；自身也有单实例保护
# 由 service.sh 在开机完成后后台启动

. "$(dirname "$0")/lib.sh"
load_conf

SLOCK=$PERSIST_DIR/.slock
SPID_FILE=$PERSIST_DIR/supervisor.pid

OWN_SLOCK=0
if mkdir "$SLOCK" 2>/dev/null; then
  OWN_SLOCK=1
  echo $$ > "$SPID_FILE"
else
  old=$(cat "$SPID_FILE" 2>/dev/null | tr -dc '0-9')
  # 必须确认该 PID 确实是本模块的守护循环，否则视为跨重启残留
  if [ -n "$old" ] && [ -d "/proc/$old" ] && \
     tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q "supervisor.sh"; then
    log_print "守护循环已在运行 (PID=$old)，本次不重复启动"
    exit 0
  fi
  rm -rf "$SLOCK" 2>/dev/null
  if mkdir "$SLOCK" 2>/dev/null; then
    OWN_SLOCK=1
    echo $$ > "$SPID_FILE"
  fi
fi
if [ "$OWN_SLOCK" != "1" ]; then
  log_print "无法获取守护循环锁，退出"
  exit 1
fi

sv_cleanup() {
  if [ "$OWN_SLOCK" = "1" ]; then
    log_print "守护循环退出(PID=$$)"
    rm -f "$SPID_FILE" 2>/dev/null
    rm -rf "$SLOCK" 2>/dev/null
    OWN_SLOCK=0
  fi
}
trap sv_cleanup EXIT
trap 'sv_cleanup; exit 0' TERM INT HUP

log_print "守护循环启动 PID=$$（重启延时 ${RESTART_DELAY}s）"

while true; do
  /system/bin/sh "$MODDIR/common/$DAEMON_SCRIPT"
  log_print "守护进程已退出，${RESTART_DELAY}s 后自动重启"
  sleep "$RESTART_DELAY"
done
