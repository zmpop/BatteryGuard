# Battery Guard —— 三星平板充电阈值控制 Magisk 模块

在已 root 的三星平板上实现「充电上限 / 下限」自动控制：

- 电量达到**上限**（默认 80%）→ 写入 sysfs 节点停止充电；
- 电量跌到**下限**（默认 40%）→ 恢复充电，充满到上限后再次停止；
- 用**滞回区间 + 最小切换间隔**双重防抖，避免在阈值附近反复通断；
- 开机自动探测当前设备实际可用的充电控制节点，探测结果写入日志；
- 拔掉充电器时自动恢复系统默认充电行为；
- 模块卸载时自动把节点复位，恢复系统默认充电行为。

---

## 一、三星设备常见充电开关节点清单

模块内置了下面这份候选清单，开机时逐个检查「是否存在 → 是否可写 → 写测试值并回读校验」，
只有通过全部检查的节点才会被启用，并把结果写入 `nodes.conf` 与日志。

### 正向节点（写 1 = 允许充电，写 0 = 停止充电）

| 节点路径 | 说明 |
|---|---|
| `/sys/class/power_supply/battery/charging_enabled` | 部分三星 / 联发科内核的标准充电开关 |
| `/sys/class/power_supply/battery/battery_charging_enabled` | 同上，命名变体 |
| `/sys/class/power_supply/battery/charge_enabled` | 命名变体 |
| `/sys/class/power_supply/battery/charger_enabled` | 命名变体 |
| `/sys/class/power_supply/battery/charging_switch` | 常见于 MTK 平台 |
| `/sys/class/power_supply/battery/charger_enable` | 命名变体 |

### 反向节点（写 0 = 允许充电，写 1 = 停止充电）

| 节点路径 | 说明 |
|---|---|
| `/sys/class/power_supply/battery/input_suspend` | **三星最常见的主力节点**，1 = 挂起充电输入 |
| `/sys/class/sec/battery/input_suspend` | 部分机型放在 sec-battery 下 |
| `/sys/class/power_supply/battery/charge_suspend` | 部分三星内核 |
| `/sys/class/power_supply/battery/batt_slate_mode` | 三星「slate mode / 展台模式」，开启后停止充电 |
| `/sys/class/sec/battery/batt_slate_mode` | 同上，路径变体 |
| `/sys/class/power_supply/battery/slate_mode` | 命名变体 |
| `/sys/class/power_supply/battery/store_mode` | ⚠️ **默认不写入**。Tab S7+ 实测为单向开关：写入任何值（含 0）都会被置 1，触碰后只能靠重启复位，期间插电不充电 |
| `/sys/class/sec/battery/store_mode` | 同上，路径变体 |
| `/sys/class/power_supply/battery/batt_charging_source` | 三星充电来源上报位，**多数内核为只读**，会被写测试自动剔除 |

### 限流类兜底节点（写原始值 = 正常，写 0 = 断流）

| 节点路径 | 说明 |
|---|---|
| `/sys/class/power_supply/battery/input_current_limit` | 输入电流上限，写 0 相当于停止充电 |
| `/sys/class/power_supply/battery/input_current_max` | 三星常见，命名变体 |
| `/sys/class/power_supply/battery/constant_charge_current_max` | 部分内核 |
| `/sys/class/power_supply/battery/batt_input_current_limit` | 命名变体 |

### 仅记录不控制（用于排查）

| 节点路径 | 说明 |
|---|---|
| `/sys/class/power_supply/battery/charge_control_limit` | 少数内核原生支持直接写百分比上限 |
| `/sys/class/power_supply/battery/charge_control_limit_max` | 上限值 |
| `/sys/class/power_supply/battery/status` / `health` / `temp` | 电池状态信息 |

> 优先级可通过配置调整，默认 `NODE_PREFERENCE=direct,invert,current_limit`。
> 若你的机型上有其它可用节点，用 `FORCE_NODE=类型:路径` 直接指定即可，例如：
> `FORCE_NODE=invert:/sys/class/power_supply/battery/input_suspend`

