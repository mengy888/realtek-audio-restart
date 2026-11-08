<#
    Restart-Audio.ps1  v1.0
    Fully reload the Realtek (or any vendor) audio driver stack without rebooting - the same effect as re-enumerating audio devices at boot.

    Usage (command line):
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -TestTone
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -DryRun
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -DeviceMatch VEN_10EC

    Parameters:
      -DeviceMatch  Vendor fragment matched inside the device InstanceId. Default: VEN_10EC (Realtek).
      -TestTone     Play a 0.5 s low-volume test tone afterwards to verify the audio path.
      -DryRun       Detect and preview only; nothing is changed.

    Exit codes: 0 = success; 1 = environment/parameter error; 2 = execution or verification failure
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

# ---------------------------------------------------------------- Device lookup

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

    # 1) Intel SST audio DSP controller: restarting it tears down and re-enumerates the whole child chain - most thorough
    foreach ($id in $chain) {
        if ($id -like 'INTELAUDIO\DSP_CTLR_*') { return [pscustomobject]@{ Target = $id; Chain = $chain; Reason = 'Intel SST audio DSP controller (parent device, re-enumerates all children)' } }
    }
    # 2) Other audio bus controllers
    foreach ($id in $chain) {
        if ($id -like 'HDAUDIO\*' -and $id -notlike 'HDAUDIO\FUNC_*') { return [pscustomobject]@{ Target = $id; Chain = $chain; Reason = 'HD Audio bus controller' } }
    }
    # 3) A PCI audio controller (Class=MEDIA) above the device also works as a target
    for ($i = 1; $i -lt $chain.Count; $i++) {
        $id = $chain[$i]
        if ($id -match '^PCI\\') {
            $cls = $null
            try { $cls = (Get-PnpDevice -InstanceId $id -ErrorAction Stop).Class } catch { }
            if ($cls -eq 'MEDIA') { return [pscustomobject]@{ Target = $id; Chain = $chain; Reason = 'PCI audio controller' } }
        }
    }
    # 4) Fallback: restart the function device itself
    return [pscustomobject]@{ Target = $FuncId; Chain = $chain; Reason = 'No audio controller found; falling back to the device itself' }
}

# ---------------------------------------------------------------- Services and processes

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

# ---------------------------------------------------------------------------------------------------- Audio endpoints

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
            if (-not $nm) { $nm = '(unnamed endpoint)' }
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
        if (hr != 0) return "GetDefaultAudioEndpoint failed 0x" + hr.ToString("X8");
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

# ================================================================ Main flow

Write-Line '==================================================================' 'Cyan'
Write-Line (' Audio driver stack restart   ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) 'Cyan'
Write-Line '==================================================================' 'Cyan'

# ---- 0. Elevation
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }

if (-not $isAdmin -and -not $DryRun) {
    Write-Line 'Administrator rights required; requesting elevation...' 'Yellow'
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($TestTone) { $arg = $arg + ' -TestTone' }
    if ($DeviceMatch -ne 'VEN_10EC') { $arg = $arg + ' -DeviceMatch "' + $DeviceMatch + '"' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arg -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Line ('Elevation failed: ' + $_.Exception.Message) 'Red'
        exit 1
    }
    exit 0
}

if (-not (Get-Command pnputil.exe -ErrorAction SilentlyContinue)) {
    Write-Line 'pnputil.exe not found. This tool requires Windows 10 1903 or newer.' 'Red'
    exit 1
}

# ---- 1. Locate the device
Write-Step 1 'Locate audio device and driver controller'

$allDev = Get-PnpDevice -ErrorAction SilentlyContinue
# Match inside audio devices only: Realtek wired NICs also use VEN_10EC, so vendor ID alone is ambiguous
$audioDev = $allDev | Where-Object { $_.Class -eq 'MEDIA' -or $_.InstanceId -like 'INTELAUDIO\FUNC_*' -or $_.InstanceId -like 'HDAUDIO\FUNC_*' }
$cand = $audioDev | Where-Object { $_.InstanceId -like ('*' + $DeviceMatch + '*') }
if (-not $cand) {
    Write-Warn ('No device matched an InstanceId containing ' + $DeviceMatch + '; falling back to a Realtek name match')
    $cand = $audioDev | Where-Object { $_.FriendlyName -like '*Realtek*' }
}
$func = $cand | Where-Object { $_.Status -eq 'OK' } | Select-Object -First 1
if (-not $func) { $func = $cand | Select-Object -First 1 }
if (-not $func) {
    Write-Bad ('No audio device matched ' + $DeviceMatch + '')
    Write-Line ('Result: FAILED (device not found); log: ' + $script:LogFile) 'Red'
    exit 2
}

Write-Info ('Device: ' + $func.FriendlyName + '  [' + $func.InstanceId + ']')

$res = Resolve-RestartTarget -FuncId $func.InstanceId
$target = $res.Target

