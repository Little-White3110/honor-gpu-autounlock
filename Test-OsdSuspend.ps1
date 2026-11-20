#Requires -Version 5.1
<#
.SYNOPSIS
    OSD 挂起/恢复自检：验证 NtSuspendProcess 能冻结 OSD_Daemon 且能干净恢复。

.DESCRIPTION
    只读式验证，不写 WMI、不改任何模式。流程：
      1) 找到 OSD_Daemon.exe
      2) 挂起 N 秒（这段时间可以手动按 Fn+P / 音量键，观察浮层是否完全不出现）
      3) finally 恢复进程
    用来在进游戏前确认"挂起 OSD"这条路走得通、且不会把 OSD 卡死。

.PARAMETER Seconds
    挂起时长（秒），默认 8。

.PARAMETER NoSuspend
    只报告 OSD_Daemon 进程状态，不挂起（纯探测）。
#>
[CmdletBinding()]
param(
    [int]$Seconds = 8,
    [switch]$NoSuspend
)

$ErrorActionPreference = 'Stop'
$p = Get-Process -Name 'OSD_Daemon' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { Write-Host '未找到 OSD_Daemon.exe 进程。' -ForegroundColor Red; exit 1 }

Write-Host ("OSD_Daemon: PID={0}  路径={1}" -f $p.Id, $p.Path) -ForegroundColor Cyan
if ($NoSuspend) { exit 0 }

$src = @'
using System;
using System.Runtime.InteropServices;
public static class OsdNativeTest {
    [DllImport("ntdll.dll")] public static extern uint NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] public static extern uint NtResumeProcess(IntPtr h);
}
'@
Add-Type -TypeDefinition $src -ErrorAction Stop

$resumed = $false
try {
    $h = $p.Handle
    $rc = [OsdNativeTest]::NtSuspendProcess($h)
    if ($rc -ne 0) { throw ("NtSuspendProcess 失败 NTSTATUS=0x{0:X8}" -f $rc) }
    Write-Host ("已挂起 OSD_Daemon {0} 秒 —— 现在按 Fn+P 或音量键，浮层应完全不出现。" -f $Seconds) -ForegroundColor Yellow
    Write-Host '（若浮层仍出现，说明它由别的进程绘制，此方案不适用。）' -ForegroundColor DarkGray
    Start-Sleep -Seconds $Seconds
}
finally {
    if (-not $resumed) {
        [void][OsdNativeTest]::NtResumeProcess($p.Handle)
        $resumed = $true
        Write-Host '已恢复 OSD_Daemon。按一次音量键确认浮层恢复正常。' -ForegroundColor Green
    }
}