---

## 二、模块结构

```
battery_guard/                      模块根目录 /data/adb/modules/battery_guard
├── module.prop                     模块信息（id / 版本 / 描述）
├── sepolicy.rule                   放行 magisk 域对 sysfs_battery 的写权限（三星 SELinux 严格策略必需）
├── service.sh                      开机完成后拉起守护进程（late_start service）
├── post-fs-data.sh                 开机早期自动探测充电控制节点
├── uninstall.sh                    卸载清理：杀进程 + 复位所有节点（自包含，不依赖 common）
├── action.sh                       Magisk 卡片「执行」按钮：查看状态与最近日志
├── customize.sh                    安装时修正权限、安装默认配置、立即执行一次节点探测
├── README.md                       本文档
├── META-INF/com/google/android/    供第三方 Recovery 刷入（Magisk App 安装不需要）
└── common/
    ├── lib.sh                      公共函数库（路径、配置、日志、sysfs 读写、进程管理）
    ├── battery-guard.conf          配置文件模板（安装时复制到 /data/adb/battery-guard/）
    ├── probe.sh                    节点自动探测 + 写测试校验 → nodes.conf
    ├── supervisor.sh               守护循环：守护进程异常退出后自动拉起
    └── battery-guard-daemon.sh     守护进程：轮询电量、滞回判定、状态切换、写日志
```

持久化目录（模块卸载后仍保留，方便重装沿用配置）：

```
/data/adb/battery-guard/
├── battery-guard.conf     用户可编辑的配置（上限 / 下限 / 轮询间隔 …）
├── battery-guard.log     运行与切换日志
├── nodes.conf            自动探测选定的节点（自动生成）
├── daemon.pid            守护进程 PID
└── supervisor.pid        守护循环 PID
```

---

## 三、配置文件参数

文件：`/data/adb/battery-guard/battery-guard.conf`
**改完不用重启**，守护进程在下一个轮询周期（约 30s）自动热重载，并在日志中记录变更。

| 参数 | 默认值 | 说明 |
|---|---|---|
| `UPPER_LIMIT` | 80 | 上限电量，达到后停止充电 |
| `LOWER_LIMIT` | 40 | 下限电量，低于后恢复充电（强制与上限间隔 ≥ 5%） |
| `POLL_INTERVAL` | 30 | 轮询电量间隔（秒），最小 5 |
| `MIN_SWITCH_INTERVAL` | 120 | 两次充电状态切换之间的最小间隔（秒），防抖核心 |
| `CONFIRM_COUNT` | 1 | 连续满足 N 次条件才动作，过滤瞬间跳变 |
| `REASSERT_SEC` | 120 | 定期重新写入节点，防止内核自行复位 |
| `ENABLED` | 1 | 总开关，0 = 只记日志不控制 |
| `ONLY_WHEN_PLUGGED` | 1 | 仅在插着充电器时控制；拔电后恢复默认 |
| `DRY_RUN` | 0 | 1 = 只写日志不写节点，用于验证逻辑 |
| `NODE_PREFERENCE` | direct,invert,current_limit | 节点类型优先级 |
| `FORCE_NODE` | 空 | 手动指定节点，格式 `类型:路径` |
| `CURRENT_LIMIT_VALUE` | 0 | 限流类节点停充时写入的电流值 |
| `PROBE_WRITE_TEST` | 1 | 探测时是否做「写测试值并回读校验」 |
| `LOG_MAX_LINES` | 2000 | 日志滚动保留行数 |
| `LOG_HEARTBEAT` | 20 | 每 N 个周期输出一条心跳（默认约 10 分钟） |
| `LOG_TO_LOGCAT` | 1 | 同步输出到 logcat（tag: `BatteryGuard`） |
| `RESTART_DELAY` | 30 | 守护进程异常退出后的重启延时（秒） |
| `EARLY_START` | 0 | 1 = 在开机动画阶段就启动守护（默认开机完成后启动） |

