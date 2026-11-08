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
# 只监听回环地址，不对外暴露；启动后按固定存活时长（WEBUI_TTL，默认 5 分钟）自动关闭。
# 注意：计时从「启动那一刻」起算，页面是否在取数都不影响——不做续命，到点就关。

. "$(dirname "$0")/lib.sh"
load_conf

PORT=${WEBUI_PORT:-8654}
PIDF=$PERSIST_DIR/webui.pid
PORTF=$PERSIST_DIR/webui.port
ALIVEF=$PERSIST_DIR/webui.alive
DEADLINEF=$PERSIST_DIR/webui.deadline
WDF=$PERSIST_DIR/webui.wd
WEBROOT=$MODDIR/webroot
# 看门狗的检查粒度（秒）：只影响关闭时刻的精度，不影响总时长
TICK=15

# 存活时长（秒）：0 或非法值 → 0 表示常驻
ttl_seconds() {
  t=${WEBUI_TTL:-300}
  case "$t" in ''|*[!0-9]*) t=300 ;; esac
  [ "$t" -gt 0 ] 2>/dev/null && echo "$t" || echo 0
}

# 把「启动时刻 + 存活时长」写成绝对截止时间：看门狗只看这个数，不看页面活动
set_deadline() {
  t=$(ttl_seconds)
  if [ "$t" -gt 0 ]; then
    echo $(( $(date +%s) + t )) > "$DEADLINEF" 2>/dev/null
  else
    rm -f "$DEADLINEF" 2>/dev/null
  fi
}

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

# 按「端口 + webroot」反查 httpd 进程：开机阶段 ps 可能还没列出刚 fork 的进程，
# 用它在抓不到 PID 时兜底、并在有实例无 PID 文件时接管，避免重复起第二个 httpd
find_httpd() {
  ps -A -o PID,ARGS 2>/dev/null | grep -F "httpd -f -p 127.0.0.1:$1" | \
    grep -F "$WEBROOT" | head -n 1 | awk '{print $1}'
}

# 存活看门狗：到 DEADLINEF 记录的时刻就关掉自己这一代实例，与页面有无活动无关。
# TTL=0 表示常驻，不装看门狗。
#
# 必须用「独立进程」拉起（sh webui.sh __watchdog），不能在当前 shell 里 fork 子 shell：
# mksh 为恢复重定向会在 fd 10+ 保存原 stdout 的副本，那份副本会一直攥着调用方的管道，
# 导致 $(webui.sh start) 这种命令替换被拖住整整一个存活周期才返回。
watchdog_start() {
  wd_target=$1
  [ "$(ttl_seconds)" -gt 0 ] || return 0
  old=$(cat "$WDF" 2>/dev/null | tr -dc '0-9')
  [ -n "$old" ] && kill -9 "$old" 2>/dev/null
  setsid sh "$MODDIR/common/webui.sh" __watchdog "$wd_target" >/dev/null 2>&1 < /dev/null &
  return 0
}

# 看门狗主体（独立进程内运行，自己写 PID 文件）
do_watchdog() {
  wd_target=$1
  [ -n "$wd_target" ] || return 1
  ttl=$(ttl_seconds)
  [ "$ttl" -gt 0 ] || return 0
  echo $$ > "$WDF" 2>/dev/null
  while :; do
    sleep "$TICK"
    # 实例已被 stop 或换成新一代：本看门狗使命结束，交给新的那个
    cur=$(cat "$PIDF" 2>/dev/null | tr -dc '0-9')
    [ "$cur" = "$wd_target" ] || return 0
    [ -d "/proc/$wd_target" ] || return 0
    dl=$(cat "$DEADLINEF" 2>/dev/null | tr -dc '0-9')
    now=$(date +%s 2>/dev/null | tr -dc '0-9')
    if [ -z "$dl" ] || [ -z "$now" ]; then
      return 0
    fi
    [ "$now" -ge "$dl" ] || continue
    log_print "面板存活 ${ttl}s 到点（启动于 $((dl - ttl))，最近活动 $(cat "$ALIVEF" 2>/dev/null | tr -dc '0-9')）：关闭 httpd PID=$wd_target"
    sh "$MODDIR/common/webui.sh" stop >/dev/null 2>&1
    return 0
  done
}

do_start() {
  BB=$(find_bb) || { echo ""; return 1; }
  [ -d "$WEBROOT" ] || { echo ""; return 1; }

  if alive_pid >/dev/null 2>&1; then
    # 已在运行：把计时重新从此刻开始（只有显式 start/点「操作」会重置，页面取数不会）
    date +%s > "$ALIVEF" 2>/dev/null
    set_deadline
    watchdog_start "$(alive_pid)"
    cat "$PORTF" 2>/dev/null | tr -dc '0-9'
    return 0
  fi
  rm -f "$PIDF" "$PORTF" 2>/dev/null

  # 已有实例在跑（例如开机时 PID 文件没写成）：直接接管，不要再起一个
  hp=$(find_httpd "$PORT")
  if [ -n "$hp" ] && [ -d "/proc/$hp" ]; then
    echo "$hp" > "$PIDF"
    echo "$PORT" > "$PORTF"
    date +%s > "$ALIVEF" 2>/dev/null
    set_deadline
    watchdog_start "$hp"
    echo "$PORT"
    return 0
  fi

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
  # 开机阶段 httpd 拉起可能要 1s 以上，重试几次再判失败（最多约 5s）
  hp=""
  i=0
  while [ "$i" -lt 5 ]; do
    hp=$(find_httpd "$p")
    [ -n "$hp" ] && [ -d "/proc/$hp" ] && break
    hp=""
    sleep 1
    i=$((i + 1))
  done
  if [ -z "$hp" ]; then
    echo ""
    return 1
  fi
  echo "$hp" > "$PIDF"
  echo "$p" > "$PORTF"
  # 记下启动时刻（仅用于日志展示），并把截止时间定为「此刻 + TTL」
  date +%s > "$ALIVEF" 2>/dev/null
  set_deadline
  watchdog_start "$hp"

  echo "$p"
  return 0
}

do_stop() {
  # 先收看门狗，否则它会在 httpd 被杀后误判「实例不见了」再多跑一轮
  wd=$(cat "$WDF" 2>/dev/null | tr -dc '0-9')
  [ -n "$wd" ] && kill -9 "$wd" 2>/dev/null
  if p=$(alive_pid); then
    kill -9 "$p" 2>/dev/null
  fi
  # 兜底：一次 ps 扫出所有指向本模块 webroot 的 httpd（比逐进程 fork 快两个数量级）
  ps -A -o PID,ARGS 2>/dev/null | grep -F "$WEBROOT" | grep -F httpd | \
    awk '{print $1}' | while read -r pid; do
      [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    done
  rm -f "$PIDF" "$PORTF" "$ALIVEF" "$DEADLINEF" "$WDF" 2>/dev/null
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
  __watchdog) do_watchdog "$2" ;;   # 内部用：由 watchdog_start 以独立进程拉起
  *)       echo "用法: $0 start|stop|restart|status|url|open"; exit 1 ;;
esac
