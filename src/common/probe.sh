#!/system/bin/sh
# Battery Guard - 充电控制节点自动探测
# 用法：sh /data/adb/modules/battery_guard/common/probe.sh
# 输出：
#   详细结果 -> /data/adb/battery-guard/battery-guard.log
#   选定结果 -> /data/adb/battery-guard/nodes.conf
#   摘要     -> stdout（供 customize.sh 的 ui_print 使用）

. "$(dirname "$0")/lib.sh"
load_conf

# ---------------- 候选节点清单 ----------------
# 类型说明：
#   direct        -> 写 1 = 允许充电，写 0 = 停止充电
#   invert        -> 写 0 = 允许充电，写 1 = 停止充电
#   current_limit -> 写原始值 = 允许充电，写极小电流值 = 停止充电（限流兜底）

CAND_DIRECT="
/sys/class/power_supply/battery/charging_enabled
/sys/class/power_supply/battery/battery_charging_enabled
/sys/class/power_supply/battery/charge_enabled
/sys/class/power_supply/battery/charger_enabled
/sys/class/power_supply/battery/charging_switch
/sys/class/power_supply/battery/charger_enable
"

CAND_INVERT="
/sys/class/power_supply/battery/input_suspend
/sys/class/sec/battery/input_suspend
/sys/class/power_supply/battery/charge_suspend
/sys/class/power_supply/battery/batt_slate_mode
/sys/class/sec/battery/batt_slate_mode
/sys/class/power_supply/battery/slate_mode
/sys/class/power_supply/battery/batt_charging_source
"

# 只登记、绝对不写入的节点
# store_mode 在 Tab S7+ 上实为"单向开关"：写入任何值（含 0）都会被置 1，
# 一旦触碰就只能靠重启复位，期间插电不充电。因此只记录它存在，绝不参与探测与复位。
CAND_NOTOUCH="
/sys/class/power_supply/battery/store_mode
/sys/class/sec/battery/store_mode
"

CAND_CURRENT="
/sys/class/power_supply/battery/input_current_limit
/sys/class/power_supply/battery/input_current_max
/sys/class/power_supply/battery/constant_charge_current_max
/sys/class/power_supply/battery/batt_input_current_limit
"

# 仅记录存在性，不参与控制（用于日志排查）
CAND_INFO="
/sys/class/power_supply/battery/charge_control_limit
/sys/class/power_supply/battery/charge_control_limit_max
/sys/class/power_supply/battery/batt_charging_source
/sys/class/power_supply/battery/switch_charging_source
/sys/class/power_supply/battery/charge_uno_control
/sys/class/power_supply/battery/batt_lp_charging
/sys/class/power_supply/battery/charge_type
/sys/class/power_supply/battery/charging_type
/sys/class/power_supply/battery/direct_charging_status
/sys/class/power_supply/battery/charge_full
/sys/class/power_supply/battery/status
/sys/class/power_supply/battery/health
/sys/class/power_supply/battery/temp
"

candidates_for() {
  case "$1" in
    direct) echo "$CAND_DIRECT" ;;
    invert) echo "$CAND_INVERT" ;;
    current_limit) echo "$CAND_CURRENT" ;;
    *) echo "" ;;
  esac
}

kind_label() {
  case "$1" in
    direct) echo "正向(1充/0停)" ;;
    invert) echo "反向(0充/1停)" ;;
    current_limit) echo "限流(电流值)" ;;
    *) echo "未知" ;;
  esac
}

test_value_for() {
  case "$1" in
    direct) echo 0 ;;
    invert) echo 1 ;;
    current_limit) echo "$CURRENT_LIMIT_VALUE" ;;
    *) echo 1 ;;
  esac
}