---

## 四、安装

### 1. 无线 adb 连接平板

```bash
adb connect 192.168.8.176:5555
adb devices                  # 确认出现 192.168.8.176:5555  device
adb shell id                 # 确认能进 shell
```

> 若连不上：平板需开启「开发者选项 → 无线调试」，或在已 USB 连接时执行
> `adb tcpip 5555` 后再 `adb connect`。
> 首次无线调试会弹授权，需在平板上点允许。

### 2. 推送并安装模块

方式 A（推荐，Magisk App 图形化）：

```bash
adb push BatteryGuard-v1.0.zip /sdcard/Download/
```
然后在平板 Magisk App → 模块 → 从本地安装 → 选择该文件。

方式 B（命令行，无需打开 App）：

```bash
adb push BatteryGuard-v1.0.zip /sdcard/Download/
adb shell su -c "magisk --install-module /sdcard/Download/BatteryGuard-v1.0.zip"
```

方式 C（第三方 Recovery）：把 zip 拷进存储，Recovery 里刷入即可。

方式 D（电脑端一键脚本，推荐长期使用）：
仓库根目录下的 `adb-tool.sh` 封装了连接 → 推送 → 安装 → 重启 → 看日志：

```bash
./adb-tool.sh                    # 连接 192.168.8.176:5555 并完成安装+重启
./adb-tool.sh 192.168.1.20:5555  # 指定其它设备
./adb-tool.sh log                # 实时跟踪日志
./adb-tool.sh status             # 电量 / 节点 / 守护 PID
./adb-tool.sh switch              # 只看状态切换记录
./adb-tool.sh set 85 45           # 热更新上限 85% / 下限 45%
./adb-tool.sh uninstall          # 卸载并恢复默认充电
```

Windows 上用同名的 `adb-tool.bat` / `adb-tool.ps1`（功能完全等价，双击 `.bat` 即可）：

```powershell
.\adb-tool.ps1                    # 连接 192.168.8.176:5555 并完成安装+重启
.\adb-tool.ps1 status             # 电量 / 节点 / 守护 PID
.\adb-tool.ps1 set 85 45          # 热更新上限 85% / 下限 45%
.\adb-tool.ps1 log                # 实时跟踪日志
.\adb-tool.ps1 restart            # 用最新脚本重启守护进程
```

> `.bat` 只是转发给 `.ps1` 的启动器（内部走 PowerShell 引擎）。
> 若 adb 还没进 PATH，脚本会自动回退到
> `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`。

### 3. 重启

```bash
adb shell su -c "reboot"
```

安装过程中 customize.sh 会立即执行一次节点探测，并在安装界面打印出实际选中的节点，
例如：

```
- 正在探测充电控制节点 ...
 已探测到充电控制节点：
   类型 : 反向(0充/1停)
   路径 : /sys/class/power_supply/battery/input_suspend
   默认值: 0
 共发现 2 个可用节点（详见日志）
```

---

## 五、调试与验证

### 看日志（最常用）

```bash
adb shell su -c "cat /data/adb/battery-guard/battery-guard.log"
# 实时跟踪
adb shell su -c "tail -f /data/adb/battery-guard/battery-guard.log"
# 只看状态切换
adb shell su -c "grep 状态切换 /data/adb/battery-guard/battery-guard.log"
# logcat 通道
adb shell "logcat -s BatteryGuard:V"
```

典型日志：

