#Requires -Version 5.1
<#
.SYNOPSIS
    GPU 热降频自动解锁器：检测到 SW Thermal Slowdown 锁死后，
    用 OemWMIfun 的 SetTurboMode(false→true) 复现 Fn+P 切换，重置 TGP。

.DESCRIPTION
    背景：高能用 GPU 撞 87°C 温度墙后进入 SW Thermal Slowdown，TGP 从 55W 锁到 30W。
          该状态带迟滞，温度回落也不会自动解除；用户实测需切到平衡再切回高能才能短暂恢复。
          本脚本把这两个动作自动化。

    检测判据（比功耗推算更精确）：
        nvidia-smi --query-gpu=clocks_event_reasons.sw_thermal_slowdown
        本机实测返回字符串：Active = 处于降频锁定；Not Active = 正常。
        （部分机型/驱动返回 1/0，解析已兼容。）

    解锁动作（OemWMIMethod.OemWMIfun，root\wmi）：
        参数 u8Input = 64 字节缓冲（前 2 字节 opcode 小端，第 3 字节参数）
        SetTurboMode(false) opcode 0x0F04 param 0 → 切到平衡（TGP 恢复 40W）
        等待 SettleMs
        SetTurboMode(true)  opcode 0x0F04 param 1 → 切回高能（TGP 短暂恢复 55W）

    注意：纯切换是"治标"——解锁后若不控温会再次撞墙，形成循环。
          -WithClockCap 会在解锁后施加时钟上限（nvidia-smi -lgc），
          把稳态压在温度墙下方，显著延长解锁后的持续时间。

.PARAMETER ThresholdHits
    连续检测到锁定的次数才触发切换（防抖动），默认 2。

.PARAMETER IntervalMs
    采样间隔，默认 2000ms。

.PARAMETER CooldownMs
    两次切换之间的最小间隔，默认 8000ms（避免切换风暴）。

.PARAMETER MaxSwitches
    最多切换次数，0=不限，默认 0。达到上限后只记录不再切换。

.PARAMETER WithClockCap
    解锁后施加时钟上限以控温，配合 -CapClock 使用。限频会一直保持，
    直到 GPU 占用持续低于 -ResumeUtilPct 达 -ResumeHits 次（负载结束）才复位，
    避免"Throttle 一清零就解除限频 → 又撞墙"的振荡。

.PARAMETER CapClock
    -WithClockCap 时的时钟上限 MHz，默认 1500。

.PARAMETER ResumeUtilPct
    判定"负载结束"的占用率阈值（%），默认 15。

.PARAMETER ResumeHits
    判定"负载结束"需连续低占用的采样次数，默认 8（间隔 2s 时约 16 秒）。

.PARAMETER DryRun
    只读：检测并打印，但绝不调用 WMI 写入，也不锁频。用于验证检测判据。

.PARAMETER SuppressOsd
    切换期间抑制性能模式 OSD 浮层。固件在 SetTurboMode 后会弹"已切换到性能模式"，
    高负载游戏中每次解锁闪两次。启用后：仅当 GPU 占用 >= -OsdSuppressUtilPct 时，
    在切换前挂起 OSD_Daemon.exe，等待 -OsdHoldMs 让浮层生命周期过去后再恢复。
    try/finally 保证异常/Ctrl+C 时也会恢复。

.PARAMETER OsdSuppressUtilPct
    触发 OSD 抑制的 GPU 占用阈值（%），默认 50。设为 0 表示每次切换都抑制。

.PARAMETER OsdHoldMs
    切换后保持 OSD_Daemon 挂起的时长（ms），默认 3000。需覆盖浮层显示时长。

.PARAMETER Seconds
    运行时长（秒），0=无限，默认 0。

.PARAMETER LogPath
    CSV 日志路径。
