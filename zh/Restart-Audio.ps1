<#
    Restart-Audio.ps1  v1.0
    不重启电脑，彻底重载 Realtek（或指定厂商）音频驱动栈，效果等同开机时重新枚举音频设备。

    用法（普通命令行）：
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -TestTone
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -DryRun
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -DeviceMatch VEN_10EC

    参数：
      -DeviceMatch  设备 InstanceId 里用于识别厂商的片段，默认 VEN_10EC（Realtek）
      -TestTone     完成后播放 0.5 秒低音量测试音，实际验证音频链路
      -DryRun       只做检测与预演，不改动任何服务或设备

    退出码：0 = 成功；1 = 环境/参数错误；2 = 执行或验证失败
#>

param(
    [string]$DeviceMatch = 'VEN_10EC',
    [switch]$TestTone,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

$script:Redir = $false
try { $script:Redir = [Console]::IsOutputRedirected } catch { }
if ($script:Redir) { try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { } }

$script:LogFile = Join-Path $PSScriptRoot ('audio_restart_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
$script:Failures = New-Object System.Collections.ArrayList
$script:ServiceStates = @{}
$script:TotalSteps = 7

function Write-Line {
    param([string]$Text, [string]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text
    if ($script:Redir) { Write-Output $line } else { Write-Host $line -ForegroundColor $Color }
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

function Write-Step {
    param([int]$Index, [string]$Text)
    Write-Line ('[{0}/{1}] {2}' -f $Index, $script:TotalSteps, $Text) 'Cyan'
}

function Write-Ok {
    param([string]$Text)
    Write-Line ('      [OK]   ' + $Text) 'Green'
}

function Write-Warn {
    param([string]$Text)
    Write-Line ('      [WARN] ' + $Text) 'Yellow'
}

function Write-Bad {
    param([string]$Text)
    Write-Line ('      [FAIL] ' + $Text) 'Red'
    [void]$script:Failures.Add($Text)
}

function Write-Info {
    param([string]$Text)
    Write-Line ('             ' + $Text) 'DarkGray'
}

# ---------------------------------------------------------------- 设备查询

function Get-PnpParent {
    param([string]$InstanceId)
    try {
        $v = (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
        if ($v) { return [string]$v }
    } catch { }
    return $null
}

function Resolve-RestartTarget {
    param([string]$FuncId)

    $chain = New-Object System.Collections.ArrayList
    [void]$chain.Add($FuncId)
    $cur = $FuncId
    for ($i = 0; $i -lt 4; $i++) {
        $p = Get-PnpParent $cur
        if (-not $p) { break }
        [void]$chain.Add($p)
        if ($p -match '^(PCI|ACPI|ROOT)\\') { break }
        $cur = $p
    }

    # 1) Intel SST 音频 DSP 控制器：重启它会连带拆掉并重新枚举整条子设备链，最彻底
    foreach ($id in $chain) {
        if ($id -like 'INTELAUDIO\DSP_CTLR_*') { return [pscustomobject]@{ Target = $id; Chain = $chain; Reason = 'Intel SST 音频 DSP 控制器（父设备，可重新枚举全部子设备）' } }
    }
    # 2) 其他音频总线控制器
    foreach ($id in $chain) {
        if ($id -like 'HDAUDIO\*' -and $id -notlike 'HDAUDIO\FUNC_*') { return [pscustomobject]@{ Target = $id; Chain = $chain; Reason = 'HD Audio 总线控制器' } }
    }
    # 3) 父设备若是 PCI 上的音频控制器（Class=MEDIA），也可作为重载目标
    for ($i = 1; $i -lt $chain.Count; $i++) {
        $id = $chain[$i]
        if ($id -match '^PCI\\') {
            $cls = $null
            try { $cls = (Get-PnpDevice -InstanceId $id -ErrorAction Stop).Class } catch { }
            if ($cls -eq 'MEDIA') { return [pscustomobject]@{ Target = $id; Chain = $chain; Reason = 'PCI 音频控制器' } }
        }
    }
    # 4) 兜底：只重启功能设备本身
    return [pscustomobject]@{ Target = $FuncId; Chain = $chain; Reason = '未找到音频控制器，回退为重启设备本身' }
}

# ---------------------------------------------------------------- 服务与进程

function Wait-ServiceState {
    param([string]$Name, [string]$State, [int]$TimeoutSec = 30)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $s) { return $false }
        if ($s.Status -eq $State) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Get-AudioServices {
    $list = New-Object System.Collections.ArrayList
    foreach ($n in @('AudioEndpointBuilder', 'Audiosrv')) {
        if (Get-Service -Name $n -ErrorAction SilentlyContinue) { [void]$list.Add($n) }
    }
    $vendor = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*Rtk*' -or $_.Name -like '*Realtek*' }
    foreach ($v in $vendor) { [void]$list.Add($v.Name) }
    return $list
}

# ---------------------------------------------------------------------------------------------------- 音频端点

function Get-EndpointInfo {
    param([string]$Kind)
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\' + $Kind
    $active = New-Object System.Collections.ArrayList
    foreach ($k in (Get-ChildItem -Path $path -ErrorAction SilentlyContinue)) {
        $st = $null
        try { $st = (Get-ItemProperty -Path $k.PSPath -ErrorAction Stop).DeviceState } catch { }
        if ($st -eq 1) {
            $nm = $null
            try { $nm = (Get-ItemProperty -Path (Join-Path $k.PSPath 'Properties') -ErrorAction Stop).'{b3f8fa53-0004-438e-9003-51a46e139bfc},6' } catch { }
            if (-not $nm) { $nm = '(未命名端点)' }
            [void]$active.Add($nm)
        }
    }
    return $active
}

function Get-DefaultRenderEndpoint {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class MMDeviceEnumeratorComObject { }

[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
interface IMMDeviceEnumerator
{
    int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, [MarshalAs(UnmanagedType.Interface)] out IMMDevice device);
}

[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")]
interface IMMDevice
{
    int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    int OpenPropertyStore(int access, out IntPtr props);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    int GetState(out int state);
}

public static class AudioRestartCheck {
    public static string DefaultRender() {
        var e = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
        IMMDevice d;
        int hr = e.GetDefaultAudioEndpoint(0, 0, out d);
        if (hr != 0) return "GetDefaultAudioEndpoint 失败 0x" + hr.ToString("X8");
        int st; d.GetState(out st);
        string id; d.GetId(out id);
        return id + " (state=" + st + ")";
    }
}
'@ -ErrorAction Stop
    } catch { }

    try { return [AudioRestartCheck]::DefaultRender() } catch { return 'N/A' }
}

function Invoke-TestTone {
    $rate = 44100
    $seconds = 0.5
    $freq = 440
    $amp = 0.18
    $n = [int]($rate * $seconds)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bytes = $n * 2
    $bw.Write([byte[]](0x52, 0x49, 0x46, 0x46))
    $bw.Write([int](36 + $bytes))
    $bw.Write([byte[]](0x57, 0x41, 0x56, 0x45))
    $bw.Write([byte[]](0x66, 0x6D, 0x74, 0x20))
    $bw.Write([int]16)
    $bw.Write([int16]1)
    $bw.Write([int16]1)
    $bw.Write([int]$rate)
    $bw.Write([int]($rate * 2))
    $bw.Write([int16]2)
    $bw.Write([int16]16)
    $bw.Write([byte[]](0x64, 0x61, 0x74, 0x61))
    $bw.Write([int]$bytes)
    for ($i = 0; $i -lt $n; $i++) {
        $v = [int](32767 * $amp * [Math]::Sin(2 * [Math]::PI * $freq * $i / $rate))
        $bw.Write([int16]$v)
    }
    $bw.Flush()
    $ms.Position = 0
    $sp = New-Object System.Media.SoundPlayer($ms)
    $sp.PlaySync()
}

# ================================================================ 主流程

Write-Line '==================================================================' 'Cyan'
Write-Line (' 音频驱动栈彻底重载   ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) 'Cyan'
Write-Line '==================================================================' 'Cyan'

# ---- 0. 权限
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }

if (-not $isAdmin -and -not $DryRun) {
    Write-Line '需要管理员权限，正在请求提升...' 'Yellow'
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($TestTone) { $arg = $arg + ' -TestTone' }
    if ($DeviceMatch -ne 'VEN_10EC') { $arg = $arg + ' -DeviceMatch "' + $DeviceMatch + '"' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arg -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Line ('提升失败：' + $_.Exception.Message) 'Red'
        exit 1
    }
    exit 0
}

if (-not (Get-Command pnputil.exe -ErrorAction SilentlyContinue)) {
    Write-Line '未找到 pnputil.exe，本工具需要 Windows 10 1903 及以上版本。' 'Red'
    exit 1
}

# ---- 1. 定位设备
Write-Step 1 '定位音频设备与驱动控制器'

$allDev = Get-PnpDevice -ErrorAction SilentlyContinue
# 只在音频设备范围内匹配：Realtek 的有线网卡同样是 VEN_10EC，不能只按厂商 ID 取设备
$audioDev = $allDev | Where-Object { $_.Class -eq 'MEDIA' -or $_.InstanceId -like 'INTELAUDIO\FUNC_*' -or $_.InstanceId -like 'HDAUDIO\FUNC_*' }
$cand = $audioDev | Where-Object { $_.InstanceId -like ('*' + $DeviceMatch + '*') }
if (-not $cand) {
    Write-Warn ('未匹配到 InstanceId 含 ' + $DeviceMatch + ' 的设备，改用名称匹配 Realtek')
    $cand = $audioDev | Where-Object { $_.FriendlyName -like '*Realtek*' }
}
$func = $cand | Where-Object { $_.Status -eq 'OK' } | Select-Object -First 1
if (-not $func) { $func = $cand | Select-Object -First 1 }
if (-not $func) {
    Write-Bad ('未找到匹配 ' + $DeviceMatch + ' 的音频设备')
    Write-Line ('结果：失败（未找到设备）；日志：' + $script:LogFile) 'Red'
    exit 2
}

Write-Info ('设备：' + $func.FriendlyName + '  [' + $func.InstanceId + ']')

$res = Resolve-RestartTarget -FuncId $func.InstanceId
$target = $res.Target

Write-Info ('父链：' + (($res.Chain | Select-Object -Skip 1) -join '  ->  '))
Write-Info ('重载目标：' + $target)
Write-Info ('选择理由：' + $res.Reason)

if (-not $target -or $target.Trim() -eq '') {
    Write-Bad '重载目标 InstanceId 为空，已中止（禁止对空参数调用 pnputil）'
    Write-Line ('结果：失败（目标为空）；日志：' + $script:LogFile) 'Red'
    exit 2
}

$arrBefore = $null
try { $arrBefore = (Get-PnpDeviceProperty -InstanceId $target -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction Stop).Data } catch { }
Write-Info ('设备到达时间（当前）：' + $arrBefore)

$svcList = Get-AudioServices
Write-Info ('音频服务：' + ($svcList -join ', '))
foreach ($n in $svcList) {
    try { $script:ServiceStates[$n] = (Get-Service -Name $n).StartType } catch { }
}

if ($DryRun) {
    Write-Line '' 
    Write-Line '[DryRun] 检测完成，未改动任何服务或设备。' 'Yellow'
    Write-Line ('日志：' + $script:LogFile) 'Gray'
    exit 0
}

# ---- 2. 停止服务
Write-Step 2 '停止音频服务（逆依赖顺序）'
$stopOrder = @()
foreach ($n in $svcList) { if ($n -ne 'AudioEndpointBuilder' -and $n -ne 'Audiosrv') { $stopOrder += $n } }
if ($svcList -contains 'Audiosrv') { $stopOrder += 'Audiosrv' }
if ($svcList -contains 'AudioEndpointBuilder') { $stopOrder += 'AudioEndpointBuilder' }

foreach ($n in $stopOrder) {
    try {
        $s = Get-Service -Name $n -ErrorAction Stop
        if ($s.Status -eq 'Stopped') { Write-Ok ($n + ' 已是停止状态'); continue }
        Stop-Service -Name $n -Force -ErrorAction Stop
        if (Wait-ServiceState -Name $n -State 'Stopped' -TimeoutSec 30) { Write-Ok ($n + ' 已停止') }
        else { Write-Warn ($n + ' 停止超时（继续执行）') }
    } catch {
        Write-Warn ($n + ' 停止失败：' + $_.Exception.Message)
    }
}

# ---- 3. 结束用户态进程
Write-Step 3 '结束音频用户态进程，释放设备占用'
$procNames = @('RtkAudUService64', 'RtkNGUI64', 'RtkUWP', 'audiodg')
foreach ($pn in $procNames) {
    $ps = Get-Process -Name $pn -ErrorAction SilentlyContinue
    if ($ps) {
        try {
            $ps | Stop-Process -Force -ErrorAction Stop
            Write-Ok ('已结束 ' + $pn + '（' + $ps.Count + ' 个进程）')
        } catch { Write-Warn ($pn + ' 结束失败：' + $_.Exception.Message) }
    }
}
Start-Sleep -Seconds 1

# ---- 4. 重载驱动
Write-Step 4 '重载驱动（卸载并重新枚举音频设备链）'
$restarted = $false
try {
    $out = & pnputil.exe /restart-device $target 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String)
    if (($code -eq 0) -and ($text -match 'restarted successfully') -and ($text -match [Regex]::Escape($target))) {
        $restarted = $true
        Write-Ok 'pnputil 已确认重载该设备（回显包含完整 InstanceId）'
    } else {
        Write-Warn ('pnputil 返回异常：code=' + $code + '，改为禁用/启用方式重载')
        Write-Info (($out | Select-Object -First 6) -join ' / ')
    }
} catch {
    Write-Warn ('pnputil 执行异常：' + $_.Exception.Message + '，改为禁用/启用方式重载')
}

if (-not $restarted) {
    try {
        & pnputil.exe /disable-device $target 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        & pnputil.exe /enable-device $target 2>&1 | Out-Null
        Start-Sleep -Seconds 4
        $restarted = $true
        Write-Ok '已通过 禁用 → 启用 完成设备重载'
    } catch {
        Write-Bad ('设备重载失败：' + $_.Exception.Message)
    }
}

Start-Sleep -Seconds 6

$arrAfter = $null
try { $arrAfter = (Get-PnpDeviceProperty -InstanceId $target -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction Stop).Data } catch { }
if ($arrBefore -and $arrAfter -and ($arrAfter -ne $arrBefore)) {
    Write-Ok ('设备已重新枚举：到达时间 ' + $arrBefore + '  ->  ' + $arrAfter)
} elseif ($restarted) {
    Write-Warn ('到达时间未变化（' + $arrAfter + '），请结合后续功能验证判断')
}

$funcAfter = $null
for ($i = 0; $i -lt 12; $i++) {
    $funcAfter = Get-PnpDevice -InstanceId $func.InstanceId -ErrorAction SilentlyContinue
    if ($funcAfter -and $funcAfter.Status -eq 'OK') { break }
    Start-Sleep -Seconds 2
}

if ($funcAfter -and $funcAfter.Status -eq 'OK') {
    Write-Ok ('设备已恢复：' + $funcAfter.FriendlyName + ' 状态 OK')
} else {
    Write-Warn '设备未按时恢复，尝试重新启用'
    try {
        & pnputil.exe /enable-device $func.InstanceId 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        $funcAfter = Get-PnpDevice -InstanceId $func.InstanceId -ErrorAction SilentlyContinue
    } catch { }
    if ($funcAfter -and $funcAfter.Status -eq 'OK') { Write-Ok '设备已重新启用并恢复 OK' }
    else { Write-Bad '设备未能恢复，请重启电脑以恢复音频' }
}

# ---- 5. 启动服务
Write-Step 5 '按依赖顺序启动音频服务'
foreach ($n in @('AudioEndpointBuilder', 'Audiosrv')) {
    if (-not ($svcList -contains $n)) { continue }
    try {
        $s = Get-Service -Name $n -ErrorAction Stop
        if ($s.Status -eq 'Running') { Write-Ok ($n + ' 已运行'); continue }
        Start-Service -Name $n -ErrorAction Stop
        if (Wait-ServiceState -Name $n -State 'Running' -TimeoutSec 40) { Write-Ok ($n + ' 已启动') }
        else { Write-Bad ($n + ' 启动超时') }
    } catch {
        Write-Bad ($n + ' 启动失败：' + $_.Exception.Message)
    }
}
foreach ($n in $svcList) {
    if ($n -eq 'AudioEndpointBuilder' -or $n -eq 'Audiosrv') { continue }
    try {
        $s = Get-Service -Name $n -ErrorAction Stop
        if ($s.Status -eq 'Running') { Write-Ok ($n + ' 已运行'); continue }
        Start-Service -Name $n -ErrorAction Stop
        Start-Sleep -Seconds 1
        if ((Get-Service -Name $n).Status -eq 'Running') { Write-Ok ($n + ' 已启动') }
        else { Write-Warn ($n + ' 未启动（不影响系统音频）') }
    } catch {
        Write-Warn ($n + ' 启动失败：' + $_.Exception.Message)
    }
}

Start-Sleep -Seconds 6

# ---- 6. 验证
Write-Step 6 '验证设备、服务与音频端点'

$problem = $null
try { $problem = (Get-PnpDeviceProperty -InstanceId $func.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data } catch { }
if ($problem -eq 0) { Write-Ok ('设备问题码 0（' + $func.FriendlyName + '）') }
elseif ($null -eq $problem -or $problem -eq '') { Write-Warn '未取到设备问题码' }
else { Write-Bad ('设备问题码 ' + $problem + '，驱动未正常加载') }

$svcOk = $true
$svcText = @()
foreach ($n in $svcList) {
    $st = 'Unknown'
    try { $st = (Get-Service -Name $n -ErrorAction Stop).Status } catch { $svcOk = $false }
    $svcText += ($n + '=' + $st)
    if ($st -ne 'Running') { $svcOk = $false }
}
if ($svcOk) { Write-Ok ('服务：' + ($svcText -join ', ')) }
else { Write-Bad ('服务状态异常：' + ($svcText -join ', ')) }

$render = Get-EndpointInfo -Kind 'Render'
$capture = Get-EndpointInfo -Kind 'Capture'
if ($render.Count -gt 0) {
    Write-Ok ('播放端点 ACTIVE ' + $render.Count + ' 个：' + (($render | Select-Object -First 4) -join ' / '))
} else { Write-Bad '没有任何 ACTIVE 播放端点' }
if ($capture.Count -gt 0) {
    Write-Ok ('录音端点 ACTIVE ' + $capture.Count + ' 个')
} else { Write-Warn '没有 ACTIVE 录音端点' }

$def = Get-DefaultRenderEndpoint
Write-Ok ('默认播放端点：' + $def)

# ---- 7. 试音与汇总
Write-Step 7 '汇总'
if ($TestTone) {
    try {
        Invoke-TestTone
        Write-Ok '测试音播放成功（音频链路可用）'
    } catch {
        Write-Bad ('测试音播放失败：' + $_.Exception.Message)
    }
} else {
    Write-Info '未启用测试音（加 -TestTone 可在完成后播放 0.5 秒验证音）'
}

Write-Line ''
if ($script:Failures.Count -eq 0) {
    Write-Line '结果：成功——音频驱动栈已完整重载，无需重启电脑。' 'Green'
    Write-Line ('日志：' + $script:LogFile) 'Gray'
    exit 0
} else {
    Write-Line ('结果：失败（' + $script:Failures.Count + ' 项）') 'Red'
    foreach ($f in $script:Failures) { Write-Line ('  - ' + $f) 'Red' }
    Write-Line ('日志：' + $script:LogFile) 'Gray'
    exit 2
}
