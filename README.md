# GPU AutoUnlock — 荣耀笔记本热降频自动解锁

检测 NVIDIA GPU 进入 `SW Thermal Slowdown`（55W 被锁到 30W）后，自动软件复现 `Fn+P` 切档动作，把功耗恢复到 55W；切换瞬间抑制 HONOR 性能模式 OSD 浮层，避免游戏中反复闪烁。

## 背景

荣耀 HYM-WXX（HalleyM，R7 5800H + RTX 3050）在高能模式下 GPU 撞 87°C 温度墙后进入软件热降频锁定，TGP 从 55W 掉到 30W，且带迟滞——温度回落也不会自动解除。实测手动按 `Fn+P` 切到平衡再切回高能可短暂恢复。本工具把这一操作自动化。

**重要**：纯切换是治标——解锁后功耗回满，持续负载会再次撞墙、再次切换。这是"不锁频"方案的预期行为。

## 环境要求

- HONOR / 荣耀笔记本，固件提供 `root\wmi:OemWMIMethod.OemWMIfun` 接口（`u8Input` 为 64 字节数组）
- Windows 10/11，PowerShell 5.1（脚本开头 `#Requires -Version 5.1`）
- NVIDIA 驱动自带 `C:\Windows\System32\nvidia-smi.exe`
- **管理员权限**（WMI 写入需要；启动器会自动 UAC 提权）

## 文件清单

| 文件 | 作用 |
|---|---|
| `Run-GPU-AutoUnlock.bat` | **懒人入口**：双击即用，自动提权，纯切换不锁频 + OSD 抑制 |
| `Set-GpuAutoSwitch.ps1` | 主程序：GPU 采样、锁定检测、Fn+P 切换、OSD 挂起、CSV 日志 |
| `Invoke-HonorWmiProbeV4.ps1` | WMI 探测器：只读查模式/风扇/温度；`-WriteProbe` 验证写入；`-RestoreOnly` 恢复高能 |
| `Test-OsdSuspend.ps1` | OSD 挂起自检（不写 WMI），验证抑制方案是否适用 |

## 快速开始

1. 把四个文件放在同一个文件夹（不要只复制 bat）。
2. **双击 `Run-GPU-AutoUnlock.bat`**，UAC 弹窗点"是"。
3. 最小化窗口，进游戏即可。停止：窗口内 `Ctrl+C` 或直接关闭。

启动器已固定为 `-SuppressOsd -MaxSwitches 0`：**不锁频**、无限切换次数、GPU 占用 ≥50% 时抑制 OSD。

首次使用建议先自检（管理员 PowerShell，在同一文件夹）：

```powershell
# 1) 确认 OSD 挂起有效：8 秒内按几次音量键/Fn+P，浮层应完全不出现
.\Test-OsdSuspend.ps1

# 2) 只读验证锁定判据：游戏撞墙后跑，看"锁定"是否变 1
.\Set-GpuAutoSwitch.ps1 -DryRun -Seconds 20
```

## 运行输出示例

```
=== GPU 热降频自动解锁器 ===
检测: sw_thermal_slowdown 连续 2 次=1 → Fn+P 切换 | 间隔 2000ms | 冷却 8000ms | OSD抑制:GPU>=50% 切换时挂起 3000ms
01:24:21  锁定=1   67°C   29.8W  1372MHz  占用 99%  切换#0  锁定x1
01:24:28  锁定=1   68°C   29.9W  1440MHz  占用 82%  切换#1  锁定x2[OSD挂起] [切换#1 OK]
01:24:31  锁定=0   72°C   53.3W  1897MHz  占用 98%  切换#1
```

## 工作原理

1. **检测**：`nvidia-smi --query-gpu=clocks_event_reasons.sw_thermal_slowdown` 返回 `Active` / `Not Active`（本机是字符串，不是数字；脚本已兼容 `Active|1|True`）。连续 `ThresholdHits` 次判定为锁定。
2. **解锁**：经 `OemWMIfun(u8Input[64])` 依次写 `SetTurboMode(false)` → 等 `SettleMs` → `SetTurboMode(true)`，复现 Fn+P 的"平衡→高能"往返，重置 TGP。
3. **OSD 抑制**：切换前用 `NtSuspendProcess` 挂起 `OSD_Daemon.exe`，等 `OsdHoldMs` 让固件浮层生命周期过去后恢复。`try/finally` 保证异常或 Ctrl+C 也不会把 OSD 留在挂起态。
4. **防抖**：切换间隔受 `CooldownMs` 限制；主循环启动时关闭当前控制台的 QuickEdit，防止鼠标误选导致"假死"。

## 参数速查（`Set-GpuAutoSwitch.ps1`）

| 参数 | 默认 | 说明 |
|---|---|---|
| `-SuppressOsd` | 关 | 切换时抑制 OSD 浮层（启动器已开启） |
| `-OsdSuppressUtilPct` | 50 | GPU 占用 ≥ 此值才抑制，低负载不误伤 |
| `-OsdHoldMs` | 3000 | 挂起保持时长，浮层有残留可调到 4000 |
| `-WithClockCap` / `-CapClock` | 关 / 1500 | 解锁后锁频控温；负载结束才复位，避免振荡 |
| `-ResumeUtilPct` / `-ResumeHits` | 15 / 8 | 判定"负载结束"的阈值与连续次数 |
| `-MaxSwitches` | 0(无限) | 保守测试设 5 |
| `-ThresholdHits` | 2 | 连续锁定几次才触发 |
| `-IntervalMs` / `-CooldownMs` | 2000 / 8000 | 采样间隔 / 切换最小间隔 |
| `-Seconds` | 0(无限) | 限定运行时长 |
| `-DryRun` | 关 | 只读，不切不锁频 |

想稳态控温（少撞墙、少切换）时手动运行：

```powershell
.\Set-GpuAutoSwitch.ps1 -SuppressOsd -WithClockCap -CapClock 1500
```

## 排错

| 现象 | 处理 |
|---|---|
| 脚本卡住不动、CPU 占用极低 | 控制台 QuickEdit 冻结输出；按 `Esc`/回车，脚本已内置启动关闭。窗口内右键 → 属性可永久关闭"快速编辑模式" |
| 被锁 30W 但从不切换 | 跑 `-DryRun` 看 `锁定=` 是否为 1；若恒为 0，检查 nvidia-smi 该字段的实际返回文本 |
| 切换后 OSD 不出现/出现残留 | 调 `-OsdHoldMs`（2500–4000）；用 `Test-OsdSuspend.ps1` 复验 |
| 中文乱码 / "缺少 using 指令" | 必须用 PowerShell 5.1；`.ps1` 必须保留 **UTF-8 BOM**，`.bat` 必须**无 BOM 且纯 ASCII** |
| 强杀进程后 OSD 卡住或频率未复位 | `nvidia-smi -rgc` 复位频率；`.\Invoke-HonorWmiProbeV4.ps1 -RestoreOnly` 切回高能 |

## 免责声明

本项目通过厂商私有 WMI 接口切换性能模式并挂起系统进程，仅适用于上述特定机型/固件。不同机型 opcode 或 OSD 进程名可能不同，请先只读探测再写入。使用者自行承担风险。
