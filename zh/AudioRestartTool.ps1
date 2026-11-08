<#
    AudioRestartTool.ps1  v1.0
    图形界面：一键彻底重载 Realtek 音频驱动栈（无需重启电脑）。
    需与 Restart-Audio.ps1 放在同一目录，由它执行实际工作。
#>

param([switch]$AutoTest)

$ErrorActionPreference = 'Stop'

$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }

if (-not $isAdmin) {
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($AutoTest) { $arg = $arg + ' -AutoTest' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arg -Verb RunAs -ErrorAction Stop
    } catch {
        [System.Windows.Forms.MessageBox]::Show('需要管理员权限才能重载音频设备。', '权限不足')
    }
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 双击 .cmd 启动时会带一个控制台窗口，这里把它隐藏，只留图形界面
if (-not $AutoTest) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleWinHelper {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@ -ErrorAction SilentlyContinue
        $h = [ConsoleWinHelper]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) { [void][ConsoleWinHelper]::ShowWindow($h, 0) }
    } catch { }
}

$script:EnginePath = Join-Path $PSScriptRoot 'Restart-Audio.ps1'
$script:AutoTest = $AutoTest
$script:Proc = $null
$script:OutFile = $null
$script:ErrFile = $null
$script:ReadPos = 0
$script:ExitCode = $null

if (-not (Test-Path -LiteralPath $script:EnginePath)) {
    [System.Windows.Forms.MessageBox]::Show('缺少 Restart-Audio.ps1，请把它与本程序放在同一文件夹。', '缺少文件')
    exit 1
}

# ---------------------------------------------------------------- 界面

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Realtek 音频彻底重启'
$form.ClientSize = New-Object System.Drawing.Size(660, 520)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $false
$form.MinimumSize = New-Object System.Drawing.Size(600, 470)
$form.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)