```
[10-26 17:31:02] === 守护进程启动 PID=8123 ===
[10-26 17:31:02] 策略: 上限=80% 下限=40% 轮询=30s 最小切换间隔=120s 连续确认=1
[10-26 17:31:02] 节点: 类型=invert 路径=/sys/class/power_supply/battery/input_suspend 默认值=0
[10-26 17:31:02] 初始策略: 允许充电
[10-26 17:31:32] 心跳: 电量=63% 电池状态=Charging 充电器=已连接 当前策略=允许充电 节点值=0
[10-26 18:12:02] 状态切换: 允许充电 -> 停止充电 | 电量=80% (>=上限80%) 充电器=已连接 电池状态=Charging 写入[...input_suspend]=1 距上次切换=2450s
[10-26 18:12:32] 心跳: 电量=80% 电池状态=Not charging 充电器=已连接 当前策略=停止充电 节点值=1
```

### 验证上下限切换是否真的生效

```bash
# 1) 确认节点当前值与电池状态
adb shell su -c "cat /sys/class/power_supply/battery/input_suspend; cat /sys/class/power_supply/battery/status; cat /sys/class/power_supply/battery/capacity"

# 2) 快速验证：把上限临时改到低于当前电量，观察是否立刻停充
adb shell su -c "sed -i 's/^UPPER_LIMIT=.*/UPPER_LIMIT=55/' /data/adb/battery-guard/battery-guard.conf"
adb shell su -c "cat /data/adb/battery-guard/battery-guard.log | tail -20"
#   预期：一个轮询周期内出现 "允许充电 -> 停止充电"，且 status 变为 Not charging

# 3) 再把下限改到高于当前电量，验证恢复充电
adb shell su -c "sed -i 's/^LOWER_LIMIT=.*/LOWER_LIMIT=50/' /data/adb/battery-guard/battery-guard.conf"
#   预期：出现 "停止充电 -> 允许充电"，status 回到 Charging

# 4) 测完改回真实值
adb shell su -c "sed -i -e 's/^UPPER_LIMIT=.*/UPPER_LIMIT=80/' -e 's/^LOWER_LIMIT=.*/LOWER_LIMIT=40/' /data/adb/battery-guard/battery-guard.conf"
```

> 提示：`LOWER_LIMIT` 被强制要求比 `UPPER_LIMIT` 小至少 5%，否则模块会自动修正。

### 其它常用命令

```bash
# 手动执行一次节点探测（会重新扫描并更新 nodes.conf）
adb shell su -c "sh /data/adb/modules/battery_guard/common/probe.sh"

# 查看当前选定节点
adb shell su -c "cat /data/adb/battery-guard/nodes.conf"

# 列出电池目录下所有真实存在的节点（找新节点时用）
adb shell su -c "ls -l /sys/class/power_supply/battery/ | grep -E 'suspend|store|slate|charging|current'"

# 确认守护进程存活
adb shell su -c "cat /data/adb/battery-guard/daemon.pid; ls /proc/\$(cat /data/adb/battery-guard/daemon.pid) >/dev/null && echo 存活"

# 手动停 / 起守护
adb shell su -c "kill \$(cat /data/adb/battery-guard/daemon.pid)"        # 停（会自动恢复充电）
adb shell su -c "nohup sh /data/adb/modules/battery_guard/common/supervisor.sh >/dev/null 2>&1 &"

# Magisk App 里点模块卡片的「执行」按钮 → 直接看到状态 + 最近 15 条日志
```

---

## 六、常见问题

**Q1. 日志里出现「无可用充电控制节点」**

先列出真实节点：

```bash
adb shell su -c "ls -l /sys/class/power_supply/battery/"
```

找到形如 `xxx_suspend` / `xxx_store_mode` / `xxx_charging_xxx` 的可写节点后，
在配置里强制指定，例如节点写 1 表示停充：

```
FORCE_NODE=invert:/sys/class/power_supply/battery/你的节点
```

改完执行 `sh /data/adb/modules/battery_guard/common/probe.sh`，重启即可。

**Q1b. 节点明明可写，探测却把它剔除了**

部分内核的节点「能写但读不回写入值」（write-only）。日志里会提示
`回读不符(写入 1 读回 空)`。此时把配置改成：

```
PROBE_WRITE_TEST=0
```