#>
[CmdletBinding()]
param(
    [int]$ThresholdHits = 2,
    [int]$IntervalMs = 2000,
    [int]$SettleMs = 1500,
    [int]$CooldownMs = 8000,
    [int]$MaxSwitches = 0,
    [switch]$WithClockCap,
    [int]$CapClock = 1500,
    [int]$ResumeUtilPct = 15,
    [int]$ResumeHits = 8,
    [int]$MinClock = 300,
    [switch]$DryRun,
    [switch]$SuppressOsd,
    [int]$OsdSuppressUtilPct = 50,
    [int]$OsdHoldMs = 3000,
    [int]$Seconds = 0,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

# 关闭当前控制台的 QuickEdit（鼠标选中文本会冻结进程输出，导致脚本"假死"）。
# 仅作用于本控制台窗口，不改注册表全局设置；非控制台环境会安全跳过。
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleQuickEdit {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
'@ -ErrorAction SilentlyContinue
    $hIn = [ConsoleQuickEdit]::GetStdHandle(-10)          # STD_INPUT_HANDLE
    $mode = [uint32]0
    if ([ConsoleQuickEdit]::GetConsoleMode($hIn, [ref]$mode)) {
        $mask = [uint32]4294967231                          # 0xFFFFFFBF (~0x0040)
        $newMode = ($mode -band $mask) -bor [uint32]128     # 清 ENABLE_QUICK_EDIT_MODE, 置 ENABLE_EXTENDED_FLAGS(0x80)
        [void][ConsoleQuickEdit]::SetConsoleMode($hIn, $newMode)
    }
} catch { }

if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'gpu-autoswitch-log.csv' }
$smi = 'C:\Windows\System32\nvidia-smi.exe'
if (-not (Test-Path $smi)) { throw "找不到 nvidia-smi: $smi" }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $DryRun -and -not $isAdmin) {
    Write-Host '需要管理员权限（WMI 写入 + 可选 -lgc 锁频）。先用 -DryRun 验证检测。' -ForegroundColor Red
    exit 1
}

# ---------- WMI 命令（已由 Honor PC Helper 源码校正：u8Input + 64 字节） ----------
# 源码 HonorWmi.cs: var input = new byte[64]; BitConverter.GetBytes(command).CopyTo(input,0);
# 参数名 u8Input 固定，长度必须 64 字节（8 字节会报"无效的参数"）。
function New-CmdBytes {
    param([int]$Opcode, [int[]]$Params = @())
    [byte[]]$bytes = New-Object byte[] 64
    $bytes[0] = [byte]($Opcode -band 0xFF)
    $bytes[1] = [byte](($Opcode -shr 8) -band 0xFF)
    for ($i = 0; $i -lt $Params.Count; $i++) { $bytes[$i+2] = [byte]($Params[$i] -band 0xFF) }
    return $bytes
}

$wmiInstance = $null
if (-not $DryRun) {
    $wmiInstance = Get-CimInstance -ClassName 'OemWMIMethod' -Namespace 'root\wmi' -ErrorAction Stop
    if (-not $wmiInstance) { throw '未找到 root\wmi:OemWMIMethod 实例' }
    Write-Host 'WMI 接口: OemWMIfun(u8Input[64])' -ForegroundColor DarkGray
}