try { $uiFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9) } catch { $uiFont = New-Object System.Drawing.Font('Microsoft YaHei', 9) }
$form.Font = $uiFont

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '彻底重启 Realtek 音频'
$lblTitle.Location = New-Object System.Drawing.Point(16, 14)
$lblTitle.Size = New-Object System.Drawing.Size(640, 32)
$lblTitle.Font = New-Object System.Drawing.Font($uiFont.FontFamily, 15, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(28, 32, 38)
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = '停止音频服务 → 重载驱动控制器 → 重新枚举设备 → 恢复服务，效果等同开机重新加载'
$lblSub.Location = New-Object System.Drawing.Point(18, 50)
$lblSub.Size = New-Object System.Drawing.Size(640, 22)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(110, 118, 128)
$form.Controls.Add($lblSub)

$lblDevice = New-Object System.Windows.Forms.Label
$lblDevice.Text = '设备：正在检测...'
$lblDevice.Location = New-Object System.Drawing.Point(18, 80)
$lblDevice.Size = New-Object System.Drawing.Size(644, 44)
$lblDevice.ForeColor = [System.Drawing.Color]::FromArgb(60, 68, 78)
$form.Controls.Add($lblDevice)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '开始重启'
$btnStart.Location = New-Object System.Drawing.Point(18, 132)
$btnStart.Size = New-Object System.Drawing.Size(150, 42)
$btnStart.FlatStyle = 'Flat'
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.Font = New-Object System.Drawing.Font($uiFont.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
$btnStart.FlatAppearance.BorderSize = 0
$btnStart.UseVisualStyleBackColor = $false
$form.Controls.Add($btnStart)

$chkTone = New-Object System.Windows.Forms.CheckBox
$chkTone.Text = '完成后播放 0.5 秒测试音'
$chkTone.Location = New-Object System.Drawing.Point(182, 144)
$chkTone.Size = New-Object System.Drawing.Size(240, 24)
$chkTone.Checked = $true
$form.Controls.Add($chkTone)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '就绪'
$lblStatus.Location = New-Object System.Drawing.Point(18, 186)
$lblStatus.Size = New-Object System.Drawing.Size(644, 24)
$lblStatus.Font = New-Object System.Drawing.Font($uiFont.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(40, 100, 60)
$form.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(18, 214)
$txtLog.Size = New-Object System.Drawing.Size(624, 248)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.WordWrap = $false
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(38, 42, 48)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Anchor = 'Top, Bottom, Left, Right'
$form.Controls.Add($txtLog)

$lblFoot = New-Object System.Windows.Forms.Label
$lblFoot.Text = ('引擎：' + $script:EnginePath)
$lblFoot.Location = New-Object System.Drawing.Point(18, 472)
$lblFoot.Size = New-Object System.Drawing.Size(624, 34)
$lblFoot.ForeColor = [System.Drawing.Color]::FromArgb(140, 146, 155)
$lblFoot.Anchor = 'Bottom, Left, Right'
$form.Controls.Add($lblFoot)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$script:Timer = $timer

# ---------------------------------------------------------------- 逻辑

$script:Btn = $btnStart
$script:Chk = $chkTone
$script:Status = $lblStatus
$script:Log = $txtLog
$script:Form = $form

function Show-DeviceInfo {
    $dev = Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like '*VEN_10EC*' -and $_.Status -eq 'OK' } | Select-Object -First 1
    if ($dev) {
        $script:DeviceLabel.Text = '设备：' + $dev.FriendlyName + '   [' + $dev.InstanceId + ']'
    } else {
        $script:DeviceLabel.Text = '设备：未检测到可用的 Realtek 音频设备'
    }
}

$script:DeviceLabel = $lblDevice

$script:Drain = {
    param([string]$path)
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $all = $sr.ReadToEnd()
        $sr.Close()
        $fs.Close()
        return $all
    } catch { return '' }
}

$btnStart.Add_Click({
    if ($script:Proc) { return }

    $script:Btn.Enabled = $false
    $script:Chk.Enabled = $false
    $script:Log.Clear()
    $script:ReadPos = 0
    $script:ExitCode = $null
    $script:Status.ForeColor = [System.Drawing.Color]::FromArgb(180, 110, 0)
    $script:Status.Text = '执行中：停止音频服务...'

    $script:OutFile = Join-Path $env:TEMP ('audio_restart_' + [Guid]::NewGuid().ToString('N') + '.out')
    $script:ErrFile = $script:OutFile + '.err'

    $argList = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:EnginePath + '"'
    if ($script:Chk.Checked) { $argList = $argList + ' -TestTone' }

    try {
        $script:Proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden `
            -RedirectStandardOutput $script:OutFile -RedirectStandardError $script:ErrFile -PassThru
        $script:Timer.Enabled = $true
    } catch {
        $script:Status.ForeColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
        $script:Status.Text = '启动失败：' + $_.Exception.Message
        $script:Btn.Enabled = $true
        $script:Chk.Enabled = $true
        $script:Proc = $null
    }
})

$timer.Add_Tick({
    if (-not $script:Proc) { return }

    $all = & $script:Drain $script:OutFile
    if ($all -and $all.Length -gt $script:ReadPos) {
        $new = $all.Substring($script:ReadPos)
        $script:ReadPos = $all.Length
        $script:Log.AppendText($new)
        $script:Log.SelectionStart = $script:Log.TextLength
        $script:Log.ScrollToCaret()

        $m = [regex]::Matches($new, '\[\d/' + $script:TotalStepsText + '\]\s*([^\r\n]+)')
        $lastStep = $null
        foreach ($hit in $m) { $lastStep = $hit.Groups[1].Value }
        if ($lastStep) { $script:Status.Text = '执行中：' + $lastStep.Trim() }
    }

    $script:Proc.Refresh()
    if ($script:Proc.HasExited) {
        $script:Timer.Enabled = $false
        $tail = & $script:Drain $script:OutFile
        if ($tail -and $tail.Length -gt $script:ReadPos) {
            $script:Log.AppendText($tail.Substring($script:ReadPos))
            $script:ReadPos = $tail.Length
            $script:Log.SelectionStart = $script:Log.TextLength
            $script:Log.ScrollToCaret()
        }

        $script:ExitCode = $script:Proc.ExitCode
        if ($script:ExitCode -eq 0) {
            $script:Status.ForeColor = [System.Drawing.Color]::FromArgb(0, 130, 70)
            $script:Status.Text = '完成：音频驱动栈已彻底重载'
        } else {
            $script:Status.ForeColor = [System.Drawing.Color]::FromArgb(190, 40, 40)
            $script:Status.Text = '失败：退出码 ' + $script:ExitCode + '，详见下方日志'
            $errText = & $script:Drain $script:ErrFile
            if ($errText) {
                $script:Log.AppendText("`r`n--- 错误输出 ---`r`n" + $errText)
            }
        }

        $script:Proc = $null
        $script:Btn.Enabled = $true
        $script:Chk.Enabled = $true

        if ($script:AutoTest) {
            [Console]::Out.WriteLine('GUI_AUTOTEST_RESULT exit=' + $script:ExitCode)
            [Console]::Out.Flush()
            $script:Form.Close()
        }
    }
})

$script:TotalStepsText = '7'

$form.Add_Shown({
    Show-DeviceInfo
    if ($script:AutoTest) {
        $t0 = New-Object System.Windows.Forms.Timer
        $script:AutoTimer = $t0
        $t0.Interval = 900
        $t0.Add_Tick({
            $script:AutoTimer.Enabled = $false
            $script:Btn.PerformClick()
        })
        $t0.Enabled = $true
    }
})

[System.Windows.Forms.Application]::Run($form)
