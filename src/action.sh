#!/system/bin/sh
# Battery Guard - Magisk 模块「操作」按钮
# 触发逻辑：
#   1) 拉起本地控制面板（busybox httpd 只监听 127.0.0.1）
#   2) 用系统浏览器打开面板，在里面拖动上下限并保存
#   3) 服务不可用时，退化为打印状态摘要

[ -n "$MODDIR" ] || MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -f "$MODDIR/common/lib.sh" ] || MODDIR=/data/adb/modules/battery_guard
. "$MODDIR/common/lib.sh"

load_conf
load_node
CAP_NODE=$(find_cap_node)

VER=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2)
[ -n "$VER" ] || VER="v?"
echo "[ Battery Guard $VER ]"
echo ""

# 启动面板服务：输出全部丢弃。后台 httpd 会继承 fd，若接到模块对话框的管道上
# 会让 Magisk 一直等不到 EOF（表现为点「操作」后卡住），因此这里不做命令替换。
if command -v timeout >/dev/null 2>&1; then
  timeout 10 sh "$MODDIR/common/webui.sh" start >/dev/null 2>&1
else
  sh "$MODDIR/common/webui.sh" start >/dev/null 2>&1
fi
PORT=$(cat "$PERSIST_DIR/webui.port" 2>/dev/null | tr -dc '0-9')

# 首次失败重试一次：开机后首次启动偶发 busybox 尚未就绪
if [ -z "$PORT" ]; then
  sleep 1
  sh "$MODDIR/common/webui.sh" start >/dev/null 2>&1
  PORT=$(cat "$PERSIST_DIR/webui.port" 2>/dev/null | tr -dc '0-9')
fi

if [ -n "$PORT" ]; then
  URL="http://127.0.0.1:$PORT/"
  echo "控制面板: $URL"
  if sh "$MODDIR/common/webui.sh" open >/dev/null 2>&1; then
    echo "已在浏览器中打开，可直接拖动滑块设置上下限"
  else
    echo "未能自动打开浏览器，请手动访问上面的地址"
  fi
  if [ "${WEBUI_IDLE_TIMEOUT:-0}" -gt 0 ] 2>/dev/null; then
    T=${WEBUI_IDLE_TIMEOUT}
    if [ $((T % 60)) -eq 0 ]; then
      echo "面板空闲 $((T / 60)) 分钟后自动关闭（重新点「操作」即可再次打开）"
    else
      echo "面板空闲 ${T}s 后自动关闭（重新点「操作」即可再次打开）"
    fi
  fi
  echo ""
else
  echo "控制面板未启动（缺少 busybox httpd 或端口不可用），以下为状态摘要"
  echo ""
fi

CAP=$(read_capacity)
ST=$(read_batt_status)
PLUGGED=$(detect_plugged)
[ "$PLUGGED" = "1" ] && PLG="已连接" || PLG="未连接"

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

exit 0