# ---------------- 探测单个节点 ----------------
# 返回：0 可用；1 不可用。结果写入 RESULT_LINE
probe_one() {
  path=$1
  kind=$2
  RESULT_LINE=""

  if [ ! -e "$path" ]; then
    [ "$LOG_VERBOSE" = "1" ] && log_print "  探测 缺失  $kind  $path"
    return 1
  fi
  if [ ! -w "$path" ]; then
    [ "$LOG_VERBOSE" = "1" ] && log_print "  探测 只读  $kind  $path"
    return 1
  fi

  old=$(node_read "$path")
  if [ "$PROBE_WRITE_TEST" = "1" ]; then
    tv=$(test_value_for "$kind")
    if ! node_write "$path" "$tv"; then
      [ "$LOG_VERBOSE" = "1" ] && log_print "  探测 写入失败  $kind  $path"
      return 1
    fi
    new=$(node_read "$path")
    # 先判定写入是否生效，再无条件还原
    if [ "$new" != "$tv" ]; then
      node_write "$path" "$old" >/dev/null 2>&1
      [ "$LOG_VERBOSE" = "1" ] && log_print "  探测 回读不符(写入 $tv 读回 ${new:-空}) $kind  $path"
      [ "$LOG_VERBOSE" = "1" ] && log_print "        若该节点确实可写但不回读，可将 PROBE_WRITE_TEST 改为 0 后重新探测"
      return 1
    fi
    # 还原后必须再验一次：部分三星节点是"单向开关"（例如 store_mode 写任何值都会置 1），
    # 这种节点写进去就回不来，会直接导致插电不充电，必须剔除
    node_write "$path" "$old" >/dev/null 2>&1
    back=$(node_read "$path")
    if [ "$back" != "$old" ]; then
      [ "$LOG_VERBOSE" = "1" ] && log_print "  探测 单向节点(还原为 $old 后仍读回 ${back:-空}) $kind  $path —— 放弃使用"
      return 1
    fi
    # 测试结束统一留在"允许充电"的值上，并记录该值为默认值，
    # 避免把探测前的停充状态误当成默认值写进 nodes.conf
    case "$kind" in
      invert) av=0 ;;
      direct) av=1 ;;
      *) av=$old ;;
    esac
    node_write "$path" "$av" >/dev/null 2>&1
    old=$av
  fi

  RESULT_LINE="$kind $path $old"
  return 0
}

# ---------------- 主流程 ----------------
log_print "================ 节点探测开始 ================"
log_print "设备: $(getprop ro.product.manufacturer) $(getprop ro.product.model) / Android $(getprop ro.build.version.release) / 内核 $(uname -r)"

# 只登记不写入的节点
for p in $CAND_NOTOUCH; do
  if [ -e "$p" ]; then
    log_print "  [不写入] $p （单向节点：写任何值都会置 1，触碰后需重启才能恢复，故跳过）"
  fi
done

# 仅信息类节点
for p in $CAND_INFO; do
  if [ -r "$p" ]; then
    v=$(node_read "$p")
    [ -n "$v" ] && log_print "  [信息] $p = $v"
  fi
done

FOUND=""
FOUND_COUNT=0
SAFE_NODES=""
SAFE_FILE=$PERSIST_DIR/safe_nodes.conf
: > "$SAFE_FILE" 2>/dev/null

for kind in $(echo "$NODE_PREFERENCE" | tr ',' ' '); do
  for p in $(candidates_for "$kind"); do
    if probe_one "$p" "$kind"; then
      FOUND_COUNT=$((FOUND_COUNT + 1))
      set -- $RESULT_LINE
      log_print "  探测 [可用] $(kind_label "$1") $2 (开机默认值=$3)"
      # 已验证可双向读写的节点才允许被开机复位清扫
      printf '%s %s\n' "$1" "$2" >> "$SAFE_FILE" 2>/dev/null
      if [ -z "$FOUND" ]; then
        FOUND=$RESULT_LINE
        log_print "   >>> 首选节点候选: $2"
      fi
    fi
  done
done

echo "=============================================="
if [ -n "$FOUND" ]; then
  set -- $FOUND
  node_save "$1" "$2" "$3"
  log_print "探测结束：共 $FOUND_COUNT 个可用节点，选定 $1 类型 -> $2 （默认值 $3）"
  log_print "================ 节点探测结束 ================"
  echo " 已探测到充电控制节点："
  echo "   类型 : $(kind_label "$1")"
  echo "   路径 : $2"
  echo "   默认值: $3"
  echo " 共发现 $FOUND_COUNT 个可用节点（详见日志）"
  echo "=============================================="
  exit 0
fi

# 未找到任何可用节点：写入 none，守护只记录不控制
node_save "none" "none" "none"
log_print "探测结束：未找到任何可写的充电控制节点，模块将只记录电量日志"
log_print "================ 节点探测结束 ================"
echo "=============================================="
echo " [警告] 未探测到可用的充电控制节点"
echo " 模块仍会记录电量日志，但无法控制充电"
echo " 请查看日志确认 /sys/class/power_supply 下的实际节点："
echo "   adb shell su -c 'ls -l /sys/class/power_supply/battery/'"
echo "=============================================="
exit 1