再执行 `sh /data/adb/modules/battery_guard/common/probe.sh` 重新探测即可
（关闭后只检查节点存在且可写，不再做回读校验）。

**Q2. 日志提示「写入 xxx 失败」**

三星出厂策略对电池节点的 SELinux 标签管控很严。以 Galaxy Tab S7+（SM-T970 / Android 13）实测：

```
ls -lZ /sys/class/power_supply/battery/batt_slate_mode
  -rw-rw-r-- system radio u:object_r:sysfs_battery:s0
```

即便 `su -c` 的上下文已经是 `u:r:magisk:s0`，直接写仍会
`can't create ...: Permission denied`（chmod 能过，open for write 被拦）。
模块已内置 `sepolicy.rule`，开机时由 Magisk 自动加载放行：

```
allow magisk sysfs_battery:file { getattr open read write append }
```

现象是「magisk 守护进程执行脚本时能写，`adb shell su -c` 直接写被拒」，
所以**判断是否真的生效请以模块日志为准**，别用 su 手工 echo 的结果下结论。

排查手段：

```bash
adb shell su -c "dmesg | grep -i avc | tail -20"      # 部分内核限制 dmesg
adb shell su -c "logcat -d -b all | grep -i avc"
adb shell su -c "magiskpolicy --live 'allow magisk sysfs_battery:file { open read write getattr }'"
```

**Q3. 状态显示停充了，但电量还在涨**

部分内核的 `store_mode` 之类节点只是降低上限而非彻底停充；
可改用 `input_suspend`（`FORCE_NODE` 指定）或改用 `direct` 类节点。

**Q4. 停充后拔掉再插上，是否能正常充电？**

能。守护进程在检测到充电器断开时会主动恢复系统默认充电行为，
所以下次插上会正常充电，直到再次达到上限。

**Q5. 禁用（不是卸载）模块是否恢复默认？**

会。禁用后重启，内核会把 sysfs 节点重置为默认值，充电恢复正常。
若希望不重启立即恢复，可在 Magisk 里直接移除（会执行 `uninstall.sh`）。

**Q6. 心跳日志太多/太少**

调整 `LOG_HEARTBEAT`（默认 20 个周期 ≈ 10 分钟一条）与 `LOG_MAX_LINES`（滚动上限）。

---

## 七、卸载

**是的，直接在 Magisk App 里对 Battery Guard 点「移除」即可，然后重启。**

Magisk 会在重启早期执行 `uninstall.sh`，它自动完成：

1. 杀掉守护进程与守护循环（先杀守护循环，防止它把守护进程重新拉起）；
2. 把被选中的节点写回默认值；
3. 清扫所有候选节点（正向写 1、反向写 0），确保无残留停充状态；
4. 清理锁文件、PID 文件与节点记录。

`uninstall.sh` 是**自包含**的（不读 `common/lib.sh`），
所以即使模块目录已被 Magisk 删除，清理照样能跑完。

> `store_mode` 是单向开关（写任何值都会变 1），卸载时**只检测不写入**，
> 万一它卡在 1，重启即自动清除——而移除模块本身就会重启，无需额外处理。

卸载后验证：

```bash
adb shell su -c "cat /sys/class/power_supply/battery/batt_slate_mode"        # 期望 0
adb shell su -c "cat /sys/class/power_supply/battery/batt_current_ua_now"    # 期望为正数（充电电流 µA）
```

> 三星在 95% 以上时 `status` 常仍报 `Not charging`，而 `batt_current_ua_now`
> （或 `current_now`）为正就能证明确实在充电。**判断有没有在充，看电流比看 status 可靠。**

配置与日志保留在 `/data/adb/battery-guard/`，重装模块可直接沿用。

### 不重启也想立刻卸载

```bash
./adb-tool.sh uninstall     # 立即执行清理 + 标记为待移除，重启后模块消失
./adb-tool.sh purge         # 连配置与日志一起删干净
```

或手动：