function Invoke-WmiCmd {
    param([int]$Opcode, [int[]]$Params = @())
    $b = New-CmdBytes $Opcode $Params
    $r = Invoke-CimMethod -InputObject $wmiInstance -MethodName 'OemWMIfun' `
        -Arguments @{ u8Input = $b } -ErrorAction Stop
    $out = $r.u8Output
    $ok = ($null -ne $out) -and ($out.Count -gt 0) -and ($out[0] -eq 0)
    return [pscustomobject]@{ Ok = $ok; ReturnValue = $r.ReturnValue; Output = $out }
}

function Invoke-FnPToggle {
    $off = Invoke-WmiCmd 0x0F04 @(0)   # SetTurboMode(false)
    Start-Sleep -Milliseconds $SettleMs
    $on  = Invoke-WmiCmd 0x0F04 @(1)   # SetTurboMode(true)
    return ($off.Ok -and $on.Ok)
}

# ---------- OSD 抑制：挂起/恢复 OSD_Daemon.exe ----------
# 固件在每次 SetTurboMode 后发 OemWMIEvent → OSD_Daemon 弹"性能模式"浮层。
# 挂起进程后它无法处理事件，浮层不显示；恢复后可继续正常工作。
# 用 NtSuspendProcess/NtResumeProcess（ntdll 未导出但稳定存在的 API）。
$osdPid   = $null
$osdProc  = $null
$osdAdded = $false

function Add-OsdNative {
    if ($script:osdAdded) { return }
    $src = @'
using System;
using System.Runtime.InteropServices;
public static class OsdNative {
    [DllImport("ntdll.dll")]
    public static extern uint NtSuspendProcess(IntPtr ProcessHandle);
    [DllImport("ntdll.dll")]
    public static extern uint NtResumeProcess(IntPtr ProcessHandle);
}
'@
    try { Add-Type -TypeDefinition $src -ErrorAction Stop; $script:osdAdded = $true }
    catch { Write-Host ("OSD native 注入失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
}

function Suspend-Osd {
    $script:osdPid = $null
    $script:osdProc = $null
    $p = Get-Process -Name 'OSD_Daemon' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return $false }
    Add-OsdNative
    if (-not $script:osdAdded) { return $false }
    try {
        $h = $p.Handle
        $rc = [OsdNative]::NtSuspendProcess($h)
        if ($rc -eq 0) {
            $script:osdPid = $p.Id
            $script:osdProc = $p
            return $true
        }
        Write-Host ("NtSuspendProcess 失败 NTSTATUS=0x{0:X8}" -f $rc) -ForegroundColor Yellow
    } catch {
        Write-Host ("挂起 OSD_Daemon 异常: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    return $false
}

function Resume-Osd {
    if (-not $script:osdProc) { return }
    try {
        [void][OsdNative]::NtResumeProcess($script:osdProc.Handle)
        Write-Host ("OSD_Daemon 已恢复 (PID {0})" -f $script:osdPid) -ForegroundColor DarkGray
    } catch {
        Write-Host ("恢复 OSD_Daemon 异常: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    $script:osdProc = $null
    $script:osdPid = $null
}

# ---------- GPU 采样 ----------
function Get-GpuSample {
    $out = & $smi '--query-gpu=clocks_event_reasons.sw_thermal_slowdown,temperature.gpu,power.draw,clocks.sm,utilization.gpu' `
        '--format=csv,noheader,nounits' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $p = ($out -split ',') | ForEach-Object { $_.Trim() }
    if ($p.Count -lt 5) { return $null }
    $throttle = 0; $temp = 0; $pw = 0.0; $clk = 0; $util = 0
    # 实测：本机 nvidia-smi 的 sw_thermal_slowdown 返回字符串 "Active"/"Not Active"，
    # 不是文档里写的数字 1/0。TryParse 会把 "Active" 解析失败→0→永远判为未锁定。
    # 兼容三种表示：Active / 1 / True。
    $raw = $p[0]
    if ($raw -match '^\s*(Active|1|True)\s*$') { $throttle = 1 } else { $throttle = 0 }
    [void][int]::TryParse($p[1], [ref]$temp)
    [void][double]::TryParse($p[2], [ref]$pw)
    [void][int]::TryParse($p[3], [ref]$clk)
    [void][int]::TryParse($p[4], [ref]$util)
    [pscustomobject]@{ Throttle=$throttle; Temp=$temp; Power=$pw; Clock=$clk; Util=$util }
}