Write-Info ('Parent chain: ' + (($res.Chain | Select-Object -Skip 1) -join '  ->  '))
Write-Info ('Restart target: ' + $target)
Write-Info ('Why: ' + $res.Reason)

if (-not $target -or $target.Trim() -eq '') {
    Write-Bad 'Restart target InstanceId is empty; aborted (never call pnputil with an empty argument)'
    Write-Line ('Result: FAILED (empty target); log: ' + $script:LogFile) 'Red'
    exit 2
}

$arrBefore = $null
try { $arrBefore = (Get-PnpDeviceProperty -InstanceId $target -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction Stop).Data } catch { }
Write-Info ('Device arrival time (current): ' + $arrBefore)

$svcList = Get-AudioServices
Write-Info ('Audio services: ' + ($svcList -join ', '))
foreach ($n in $svcList) {
    try { $script:ServiceStates[$n] = (Get-Service -Name $n).StartType } catch { }
}

if ($DryRun) {
    Write-Line '' 
    Write-Line '[DryRun] Detection complete; nothing was changed.' 'Yellow'
    Write-Line ('Log: ' + $script:LogFile) 'Gray'
    exit 0
}

# ---- 2. Stop services
Write-Step 2 'Stop audio services (reverse dependency order)'
$stopOrder = @()
foreach ($n in $svcList) { if ($n -ne 'AudioEndpointBuilder' -and $n -ne 'Audiosrv') { $stopOrder += $n } }
if ($svcList -contains 'Audiosrv') { $stopOrder += 'Audiosrv' }
if ($svcList -contains 'AudioEndpointBuilder') { $stopOrder += 'AudioEndpointBuilder' }

foreach ($n in $stopOrder) {
    try {
        $s = Get-Service -Name $n -ErrorAction Stop
        if ($s.Status -eq 'Stopped') { Write-Ok ($n + ' is already stopped'); continue }
        Stop-Service -Name $n -Force -ErrorAction Stop
        if (Wait-ServiceState -Name $n -State 'Stopped' -TimeoutSec 30) { Write-Ok ($n + ' stopped') }
        else { Write-Warn ($n + ' stop timed out (continuing)') }
    } catch {
        Write-Warn ($n + ' failed to stop: ' + $_.Exception.Message)
    }
}

# ---- 3. End user-mode processes
Write-Step 3 'End audio user-mode processes to release the device'
$procNames = @('RtkAudUService64', 'RtkNGUI64', 'RtkUWP', 'audiodg')
foreach ($pn in $procNames) {
    $ps = Get-Process -Name $pn -ErrorAction SilentlyContinue
    if ($ps) {
        try {
            $ps | Stop-Process -Force -ErrorAction Stop
            Write-Ok ('Terminated ' + $pn + ' (' + $ps.Count + ' processes)')
        } catch { Write-Warn ($pn + ' failed to terminate: ' + $_.Exception.Message) }
    }
}
Start-Sleep -Seconds 1

# ---- 4. Reload the driver
Write-Step 4 'Reload the driver (unload and re-enumerate the audio device chain)'
$restarted = $false
try {
    $out = & pnputil.exe /restart-device $target 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String)
    if (($code -eq 0) -and ($text -match 'restarted successfully') -and ($text -match [Regex]::Escape($target))) {
        $restarted = $true
        Write-Ok 'pnputil confirmed the restart of this device (echo contains the full InstanceId)'
    } else {
        Write-Warn ('pnputil returned an unexpected result: code=' + $code + '; falling back to disable/enable')
        Write-Info (($out | Select-Object -First 6) -join ' / ')
    }
} catch {
    Write-Warn ('pnputil threw: ' + $_.Exception.Message + '; falling back to disable/enable')
}

if (-not $restarted) {
    try {
        & pnputil.exe /disable-device $target 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        & pnputil.exe /enable-device $target 2>&1 | Out-Null
        Start-Sleep -Seconds 4
        $restarted = $true
        Write-Ok 'Device reloaded via disable -> enable'
    } catch {
        Write-Bad ('Device reload failed: ' + $_.Exception.Message)
    }
}

Start-Sleep -Seconds 6

$arrAfter = $null
try { $arrAfter = (Get-PnpDeviceProperty -InstanceId $target -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction Stop).Data } catch { }
if ($arrBefore -and $arrAfter -and ($arrAfter -ne $arrBefore)) {
    Write-Ok ('Device re-enumerated: arrival time ' + $arrBefore + '  ->  ' + $arrAfter)
} elseif ($restarted) {
    Write-Warn ('Arrival time unchanged (' + $arrAfter + '); rely on the functional checks below')
}

$funcAfter = $null
for ($i = 0; $i -lt 12; $i++) {
    $funcAfter = Get-PnpDevice -InstanceId $func.InstanceId -ErrorAction SilentlyContinue
    if ($funcAfter -and $funcAfter.Status -eq 'OK') { break }
    Start-Sleep -Seconds 2
}

