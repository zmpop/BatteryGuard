#!/system/bin/sh
# Battery Guard - 控制面板数据接口（供 cgi-bin/* 与 WebUI 桥接调用）
# 约定：只输出结果，不输出 HTTP 头；被 cgi-bin 脚本引用时由脚本负责打印头部
#   api_state_json            打印一行 JSON：当前电量 / 策略 / 节点 / 守护状态
#   api_set <上限> <下限>      校验并写入配置，打印一行 JSON
#   api_log                   打印最近日志（纯文本）

# 被 cgi-bin 下的脚本引用时 $0 指向 cgi 脚本本身，需按模块目录兜底定位 lib.sh
_api_dir=$(dirname "$0")
[ -f "$_api_dir/lib.sh" ] || _api_dir=/data/adb/modules/battery_guard/common
[ -f "$_api_dir/lib.sh" ] || _api_dir=${MODDIR:+$MODDIR/common}
. "$_api_dir/lib.sh"

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

api_state_json() {
  # 页面每 3s 取一次状态：这里刷新活动时间，仅供日志展示——面板寿命由 webui.deadline 决定，
  # 页面取数不会延长（这是 v1.1.5 起的「固定存活」语义）
  webui_touch
  load_conf
  load_node
  # 面板剩余寿命：给页面底部显示倒计时用；未启用（TTL=0）或没在跑时给 0
  ttl=$(printf '%s' "${WEBUI_TTL:-0}" | tr -dc '0-9'); [ -n "$ttl" ] || ttl=0
  dl=$(cat "$PERSIST_DIR/webui.deadline" 2>/dev/null | tr -dc '0-9')
  now=$(date +%s 2>/dev/null | tr -dc '0-9')
  remain=0
  if [ "$ttl" -gt 0 ] 2>/dev/null && [ -n "$dl" ] && [ -n "$now" ]; then
    remain=$((dl - now))
    [ "$remain" -ge 0 ] || remain=0
  fi
  CAP_NODE=$(find_cap_node)
  cap=$(read_capacity)
  st=$(read_batt_status)
  pg=$(detect_plugged)
  state=$(daemon_state_text)
  if pid=$(is_daemon_running); then dpid=$pid; drun=true; else dpid=0; drun=false; fi
  case "$NODE_KIND" in
    invert) kdesc="反向(0充/1停)" ;;
    direct) kdesc="正向(1充/0停)" ;;
    current_limit) kdesc="限流" ;;
    *) kdesc="无" ;;
  esac
  printf '{"upper":%s,"lower":%s,"poll":%s,"minSwitch":%s,"cap":%s,"ttl":%s,"remain":%s,' \
    "$UPPER_LIMIT" "$LOWER_LIMIT" "$POLL_INTERVAL" "$MIN_SWITCH_INTERVAL" "$cap" "$ttl" "$remain"
  printf '"battery":"%s","plugged":%s,"state":"%s","kind":"%s","nodeDesc":"%s",' \
    "$(json_escape "$st")" "$pg" "$(json_escape "$state")" "$NODE_KIND" "$(json_escape "$kdesc")"
  printf '"node":"%s","enabled":%s,"daemon":%s,"pid":%s,"model":"%s"}\n' \
    "$(json_escape "$NODE_PATH")" \
    "$([ "$ENABLED" = "1" ] && echo true || echo false)" "$drun" "$dpid" \
    "$(json_escape "$(getprop ro.product.model)")"
}

api_set() {
  webui_touch
  load_conf
  u=$(printf '%s' "${1:-}" | tr -dc '0-9')
  l=$(printf '%s' "${2:-}" | tr -dc '0-9')

  if [ -z "$u" ] || [ -z "$l" ]; then
    printf '{"ok":false,"msg":"请同时提供上限与下限"}\n'
    return 1
  fi
  if [ "$u" -lt 20 ] || [ "$u" -gt 100 ]; then
    printf '{"ok":false,"msg":"上限需在 20-100 之间"}\n'
    return 1
  fi
  if [ "$l" -lt 5 ]; then
    printf '{"ok":false,"msg":"下限需不低于 5%%"}\n'
    return 1
  fi
  adjusted=false
  if [ "$l" -gt $((u - 5)) ]; then
    l=$((u - 5))
    adjusted=true
  fi

  [ -f "$CONF_FILE" ] || ensure_conf
  sed -i -e "s/^UPPER_LIMIT=.*/UPPER_LIMIT=$u/" -e "s/^LOWER_LIMIT=.*/LOWER_LIMIT=$l/" \
    "$CONF_FILE" 2>/dev/null
  # 校验写入结果，避免 sed 静默失败后 UI 显示成功
  nu=$(grep '^UPPER_LIMIT=' "$CONF_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2 | tr -dc '0-9')
  nl=$(grep '^LOWER_LIMIT=' "$CONF_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2 | tr -dc '0-9')
  if [ "$nu" != "$u" ] || [ "$nl" != "$l" ]; then
    printf '{"ok":false,"msg":"写入配置失败，请检查 %s 权限"}\n' "$(json_escape "$CONF_FILE")"
    return 1
  fi

  # 立刻触发一次热重载：守护进程按 mtime 变化读取，这里不需要额外通知
  msg="已保存，守护进程将在 ${POLL_INTERVAL}s 内热重载并生效"
  [ "$adjusted" = "true" ] && msg="下限已自动调整为 ${l}%（与上限至少间隔 5%），${msg}"
  printf '{"ok":true,"upper":%s,"lower":%s,"adjusted":%s,"msg":"%s"}\n' \
    "$u" "$l" "$adjusted" "$(json_escape "$msg")"
}

api_log() {
  webui_touch
  if [ -f "$LOG_FILE" ]; then
    tail -n 14 "$LOG_FILE" 2>/dev/null
  else
    echo "暂无日志"
  fi
}