function Reset-Clock { & $smi -rgc 2>&1 | Out-Null }
function Set-ClockCap {
    param([int]$Cap)
    & $smi -lgc $MinClock $Cap 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ---------- 主循环 ----------
Write-Host ''
Write-Host '=== GPU 热降频自动解锁器 ===' -ForegroundColor Cyan
Write-Host ("检测: sw_thermal_slowdown 连续 {0} 次=1 → Fn+P 切换 | 间隔 {1}ms | 冷却 {2}ms{3}{4}" -f
    $ThresholdHits, $IntervalMs, $CooldownMs,
    $(if ($WithClockCap) { " | 解锁后锁频上限 ${CapClock}MHz" } elseif ($DryRun) { ' | [只读]' } else { '' }),
    $(if ($SuppressOsd) { " | OSD抑制:GPU>=$OsdSuppressUtilPct% 切换时挂起 ${OsdHoldMs}ms" } else { '' })) -ForegroundColor Cyan
Write-Host '按 Ctrl+C 停止（退出时自动复位锁频）。' -ForegroundColor DarkGray
Write-Host ''

$hits = 0
$switches = 0
$lastSwitch = [datetime]::MinValue
$capApplied = $false
$lowUtilHits = 0
$rows = New-Object System.Collections.Generic.List[object]
$failCount = 0

try {
    $deadline = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [datetime]::MaxValue }
    while ((Get-Date) -lt $deadline) {
        $s = Get-GpuSample
        if ($null -eq $s) {
            $failCount++
            if ($failCount -ge 5) { Write-Host '连续读取失败，退出。' -ForegroundColor Red; break }
            Start-Sleep -Milliseconds $IntervalMs
            continue
        }
        $failCount = 0

        $action = ''
        if ($s.Throttle -eq 1) {
            $hits++
            $action = "锁定x$hits"
        }
        else {
            if ($hits -gt 0) { $action = '已解除' }
            $hits = 0
        }

        # 限频保持逻辑：仅当"负载确实结束"（占用持续走低）才复位，
        # 不能只看 Throttle=0——否则限频一生效、温度回落、Throttle 清零后
        # 立即复位 → GPU 又自由跑 → 又撞墙，形成切换振荡。
        if ($capApplied -and -not $DryRun) {
            if ($s.Util -lt $ResumeUtilPct) { $lowUtilHits++ } else { $lowUtilHits = 0 }
            if ($lowUtilHits -ge $ResumeHits) {
                Reset-Clock
                $capApplied = $false
                $lowUtilHits = 0
                $action += '(负载结束,复位锁频)'
            }
        }

        $canSwitch = ($hits -ge $ThresholdHits) -and
                     ((Get-Date) - $lastSwitch).TotalMilliseconds -ge $CooldownMs -and
                     ($MaxSwitches -eq 0 -or $switches -lt $MaxSwitches)

        if ($canSwitch) {
            if ($DryRun) {
                $action += ' [DRYRUN:将切换]'
            }
            else {
                # 仅在 GPU 占用达阈值时才抑制 OSD（避免低负载/桌面误伤）
                $osdHeld = $false
                if ($SuppressOsd -and $s.Util -ge $OsdSuppressUtilPct) {
                    $osdHeld = Suspend-Osd
                    if ($osdHeld) { $action += '[OSD挂起]' }
                }
                $ok = Invoke-FnPToggle
                if ($osdHeld) {
                    Start-Sleep -Milliseconds $OsdHoldMs
                    Resume-Osd
                }
                $switches++
                $lastSwitch = Get-Date
                $action += $(if ($ok) { " [切换#$switches OK]" } else { " [切换#$switches 失败]" })
                if ($WithClockCap) {
                    if (Set-ClockCap $CapClock) {
                        $capApplied = $true
                        $action += "[锁频$CapClock]"
                    }
                }
            }
            $hits = 0
        }

        $row = [pscustomobject]@{
            Time=(Get-Date).ToString('HH:mm:ss'); Throttle=$s.Throttle; Temp=$s.Temp
            Power=[math]::Round($s.Power,1); Clock=$s.Clock; Util=$s.Util
            Switch=$switches; Action=$action
        }
        $rows.Add($row) | Out-Null
        $color = if ($s.Throttle -eq 1) { 'Red' } elseif ($s.Temp -ge 84) { 'Yellow' } else { 'Gray' }
        Write-Host ("{0}  锁定={1}  {2,3}°C  {3,5}W  {4,4}MHz  占用{5,3}%  切换#{6}  {7}" -f
            $row.Time, $s.Throttle, $row.Temp, $row.Power, $row.Clock, $row.Util, $row.Switch, $action) -ForegroundColor $color

        Start-Sleep -Milliseconds $IntervalMs
    }
}
finally {
    # 安全网：任何异常/Ctrl+C 退出都确保 OSD 不被留在挂起态
    if ($script:osdProc) { Resume-Osd }
    if ($capApplied -and -not $DryRun) {
        Write-Host '复位锁频…' -ForegroundColor Yellow
        Reset-Clock
    }
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8 -Append
        Write-Host ("已记录 {0} 行 -> {1}" -f $rows.Count, $LogPath) -ForegroundColor Green
    }
}