```bash
adb shell su -c "sh /data/adb/modules/battery_guard/uninstall.sh"
adb shell su -c "rm -rf /data/adb/modules/battery_guard"
adb shell su -c "rm -rf /data/adb/battery-guard"        # 可选：连配置一起删
```

### 只是想临时停用

在 Magisk 里把开关关掉（禁用）即可，重启后节点由内核重置为默认值、充电恢复正常。
比卸载更适合"先停一停看看"，因为配置和日志都还在。

---

## 八、机型实测记录

### 三星 Galaxy Tab S7+（SM-T970 / Android 13 / 内核 4.19.113 / Tab S7+ 为 gts7xlwifi）

| 项目 | 结果 |
|---|---|
| 自动选中的节点 | `/sys/class/power_supply/battery/batt_slate_mode`（invert：写 1 停充 / 写 0 充电） |
| 可用的节点数 | 2 个（batt_slate_mode、store_mode） |
| 直接可用的 direct 类 | 无（charging_enabled 等全部不存在） |
| 电源节点 | `ac`(Mains) / `battery` / `max77705-charger` / `max77705-fuelgauge` / `otg` / `pca9468-charger` / `ps` / `sec-direct-charger` / `usb` / `wireless` |

三个必须知道的坑：

1. **`/sys/class/power_supply/usb/online` 常年为 1**，即使没插充电器。
   直接采信会导致"未插电却判定已连接"，进而在 100% 时误写停充节点。
   所以模块默认 `TRUST_USB_ONLINE=0`，只信 `ac` / `wireless` / `dock`。
2. **`batt_charging_source` 未插电时也报 1**，同样不可作为"已插电"依据（已弃用）。
3. **`store_mode` 是单向开关**：写入任何值都会变成 1，且只有重启能复位。
   模块的探测写测试会把它永久置 1，因此已被移入"只登记、绝不写入"清单。
   另外，`adb shell su -c "echo ... > 节点"` 在这台机器上**写不进去**
   （magisk 域对 `sysfs_battery` 被拦），但 **magisk 守护进程执行脚本时可以写入**，
   所以判断节点是否生效请以 `/data/adb/battery-guard/battery-guard.log` 为准。

4. **写入停充节点会触发"传感器反馈"**：写 `batt_slate_mode=1` 后，驱动会立刻把
   `charging_type` 上报成 `NONE`、`status` 变成 `Discharging`——看起来就像充电器被拔了。
   如果据此判定"已拔电"并恢复充电，就会形成
   `停充 → 以为拔电 → 充 → 以为插上 → 停充` 的 30 秒自激振荡。
   模块的对策是：**处于停充状态时，不采信"无充电器"证据**（把它当作还插着），
   只有在停充状态下重新读到充电证据时，才判定为"刚被插上"并开启新会话。

5. **停充期间平板由电池供电**：`batt_slate_mode` 切断的是充电输入，
   插着电也会继续掉电。所以实际循环是
   `充到 80% 停充 → 掉到 40% 复充 → 再充到 80%`。
   想改成就地保持 80%（充电器直接给主板供电）需要内核支持输入旁路，
   该节点做不到，这是 Tab S7+ 上的硬件/驱动限制。

## 九、滞回逻辑说明

```
电量 ≥ UPPER_LIMIT(80%) 且 充电器已连接  →  停止充电
                    ↑                            │
                    │                            ↓
            重新充到上限后再次停止          电量 ≤ LOWER_LIMIT(40%)  →  恢复充电
```

三重防抖：

1. **滞回区间**：80% 停、40% 才充，中间 40 个百分点的缓冲，天然不会在阈值附近抖动；
2. **最小切换间隔** `MIN_SWITCH_INTERVAL`（默认 120s）：两次切换之间必须间隔足够久；
3. **连续确认** `CONFIRM_COUNT`：需连续 N 次轮询都满足才动作，过滤电量瞬间跳变。

拔掉充电器时立即恢复系统默认充电行为，保证下次插电正常充电。
