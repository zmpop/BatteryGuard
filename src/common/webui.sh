#!/system/bin/sh
# Battery Guard - 本地控制面板（WebUI）服务管理
# 用法：
#   sh webui.sh start    启动服务，成功则输出端口号（失败输出空）
#   sh webui.sh stop     停止服务
#   sh webui.sh restart  重启
#   sh webui.sh status   输出 "PID 端口" 或空
#   sh webui.sh url      输出面板地址
#   sh webui.sh open     用系统浏览器打开面板
#
# 实现方式：busybox httpd（Magisk 自带）在 127.0.0.1 上提供静态页 + /cgi-bin 接口，
# 只监听回环地址，不对外暴露；空闲超时后自动关闭。

. "$(dirname "$0")/lib.sh"
load_conf

PORT=${WEBUI_PORT:-8654}
IDLE=${WEBUI_IDLE_TIMEOUT:-1800}
PIDF=$PERSIST_DIR/webui.pid
PORTF=$PERSIST_DIR/webui.port
WEBROOT=$MODDIR/webroot

find_bb() {
  for b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    [ -x "$b" ] && { echo "$b"; return 0; }
  done
  b=$(command -v busybox 2>/dev/null)
  [ -n "$b" ] && { echo "$b"; return 0; }
  return 1
}

# 端口是否已被监听（查 /proc/net/tcp 的 0A=LISTEN，避免逐进程 fork）
port_listening() {
  hex=$(printf '%04X' "$1" 2>/dev/null)
  [ -n "$hex" ] || return 1
  awk -v pat=":$hex" '$4 == "0A" && index($2, pat) > 0 { found = 1 } END { exit !found }' \
    /proc/net/tcp 2>/dev/null
}

alive_pid() {
  p=$(cat "$PIDF" 2>/dev/null | tr -dc '0-9')
  [ -n "$p" ] || return 1
  [ -d "/proc/$p" ] || return 1
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q httpd || return 1
  echo "$p"
}

do_start() {
  BB=$(find_bb) || { echo ""; return 1; }
  [ -d "$WEBROOT" ] || { echo ""; return 1; }

  if alive_pid >/dev/null 2>&1; then
    cat "$PORTF" 2>/dev/null | tr -dc '0-9'
    return 0
  fi
  rm -f "$PIDF" "$PORTF" 2>/dev/null

  # 选一个空闲端口：默认 8654，被占用就 +1（最多试 8 个）
  p=$PORT
  i=0
  while [ "$i" -lt 8 ] && port_listening "$p"; do
    p=$((p + 1))
    i=$((i + 1))
  done

  # setsid + 断开三个标准流：否则后台 httpd 会拖住调用方（action.sh 的命令替换会一直挂着）
  setsid "$BB" httpd -f -p 127.0.0.1:$p -h "$WEBROOT" >/dev/null 2>&1 < /dev/null &
  sleep 1

  # 用 PID 文件反查更可靠（setsid 后 $! 不一定是 httpd 本身）
  hp=$(ps -A -o PID,ARGS 2>/dev/null | grep -F "httpd -f -p 127.0.0.1:$p" | grep -F "$WEBROOT" | head -n 1 | awk '{print $1}')
  if [ -z "$hp" ] || [ ! -d "/proc/$hp" ]; then
    echo ""
    return 1
  fi
  echo "$hp" > "$PIDF"
  echo "$p" > "$PORTF"

  # 空闲超时自动关闭（只关自己这一代，避免误杀后启动的新实例）
  ( sleep "$IDLE"
    cur=$(cat "$PIDF" 2>/dev/null | tr -dc '0-9')
    [ "$cur" = "$hp" ] && sh "$MODDIR/common/webui.sh" stop >/dev/null 2>&1
  ) >/dev/null 2>&1 < /dev/null &

  echo "$p"
  return 0
}

do_stop() {
  if p=$(alive_pid); then
    kill -9 "$p" 2>/dev/null
  fi
  # 兜底：一次 ps 扫出所有指向本模块 webroot 的 httpd（比逐进程 fork 快两个数量级）
  ps -A -o PID,ARGS 2>/dev/null | grep -F "$WEBROOT" | grep -F httpd | \
    awk '{print $1}' | while read -r pid; do
      [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    done
  rm -f "$PIDF" "$PORTF" 2>/dev/null
  return 0
}

do_url() {
  p=$(cat "$PORTF" 2>/dev/null | tr -dc '0-9')
  echo "http://127.0.0.1:${p:-$PORT}/"
}

do_open() {
  u=$(do_url)
  out=$(am start -a android.intent.action.VIEW -d "$u" --user 0 2>&1)
  case "$out" in
    *Error*|*error*|*Exception*|*Failure*|*"not found"*)
      am start -n com.sec.android.app.sbrowser/.BrowserActivity -d "$u" --user 0 \
        >/dev/null 2>&1 && return 0
      return 1
      ;;
    *) return 0 ;;
  esac
}

case "${1:-start}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; sleep 1; do_start ;;
  status)  p=$(alive_pid) && echo "$p $(cat "$PORTF" 2>/dev/null | tr -dc '0-9')" ;;
  url)     do_url ;;
  open)    do_open ;;
  *)       echo "用法: $0 start|stop|restart|status|url|open"; exit 1 ;;
esac
