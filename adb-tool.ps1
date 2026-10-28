#Requires -Version 5.1
<#
============================================================
 Battery Guard - Windows 端无线安装 / 调试助手 (PowerShell)

 用法（PowerShell 中）：
   .\adb-tool.ps1                      连接 -> 推送 -> 安装 -> 重启
   .\adb-tool.ps1 install              同上，但不重启
   .\adb-tool.ps1 status               查看电量 / 节点 / 守护状态
   .\adb-tool.ps1 log                  实时日志（Ctrl+C 退出）
   .\adb-tool.ps1 restart              用最新脚本重启守护进程
   .\adb-tool.ps1 probe                重新探测充电控制节点
   .\adb-tool.ps1 switch               查看所有状态切换记录
   .\adb-tool.ps1 set 85 45            上限 85% 下限 45%（热生效）
   .\adb-tool.ps1 uninstall            恢复默认充电并标记待移除
   .\adb-tool.ps1 purge                连同配置与日志一并清除
   .\adb-tool.ps1 192.168.1.20:5555    指定其它设备地址

 双击 adb-tool.bat 等价于不带参数运行本脚本。
============================================================
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

# ---------- 编码：让设备返回的 UTF-8 中文正常显示 ----------
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    & chcp 65001 | Out-Null
} catch { }

# ---------- 常量 ----------
$DefaultDevice = '192.168.8.176:5555'
$ZipName       = 'BatteryGuard-v1.0.zip'
$ZipPath       = Join-Path $PSScriptRoot $ZipName
$Log           = '/data/adb/battery-guard/battery-guard.log'
$Conf          = '/data/adb/battery-guard/battery-guard.conf'
$ModDir        = '/data/adb/modules/battery_guard'
$PersistDir    = '/data/adb/battery-guard'

# ---------- 参数解析 ----------
$Device = $DefaultDevice
$Cmd    = 'install-reboot'
$U = 80
$L = 40

if ($Rest) {
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        $a = $Rest[$i]
        if ($a -match '^[\d.]+:\d+$') { $Device = $a; continue }
        if ($a -eq 'set') {
            $Cmd = 'set'
            # 必须把两个数字参数一起吃掉，否则它们会被当成子命令再次覆盖 $Cmd
            if ($i + 1 -lt $Rest.Count) { $U = $Rest[$i + 1]; $i++ }
            if ($i + 1 -lt $Rest.Count) { $L = $Rest[$i + 1]; $i++ }
            continue
        }
        $Cmd = $a
    }
}

function Show-Usage {
    Write-Host @'

用法:
  .\adb-tool.ps1                      连接 -> 推送 -> 安装 -> 重启
  .\adb-tool.ps1 install              安装但不重启
  .\adb-tool.ps1 status               电量 / 节点 / 守护状态
  .\adb-tool.ps1 log                  实时日志 (Ctrl+C 退出)
  .\adb-tool.ps1 restart              用最新脚本重启守护进程
  .\adb-tool.ps1 probe                重新探测充电控制节点
  .\adb-tool.ps1 switch               状态切换记录
  .\adb-tool.ps1 set 85 45            上限 85% 下限 45%
  .\adb-tool.ps1 uninstall            恢复默认充电 + 标记待移除
  .\adb-tool.ps1 purge                连同配置与日志清除
  .\adb-tool.ps1 192.168.1.20:5555    指定设备地址

'@
}

