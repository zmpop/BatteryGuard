# Battery Guard

三星平板的**充电阈值控制 Magisk 模块**：电量到上限自动停止充电，掉到下限自动恢复，
用滞回区间避免频繁通断。开机自动探测当前设备真实可用的 sysfs 充电控制节点，
卸载时自动复位节点、恢复系统默认充电行为。

在三星 Galaxy Tab S7+（SM-T970 / Android 13）上实测通过，实际控制节点为
`/sys/class/power_supply/battery/batt_slate_mode`。

自带可视化控制面板：拖动滑块设定上下限 → 保存 → 30 秒内热生效，不用改配置文件、不用重启。
面板由模块自带的 `busybox httpd` 提供（只监听 `127.0.0.1:8654`），不依赖任何第三方 App。

- **Magisk 28+**：模块卡片上的 **「操作」** 按钮直接打开面板；
- **Magisk 26.x / 27.x**：Magisk 本身没有操作按钮（Action UI 自 v28 才有），面板默认开机常驻，
  用浏览器打开 `http://127.0.0.1:8654/`，再「添加页面至 → 主屏幕」生成桌面图标即可。

## 快速开始

```bash
# 1. 打包（必须走 build.py：需要正确的 Unix 权限位与目录条目，
#    用资源管理器/Compress-Archive 打的包 Magisk 会解压失败）
python build.py

# 2. 无线连接平板并安装（默认 192.168.8.176:5555）
./adb-tool.sh                 # Linux / macOS / Git Bash
.\adb-tool.ps1                # Windows（双击 adb-tool.bat 亦可）

# 3. 查看运行状态
./adb-tool.sh status
./adb-tool.sh switch          # 只看状态切换记录
./adb-tool.sh ui              # 打开平板上的控制面板（滑块设置上下限）
./adb-tool.sh set 75 45       # 命令行方式改上限 75% / 下限 45%，热生效无需重启
```

也可以把生成的 `BatteryGuard-v1.0.zip` 推到 `/sdcard/Download/`，
再用 Magisk App → 模块 → 从本地安装。

## 默认策略

| 项 | 默认 |
|---|---|
| 上限 `UPPER_LIMIT` | 80% |
| 下限 `LOWER_LIMIT` | 40% |
| 轮询间隔 | 30s |
| 最小切换间隔（防抖） | 120s |

配置文件在设备的 `/data/adb/battery-guard/battery-guard.conf`，改完约 30s 内热重载，日志里会有 `配置热重载` 记录。

> 该节点切断的是**充电输入而非旁路供电**：停充期间平板仍由电池供电、电量会缓慢下降，
> 所以实际是 `80% 停充 → 掉到 40% 复充` 的浅循环。想延长电池寿命，推荐区间 `75 / 45`。

## 目录结构

```
BatteryGuard/
├── build.py                生成 Magisk 模块 zip
├── adb-tool.sh             电脑端一键安装 / 调试（Linux / macOS / Git Bash）
├── adb-tool.ps1 / .bat     同上，Windows 版
└── src/                    模块源码
    ├── module.prop
    ├── sepolicy.rule       放行 magisk 域写 sysfs_battery（三星 SELinux 必需）
    ├── service.sh          开机完成后拉起守护
    ├── post-fs-data.sh     开机早期探测节点
    ├── uninstall.sh        卸载清理（自包含，不依赖 common/）
    ├── action.sh           Magisk 28+ 的「操作」按钮：拉起控制面板
    ├── customize.sh        安装时探测节点并立即启动守护
    ├── README.md           完整文档：节点清单 / 配置 / 调试 / 排错 / 机型实测
    ├── webroot/            控制面板：index.html + cgi-bin/{state,set,log}
    └── common/
        ├── lib.sh
        ├── api.sh          面板数据接口（JSON / 校验 / 写配置）
        ├── webui.sh        面板服务管理（busybox httpd）
        ├── battery-guard.conf
        ├── probe.sh
        ├── supervisor.sh
        └── battery-guard-daemon.sh
```

完整文档（三星节点清单、全部配置参数、排错与机型实测坑位）见 [`src/README.md`](src/README.md)。
