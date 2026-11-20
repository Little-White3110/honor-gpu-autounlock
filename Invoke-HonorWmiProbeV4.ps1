#Requires -Version 5.1
<#
.SYNOPSIS
    OemWMIfun 探测器 V4 —— 基于 Honor PC Helper 开源源码校正的最终版。
.DESCRIPTION
    V3 失败根因：u8Input 参数名正确，但传了 8 字节数组；固件期望
    固定 64 字节 uint8[]（源码 HonorWmi.cs: var input = new byte[64]）。
    "无效的参数" = 参数名对、长度错。本版修正为 64 字节。

    命令编码（源码逐条核对，u64 小端，参数在 bit16）：
      GetTurboMode       0x0E04            -> out[1] = 模式 (0=智能, 1=性能/高能, 3=HUNTER)
      SetTurboMode       0x0F04 | val<<16  val: 1=开高能, 0=关(智能/平衡)
      GetFanSpeed        0x0802 | idx<<16  -> out[1]|out[2]<<8 = 实际转速, out[3]|out[4]<<8 = 目标
      GetSensorTemp      0x0202 | idx<<16  -> out[2] = 温度

    成功判据：out[0] == 0；非 0 = BIOS 拒绝该命令（该机型不支持）。
.PARAMETER WriteProbe
    执行 SetTurboMode(false -> true) 往返，验证能否软件复现 Fn+P。
.PARAMETER RestoreOnly
    只切回高能。
.PARAMETER SettleMs
    两次切换之间的等待毫秒。
#>
[CmdletBinding()]
param(
    [switch]$WriteProbe,
    [switch]$RestoreOnly,
    [int]$SettleMs = 1500
)

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '需要管理员权限。请以管理员身份运行。' -ForegroundColor Red
    exit 1
}

$instance = Get-CimInstance -ClassName 'OemWMIMethod' -Namespace 'root\wmi' -ErrorAction Stop
Write-Host ("实例: {0}" -f $instance.InstanceName) -ForegroundColor DarkGray

# 构造 64 字节输入缓冲（关键修复点）
function New-Input64 {
    param([int]$Opcode, [int]$Param = 0)
    [byte[]]$buf = New-Object byte[] 64
    $buf[0] = [byte]($Opcode -band 0xFF)
    $buf[1] = [byte](($Opcode -shr 8) -band 0xFF)
    $buf[2] = [byte]($Param -band 0xFF)
    return $buf
}

function Invoke-Cmd {
    param([string]$Name, [int]$Opcode, [int]$Param = 0)
    $input64 = New-Input64 $Opcode $Param
    $r = Invoke-CimMethod -InputObject $instance -MethodName 'OemWMIfun' `
        -Arguments @{ u8Input = $input64 } -ErrorAction Stop
    $out = $r.u8Output
    $hex = if ($null -eq $out) { '(null)' } else { ($out | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }
    $first = if ($out -and $out.Count -gt 0) { $out[0] } else { '-' }
    $ok = ($first -eq 0)
    Write-Host ("  {0,-22} ret={1} ok={2} out=[{3}]" -f $Name, $r.ReturnValue, $ok, $hex) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'DarkYellow' })
    return [pscustomobject]@{ Ok = $ok; Out = $out; First = $first }
}

function Get-Mode {
    param([int]$Opcode, [int]$Param = 0)
    $input64 = New-Input64 $Opcode $Param
    $r = Invoke-CimMethod -InputObject $instance -MethodName 'OemWMIfun' `
        -Arguments @{ u8Input = $input64 } -ErrorAction Stop
    return $r.u8Output
}

Write-Host ''
Write-Host '=== 只读探测 ===' -ForegroundColor Cyan

# 性能模式
$o = Get-Mode 0x0E04
if ($o -and $o.Count -gt 1) {
    $ok = $o[0] -eq 0
    Write-Host ("  GetTurboMode          ok={0} 模式值={1}  (1=高能/性能, 0=平衡)" -f $ok, $o[1]) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'DarkYellow' })
} else {
    Write-Host '  GetTurboMode          无有效返回' -ForegroundColor DarkYellow
}

# 风扇
foreach ($idx in 0,1) {
    $o = Get-Mode 0x0802 $idx
    if ($o -and $o.Count -ge 3) {
        $rpm = $o[1] -bor ($o[2] -shl 8)
        $tgt = if ($o.Count -ge 5) { $o[3] -bor ($o[4] -shl 8) } else { 0 }
        Write-Host ("  风扇{0}                 ok={1} 实际={2} rpm 目标={3} rpm" -f ($idx+1), ($o[0] -eq 0), $rpm, $tgt) `
            -ForegroundColor $(if ($o[0] -eq 0) { 'Green' } else { 'DarkYellow' })
    }
}

# 温度（源码 HardwareSensors.cs: zone 0x00=CPU, 0x0E=电池）
foreach ($z in @(@{n='CPU';id=0x00}, @{n='电池';id=0x0E})) {
    $o = Get-Mode 0x0202 $z.id
    if ($o -and $o.Count -ge 3) {
        Write-Host ("  温度-{0,-4}             ok={1} {2} C" -f $z.n, ($o[0] -eq 0), $o[2]) `
            -ForegroundColor $(if ($o[0] -eq 0) { 'Green' } else { 'DarkYellow' })
    }
}

if ($RestoreOnly) {
    Write-Host ''
    Write-Host '=== 恢复高能 ===' -ForegroundColor Yellow
    Invoke-Cmd 'SetTurboMode(true)'  0x0F04 1 | Out-Null
    exit 0
}

if ($WriteProbe) {
    Write-Host ''
    Write-Host '=== 写入探测：关高能(false) -> 开高能(true) ===' -ForegroundColor Yellow
    Invoke-Cmd 'SetTurboMode(false)' 0x0F04 0 | Out-Null
    Start-Sleep -Milliseconds $SettleMs
    $mid = Get-Mode 0x0E04
    Write-Host ("  中间态模式值: {0}" -f $(if ($mid -and $mid.Count -gt 1) { $mid[1] } else { '?' }))
    Start-Sleep -Milliseconds $SettleMs
    Invoke-Cmd 'SetTurboMode(true)'  0x0F04 1 | Out-Null
    Start-Sleep -Milliseconds $SettleMs
    $fin = Get-Mode 0x0E04
    Write-Host ("  终态模式值:   {0}" -f $(if ($fin -and $fin.Count -gt 1) { $fin[1] } else { '?' }))
    Write-Host '（若桌面弹出性能模式 OSD 图标，即证明软件入口 = Fn+P）' -ForegroundColor DarkGray
}
else {
    Write-Host ''
    Write-Host '（未加 -WriteProbe，无写入）' -ForegroundColor DarkGray
}