# ---------- 定位 adb ----------
function Find-Adb {
    $c = Get-Command adb -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $fallback = @(
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'),
        'C:\platform-tools\adb.exe'
    )
    foreach ($p in $fallback) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

$AdbExe = Find-Adb
if (-not $AdbExe) {
    Write-Host "错误: 未找到 adb.exe" -ForegroundColor Red
    Write-Host "      请安装 platform-tools，或把 adb.exe 所在目录加入 PATH"
    exit 1
}

# 以 root 在设备上执行一段 shell
# 用单引号包裹整段：这样 $(...) 是在 root shell 内部展开的，
# 若用双引号则会被外层非 root 的 shell 先展开，读 /data/adb 会 Permission denied
function Invoke-Dev {
    param([Parameter(Mandatory = $true)][string]$ShellCmd)
    & $AdbExe -s $Device shell "su -c '$ShellCmd'"
}

function Step { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor Cyan }
function Ok   { param([string]$Msg) Write-Host "    $Msg" -ForegroundColor Green }
function Warn { param([string]$Msg) Write-Host "    $Msg" -ForegroundColor Yellow }
function Err  { param([string]$Msg) Write-Host "错误: $Msg" -ForegroundColor Red }

# ---------- 连接设备 ----------
Step "连接设备 $Device"
$null = & $AdbExe connect $Device 2>&1

$probe = & $AdbExe -s $Device shell 'echo ADB_OK' 2>&1 | Out-String
if ($probe -notmatch 'ADB_OK') {
    Err "无法通过 adb 访问 $Device"
    Warn "请确认：开发者选项 -> 无线调试 已开启"
    Warn "        且已允许本机调试（adb devices 不能显示 unauthorized）"
    exit 1
}

$model = (& $AdbExe -s $Device shell 'getprop ro.product.model' 2>&1 | Out-String).Trim()
Ok "已连接: $model"

$idout = & $AdbExe -s $Device shell 'su -c id' 2>&1 | Out-String
if ($idout -notmatch 'uid=0') {
    Err "无法获取 root 权限（su 不可用或未在 Magisk 中授予）"
    exit 1
}
Ok "root 权限: OK"

# ---------- 命令分发 ----------
switch ($Cmd) {

    { $_ -in 'install-reboot', 'install' } {
        if (-not (Test-Path $ZipPath)) {
            Err "找不到安装包: $ZipPath"
            Warn "请先运行 build.py 生成 zip，或把 zip 放到本脚本同目录"
            exit 1
        }
        Step "推送安装包"
        $null = & $AdbExe -s $Device push $ZipPath '/sdcard/Download/' 2>&1
        Step "安装模块"
        $out = & $AdbExe -s $Device shell "su -c `"magisk --install-module /sdcard/Download/$ZipName`"" 2>&1
        if (($out | Out-String) -match 'not found|not exist') {
            $out = & $AdbExe -s $Device shell "su -c `"/data/adb/magisk/magisk --install-module /sdcard/Download/$ZipName`"" 2>&1
        }
        $out | ForEach-Object { Write-Host "    $_" }

        if ($Cmd -eq 'install-reboot') {
            Step "重启设备"
            $null = & $AdbExe -s $Device shell 'su -c reboot' 2>&1
            Step "等待重启完成..."
            & $AdbExe -s $Device wait-for-device | Out-Null
            Start-Sleep -Seconds 25
            $null = & $AdbExe connect $Device 2>&1
            Step "重启后的日志："
            Invoke-Dev "tail -n 25 $Log" | ForEach-Object { Write-Host "    $_" }
        } else {
            Ok "安装完成，请手动重启设备使模块目录合并生效"
        }
    }

    'log' {
        Step "实时日志（Ctrl+C 退出）"
        Invoke-Dev "tail -f $Log"
    }

    'status' {
        Step "当前状态"
        Invoke-Dev "echo 电量=`$(cat /sys/class/power_supply/battery/capacity)%"
        Invoke-Dev "echo 电池状态=`$(cat /sys/class/power_supply/battery/status)"
        Invoke-Dev "echo 充电类型=`$(cat /sys/class/power_supply/battery/charging_type)"
        Invoke-Dev "echo 选中节点=`$(grep -v '^#' $PersistDir/nodes.conf)"
        Invoke-Dev "echo 守护PID=`$(cat $PersistDir/daemon.pid 2>/dev/null)"
        Step "最近日志"
        Invoke-Dev "tail -n 20 $Log" | ForEach-Object { Write-Host "    $_" }
    }

    'restart' {
        Step "重启守护进程（加载最新脚本与配置）"
        if (Test-Path $ZipPath) {
            $null = & $AdbExe -s $Device push $ZipPath '/sdcard/Download/' 2>&1
        }
        Invoke-Dev "kill -9 `$(cat $PersistDir/supervisor.pid) `$(cat $PersistDir/daemon.pid) 2>/dev/null" | Out-Null
        Start-Sleep -Seconds 2
        Invoke-Dev "rm -rf $PersistDir/.lock $PersistDir/.slock $PersistDir/daemon.pid $PersistDir/supervisor.pid" | Out-Null
        $out = & $AdbExe -s $Device shell "su -c `"magisk --install-module /sdcard/Download/$ZipName`"" 2>&1
        $out | Where-Object { $_ -match '守护|Done|路径|共发现' } | ForEach-Object { Write-Host "    $_" }
        Start-Sleep -Seconds 3
        Ok "守护PID=$(Invoke-Dev "cat $PersistDir/daemon.pid 2>/dev/null")"
    }

    'probe' {
        Step "重新探测充电控制节点"
        Invoke-Dev "sh $ModDir/common/probe.sh" | ForEach-Object { Write-Host "    $_" }
    }

    'switch' {
        Step "状态切换记录"
        # 在本机筛选：设备上的 toybox grep 遇到带引号的模式会退化成读 stdin
        # （报 Inappropriate ioctl for device 并挂住），且中文参数在传输时会被转码
        $hits = Invoke-Dev "cat $Log" | Where-Object { $_ -match '状态切换' }
        if ($hits) {
            $hits | ForEach-Object { Write-Host "    $_" }
        } else {
            Warn "暂无状态切换记录（自守护进程启动以来还没触发过上下限）"
        }
    }

    'set' {
        Step "设置上限 ${U}% / 下限 ${L}%（热生效，无需重启）"
        Invoke-Dev "sed -i -e `"s/^UPPER_LIMIT=.*/UPPER_LIMIT=$U/`" -e `"s/^LOWER_LIMIT=.*/LOWER_LIMIT=$L/`" $Conf"
        Ok "已写入 $Conf"
        Start-Sleep -Seconds 2
        Invoke-Dev "grep -e `"^UPPER_LIMIT=`" -e `"^LOWER_LIMIT=`" $Conf" | ForEach-Object { Write-Host "    $_" }
    }

    'uninstall' {
        Step "先执行卸载清理（立即恢复系统默认充电行为）"
        Invoke-Dev "sh $ModDir/uninstall.sh" | ForEach-Object { Write-Host "    $_" }
        Step "标记为待移除（Magisk 标准流程，重启后模块彻底消失）"
        Invoke-Dev "touch $ModDir/remove" | Out-Null
        Invoke-Dev "rm -rf /data/adb/modules_update/battery_guard" | Out-Null
        Ok "已恢复默认充电。重启后模块将从 Magisk 中消失。"
    }

    'purge' {
        Step "卸载清理 + 删除配置与日志"
        Invoke-Dev "sh $ModDir/uninstall.sh" | ForEach-Object { Write-Host "    $_" }
        Invoke-Dev "touch $ModDir/remove" | Out-Null
        Invoke-Dev "rm -rf $PersistDir /data/adb/modules_update/battery_guard" | Out-Null
        Ok "配置、日志、节点记录已全部清除，重启后模块消失"
    }

    default {
        Err "未知命令: $Cmd"
        Show-Usage
        exit 1
    }
}