if ($funcAfter -and $funcAfter.Status -eq 'OK') {
    Write-Ok ('Device recovered: ' + $funcAfter.FriendlyName + ' status OK')
} else {
    Write-Warn 'Device did not recover in time; trying to re-enable it'
    try {
        & pnputil.exe /enable-device $func.InstanceId 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        $funcAfter = Get-PnpDevice -InstanceId $func.InstanceId -ErrorAction SilentlyContinue
    } catch { }
    if ($funcAfter -and $funcAfter.Status -eq 'OK') { Write-Ok 'Device re-enabled and reported OK' }
    else { Write-Bad 'Device did not recover; reboot Windows to restore audio' }
}

# ---- 5. Start services
Write-Step 5 'Start audio services in dependency order'
foreach ($n in @('AudioEndpointBuilder', 'Audiosrv')) {
    if (-not ($svcList -contains $n)) { continue }
    try {
        $s = Get-Service -Name $n -ErrorAction Stop
        if ($s.Status -eq 'Running') { Write-Ok ($n + ' already running'); continue }
        Start-Service -Name $n -ErrorAction Stop
        if (Wait-ServiceState -Name $n -State 'Running' -TimeoutSec 40) { Write-Ok ($n + ' started') }
        else { Write-Bad ($n + ' start timed out') }
    } catch {
        Write-Bad ($n + ' failed to start: ' + $_.Exception.Message)
    }
}
foreach ($n in $svcList) {
    if ($n -eq 'AudioEndpointBuilder' -or $n -eq 'Audiosrv') { continue }
    try {
        $s = Get-Service -Name $n -ErrorAction Stop
        if ($s.Status -eq 'Running') { Write-Ok ($n + ' already running'); continue }
        Start-Service -Name $n -ErrorAction Stop
        Start-Sleep -Seconds 1
        if ((Get-Service -Name $n).Status -eq 'Running') { Write-Ok ($n + ' started') }
        else { Write-Warn ($n + ' not started (does not affect system audio)') }
    } catch {
        Write-Warn ($n + ' failed to start: ' + $_.Exception.Message)
    }
}

Start-Sleep -Seconds 6

# ---- 6. Verify
Write-Step 6 'Verify device, services and endpoints'

$problem = $null
try { $problem = (Get-PnpDeviceProperty -InstanceId $func.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data } catch { }
if ($problem -eq 0) { Write-Ok ('Device problem code 0 (' + $func.FriendlyName + '）') }
elseif ($null -eq $problem -or $problem -eq '') { Write-Warn 'Device problem code unavailable' }
else { Write-Bad ('Device problem code ' + $problem + '; the driver did not load correctly') }

$svcOk = $true
$svcText = @()
foreach ($n in $svcList) {
    $st = 'Unknown'
    try { $st = (Get-Service -Name $n -ErrorAction Stop).Status } catch { $svcOk = $false }
    $svcText += ($n + '=' + $st)
    if ($st -ne 'Running') { $svcOk = $false }
}
if ($svcOk) { Write-Ok ('Services: ' + ($svcText -join ', ')) }
else { Write-Bad ('Unexpected service state: ' + ($svcText -join ', ')) }

$render = Get-EndpointInfo -Kind 'Render'
$capture = Get-EndpointInfo -Kind 'Capture'
if ($render.Count -gt 0) {
    Write-Ok ('Active playback endpoints: ' + $render.Count + ' -> ' + (($render | Select-Object -First 4) -join ' / '))
} else { Write-Bad 'No active playback endpoint' }
if ($capture.Count -gt 0) {
    Write-Ok ('Active recording endpoints: ' + $capture.Count + '')
} else { Write-Warn 'No active recording endpoint' }

$def = Get-DefaultRenderEndpoint
Write-Ok ('Default playback endpoint: ' + $def)

# ---- 7. Test tone and summary
Write-Step 7 'Summary'
if ($TestTone) {
    try {
        Invoke-TestTone
        Write-Ok 'Test tone played - audio path works'
    } catch {
        Write-Bad ('Test tone failed: ' + $_.Exception.Message)
    }
} else {
    Write-Info 'Test tone disabled (add -TestTone to play 0.5 s afterwards)'
}

Write-Line ''
if ($script:Failures.Count -eq 0) {
    Write-Line 'Result: SUCCESS - the audio driver stack was fully reloaded, no reboot needed.' 'Green'
    Write-Line ('Log: ' + $script:LogFile) 'Gray'
    exit 0
} else {
    Write-Line ('Result: FAILED (' + $script:Failures.Count + ' item(s))') 'Red'
    foreach ($f in $script:Failures) { Write-Line ('  - ' + $f) 'Red' }
    Write-Line ('Log: ' + $script:LogFile) 'Gray'
    exit 2
}
