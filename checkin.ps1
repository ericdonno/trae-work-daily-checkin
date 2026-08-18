[CmdletBinding()]
param(
    [ValidateSet('Run', 'Calibrate', 'ImageCalibrate', 'Diagnose', 'Capture', 'Status', 'Install', 'Uninstall', 'SelfTest')]
    [string]$Mode = 'Run',
    [string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:Root = Split-Path -Parent $script:ScriptPath
$script:ConfigPath = Join-Path $script:Root 'targets.json'
$script:TaskName = 'CheckinBox-DailyCheckin'
$script:LegacyTaskName = 'AutoAgentsLogin-DailyCheckin'
$machineKey = (($env:COMPUTERNAME + '-' + $env:USERNAME) -replace '[^A-Za-z0-9_.-]', '_')
$script:Runtime = Join-Path $script:Root (Join-Path 'runtime' $machineKey)
$script:LogPath = Join-Path $script:Runtime 'checkin.log'

function Ensure-Runtime {
    if (-not (Test-Path -LiteralPath $script:Runtime)) {
        New-Item -ItemType Directory -Path $script:Runtime -Force | Out-Null
    }
}

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    Ensure-Runtime
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { throw "Missing $script:ConfigPath" }
    Get-Content -Raw -LiteralPath $script:ConfigPath -Encoding UTF8 | ConvertFrom-Json
}

function Get-Targets {
    $items = @((Get-Config).targets | Where-Object { $_.enabled })
    if ($Target -ne 'all') { $items = @($items | Where-Object { $_.id -eq $Target }) }
    if ($items.Count -eq 0) { throw "No enabled target matched '$Target'." }
    $items
}

function Get-TargetProcesses($App) {
    $names = @($App.processNames)
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName })
}

function Find-Executable($App) {
    foreach ($process in @(Get-TargetProcesses $App)) {
        try { if ($process.Path -and (Test-Path -LiteralPath $process.Path)) { return $process.Path } } catch {}
    }
    foreach ($candidate in @($App.executableCandidates)) {
        $path = [Environment]::ExpandEnvironmentVariables([string]$candidate)
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($entry in @(Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $App.displayNamePattern })) {
        $icon = ([string]$entry.DisplayIcon).Trim('"') -replace ',\d+$', ''
        if ($icon -and (Test-Path -LiteralPath $icon)) { return $icon }
        foreach ($name in @($App.processNames)) {
            $path = Join-Path ([string]$entry.InstallLocation) ($name + '.exe')
            if ($entry.InstallLocation -and (Test-Path -LiteralPath $path)) { return $path }
        }
    }
    $null
}

function Import-UIAutomation {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
}

function Get-Controls($App) {
    $rows = New-Object System.Collections.Generic.List[object]
    $pids = @((Get-TargetProcesses $App) | Select-Object -ExpandProperty Id)
    if ($pids.Count -eq 0) { return $rows.ToArray() }
    try {
        $elements = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        )
    } catch { return $rows.ToArray() }
    foreach ($element in $elements) {
        try {
            if ($pids -notcontains $element.Current.ProcessId) { continue }
            $rows.Add([pscustomobject]@{
                Element      = $element
                Name         = [string]$element.Current.Name
                ControlType  = [string]$element.Current.ControlType.ProgrammaticName
                ClassName    = [string]$element.Current.ClassName
                AutomationId = [string]$element.Current.AutomationId
                Enabled      = [bool]$element.Current.IsEnabled
                Offscreen    = [bool]$element.Current.IsOffscreen
            })
        } catch {}
    }
    $rows.ToArray()
}

function Wait-Controls($App, [int]$Seconds = 25) {
    $until = (Get-Date).AddSeconds($Seconds)
    do {
        $controls = @(Get-Controls $App)
        if ($controls.Count -gt 0) { return $controls }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $until)
    @()
}

function Matches-Any([string]$Text, $Patterns) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($pattern in @($Patterns)) { if ($Text -match $pattern) { return $true } }
    $false
}

function Find-Matches($Controls, $Patterns, [switch]$Actionable) {
    @($Controls | Where-Object {
        $_.Enabled -and -not $_.Offscreen -and
        (Matches-Any $_.Name $Patterns) -and
        (-not $Actionable -or $_.ControlType -match 'Button|Hyperlink|MenuItem|ListItem|TabItem')
    })
}

function Get-CalibrationPath($App) {
    Join-Path $script:Runtime ('calibration-' + $App.id + '.json')
}

function Get-ImageCalibrationPath($App) {
    Join-Path $script:Runtime ('image-calibration-' + $App.id + '.json')
}

function Test-AppCalibrated($App) {
    (Test-Path -LiteralPath (Get-CalibrationPath $App)) -or
    (Test-Path -LiteralPath (Get-ImageCalibrationPath $App))
}

function Get-TargetWindow($App) {
    $pids = @((Get-TargetProcesses $App) | Select-Object -ExpandProperty Id)
    if ($pids.Count -eq 0) { return $null }
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition
    )
    foreach ($candidate in $windows) {
        try {
            if ($pids -contains $candidate.Current.ProcessId -and $candidate.Current.NativeWindowHandle -ne 0) { return $candidate }
        } catch {}
    }
    $null
}

function Wait-TargetWindow($App, [int]$Seconds = 30) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $window = Get-TargetWindow $App
        if ($window) { return $window }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)
    $null
}

function Add-NativeDesktopType {
    if ('AutoAgentsLoginClickNative' -as [type]) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AutoAgentsLoginClickNative {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int width, int height, bool repaint);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
}
'@
}

function Capture-WindowBitmap($Window) {
    Add-Type -AssemblyName System.Drawing
    $rect = $Window.Current.BoundingRectangle
    $bounds = New-Object System.Drawing.Rectangle(
        [int][Math]::Floor($rect.Left), [int][Math]::Floor($rect.Top),
        [int][Math]::Ceiling($rect.Width), [int][Math]::Ceiling($rect.Height)
    )
    if ($bounds.Width -le 1 -or $bounds.Height -le 1) { throw 'Target window has invalid bounds.' }
    $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
        [pscustomobject]@{ Bitmap=$bitmap; Bounds=$bounds }
    } catch {
        $bitmap.Dispose()
        throw
    } finally { $graphics.Dispose() }
}

function Capture-TargetWindow($App, [int]$Attempts = 3) {
    $lastError = $null
    foreach ($attempt in 1..$Attempts) {
        $window = Get-TargetWindow $App
        if ($window) {
            try { return [pscustomobject]@{ Window=$window; Capture=(Capture-WindowBitmap $window) } }
            catch { $lastError = $_ }
        }
        if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds 500 }
    }
    if ($lastError) { throw ("Unable to capture {0} after {1} attempts: {2}" -f $App.displayName, $Attempts, $lastError.Exception.Message) }
    throw ("Interactive window not found for {0}." -f $App.displayName)
}

function Get-CroppedBitmap($Bitmap, $Calibration) {
    $rect = New-Object System.Drawing.Rectangle(
        [int]$Calibration.cropX, [int]$Calibration.cropY,
        [int]$Calibration.cropWidth, [int]$Calibration.cropHeight
    )
    $Bitmap.Clone($rect, $Bitmap.PixelFormat)
}

function Get-ImageDifference($First, $Second) {
    if ($First.Width -ne $Second.Width -or $First.Height -ne $Second.Height) { return 999.0 }
    [long]$total = 0; [long]$samples = 0
    for ($y = 0; $y -lt $First.Height; $y += 2) {
        for ($x = 0; $x -lt $First.Width; $x += 2) {
            $a = $First.GetPixel($x, $y); $b = $Second.GetPixel($x, $y)
            $total += [Math]::Abs([int]$a.R-[int]$b.R) + [Math]::Abs([int]$a.G-[int]$b.G) + [Math]::Abs([int]$a.B-[int]$b.B)
            $samples += 3
        }
    }
    [double]$total / [double]$samples
}

function Open-TraeAccountMenu($Window) {
    $rect = $Window.Current.BoundingRectangle
    $screenX = [int][Math]::Floor($rect.Left) + 130
    $screenY = [int][Math]::Floor($rect.Top + $rect.Height) - 34
    [void][AutoAgentsLoginClickNative]::SetCursorPos($screenX, $screenY)
    Start-Sleep -Milliseconds 200
    [AutoAgentsLoginClickNative]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero)
    [AutoAgentsLoginClickNative]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 800
}

function Run-ImageTarget($App) {
    Add-NativeDesktopType
    Add-Type -AssemblyName System.Drawing
    $calibration = Get-Content -Raw -LiteralPath (Get-ImageCalibrationPath $App) -Encoding UTF8 | ConvertFrom-Json
    $templatePath = Join-Path $script:Runtime ([string]$calibration.template)
    if (-not (Test-Path -LiteralPath $templatePath)) { Write-Log ("{0}: image template missing." -f $App.displayName) 'ERROR'; return 'needs-calibration' }
    if ([int]$calibration.centerY -lt 50) { Write-Log ("{0}: calibrated point is inside the window header; refusing click." -f $App.displayName) 'ERROR'; return 'needs-calibration' }
    $window = Get-TargetWindow $App
    if (-not $window) {
        $exe = Find-Executable $App
        if (-not $exe) { return 'not-installed' }
        Start-Target $App $exe
        $window = Wait-TargetWindow $App
    }
    if (-not $window) { Write-Log ("{0}: interactive window not found." -f $App.displayName) 'ERROR'; return 'deferred' }
    $handle = [IntPtr]$window.Current.NativeWindowHandle
    [void][AutoAgentsLoginClickNative]::ShowWindowAsync($handle, 9)
    [void][AutoAgentsLoginClickNative]::SetForegroundWindow($handle)
    Start-Sleep -Seconds 1
    $rect = $window.Current.BoundingRectangle
    if ([Math]::Abs($rect.Width-[int]$calibration.windowWidth) -gt 3 -or [Math]::Abs($rect.Height-[int]$calibration.windowHeight) -gt 3) {
        Write-Log ("{0}: restoring calibrated window size." -f $App.displayName)
        [void][AutoAgentsLoginClickNative]::MoveWindow($handle, [int]$rect.Left, [int]$rect.Top, [int]$calibration.windowWidth, [int]$calibration.windowHeight, $true)
        Start-Sleep -Seconds 1
        $window = Get-TargetWindow $App
        if (-not $window) { Write-Log ("{0}: window disappeared while restoring size." -f $App.displayName) 'ERROR'; return 'deferred' }
    }
    $template = [System.Drawing.Bitmap]::FromFile($templatePath)
    $capture = $null
    $beforeCrop = $null
    try {
        $hoverRect = $window.Current.BoundingRectangle
        [void][AutoAgentsLoginClickNative]::SetCursorPos(
            [int][Math]::Floor($hoverRect.Left) + [int]$calibration.centerX,
            [int][Math]::Floor($hoverRect.Top) + [int]$calibration.centerY
        )
        Start-Sleep -Milliseconds 500
        $snapshot = Capture-TargetWindow $App
        $window = $snapshot.Window; $capture = $snapshot.Capture
        if ([Math]::Abs($capture.Bounds.Width-[int]$calibration.windowWidth) -gt 3 -or [Math]::Abs($capture.Bounds.Height-[int]$calibration.windowHeight) -gt 3) {
            Write-Log ("{0}: window size changed; refusing coordinate click." -f $App.displayName) 'ERROR'
            return 'needs-calibration'
        }
        $beforeCrop = Get-CroppedBitmap $capture.Bitmap $calibration
        $difference = Get-ImageDifference $beforeCrop $template
        if ($difference -gt [double]$calibration.maxDifference -and [string]$App.id -eq 'trae') {
            Write-Log ("{0}: check-in card is not visible; opening the account menu." -f $App.displayName)
            $beforeCrop.Dispose(); $beforeCrop = $null
            $capture.Bitmap.Dispose(); $capture = $null
            foreach ($menuAttempt in 1..3) {
                Open-TraeAccountMenu $window
                foreach ($attempt in 1..4) {
                    $hoverRect = $window.Current.BoundingRectangle
                    [void][AutoAgentsLoginClickNative]::SetCursorPos(
                        [int][Math]::Floor($hoverRect.Left) + [int]$calibration.centerX,
                        [int][Math]::Floor($hoverRect.Top) + [int]$calibration.centerY
                    )
                    Start-Sleep -Milliseconds 750
                    $snapshot = Capture-TargetWindow $App
                    $window = $snapshot.Window; $capture = $snapshot.Capture
                    $beforeCrop = Get-CroppedBitmap $capture.Bitmap $calibration
                    $difference = Get-ImageDifference $beforeCrop $template
                    if ($difference -le [double]$calibration.maxDifference -or $attempt -eq 4) { break }
                    $beforeCrop.Dispose(); $beforeCrop = $null
                    $capture.Bitmap.Dispose(); $capture = $null
                }
                if ($difference -le [double]$calibration.maxDifference -or $difference -lt 50 -or $menuAttempt -eq 3) { break }
                Write-Log ("{0}: account menu did not appear; waiting and retrying." -f $App.displayName)
                $beforeCrop.Dispose(); $beforeCrop = $null
                $capture.Bitmap.Dispose(); $capture = $null
                Start-Sleep -Seconds 2
            }
        }
        Write-Log ("{0}: image-template difference {1:N2}." -f $App.displayName, $difference)
        if ($difference -gt [double]$calibration.maxDifference) {
            Write-Log ("{0}: current button differs from calibrated unclaimed state; no click." -f $App.displayName) 'ERROR'
            return 'blocked'
        }
        $screenX = $capture.Bounds.Left + [int]$calibration.centerX
        $screenY = $capture.Bounds.Top + [int]$calibration.centerY
        [void][AutoAgentsLoginClickNative]::SetCursorPos($screenX, $screenY)
        Start-Sleep -Milliseconds 200
        [AutoAgentsLoginClickNative]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero)
        [AutoAgentsLoginClickNative]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
        Write-Log ("{0}: clicked calibrated check-in button once; verifying." -f $App.displayName)
        Start-Sleep -Seconds 3
        $snapshot = Capture-TargetWindow $App
        $window = $snapshot.Window; $after = $snapshot.Capture
        $afterCrop = Get-CroppedBitmap $after.Bitmap $calibration
        try {
            $changed = Get-ImageDifference $beforeCrop $afterCrop
            Write-Log ("{0}: post-click visual change {1:N2}." -f $App.displayName, $changed)
            if ($changed -lt [double]$calibration.minSuccessChange) {
                Write-Log ("{0}: button did not visibly change; no retry click." -f $App.displayName) 'ERROR'
                return 'failed'
            }
        } finally { $afterCrop.Dispose(); $after.Bitmap.Dispose() }
        Save-Success $App 'claimed and visually verified'
        Close-Target $App
        'success'
    } finally {
        if ($beforeCrop) { $beforeCrop.Dispose() }
        $template.Dispose()
        if ($capture) { $capture.Bitmap.Dispose() }
    }
}

function Calibrate-ImageTarget($App) {
    Add-NativeDesktopType
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    $exe = Find-Executable $App
    if (-not $exe) { Write-Log ("{0}: not installed; skipped." -f $App.displayName) 'WARN'; return }
    $window = Get-TargetWindow $App
    if (-not $window) {
        Start-Target $App $exe
        $window = Wait-TargetWindow $App
    }
    if (-not $window) { Write-Log ("{0}: interactive window not found." -f $App.displayName) 'ERROR'; return }
    $handle = [IntPtr]$window.Current.NativeWindowHandle
    [void][AutoAgentsLoginClickNative]::ShowWindowAsync($handle, 9)
    [void][AutoAgentsLoginClickNative]::SetForegroundWindow($handle)
    Write-Host ''
    Write-Host ("{0}: move the mouse to the CENTER of the unclaimed check-in button and leave it there." -f $App.displayName) -ForegroundColor Cyan
    Write-Host 'Capturing in 8 seconds. Calibration will not click.'
    Start-Sleep -Seconds 8
    $snapshot = Capture-TargetWindow $App
    $window = $snapshot.Window; $capture = $snapshot.Capture
    try {
        $cursor = [System.Windows.Forms.Cursor]::Position
        $centerX = $cursor.X - $capture.Bounds.Left
        $centerY = $cursor.Y - $capture.Bounds.Top
        if ($centerX -lt 50 -or $centerY -lt 50 -or $centerX -gt ($capture.Bounds.Width-50) -or $centerY -gt ($capture.Bounds.Height-24)) {
            throw 'Mouse cursor was not safely inside the target window.'
        }
        $cropX = $centerX - 46; $cropY = $centerY - 20
        $rect = New-Object System.Drawing.Rectangle($cropX,$cropY,92,40)
        $crop = $capture.Bitmap.Clone($rect,$capture.Bitmap.PixelFormat)
        try {
            Ensure-Runtime
            $templateName = 'template-' + $App.id + '.png'
            $templatePath = Join-Path $script:Runtime $templateName
            $crop.Save($templatePath,[System.Drawing.Imaging.ImageFormat]::Png)
            [pscustomobject]@{
                savedAt=(Get-Date).ToString('o'); windowWidth=$capture.Bounds.Width; windowHeight=$capture.Bounds.Height
                centerX=$centerX; centerY=$centerY; cropX=$cropX; cropY=$cropY; cropWidth=92; cropHeight=40
                template=$templateName; maxDifference=10.0; minSuccessChange=2.0
            } | ConvertTo-Json | Set-Content -LiteralPath (Get-ImageCalibrationPath $App) -Encoding UTF8
            Write-Log ("{0}: image calibration saved without clicking." -f $App.displayName)
        } finally { $crop.Dispose() }
    } finally { $capture.Bitmap.Dispose() }
}

function Get-CalibratedClaim($App, $Controls) {
    $path = Get-CalibrationPath $App
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $saved = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
        @($Controls | Where-Object {
            $_.Enabled -and -not $_.Offscreen -and
            (($_.AutomationId -and $saved.claim.automationId -and $_.AutomationId -eq $saved.claim.automationId) -or
             ($_.Name -eq $saved.claim.name -and $_.ControlType -eq $saved.claim.controlType))
        })
    } catch { @() }
}

function Invoke-Control($Control) {
    [object]$pattern = $null
    if ($Control.Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
        return $true
    }
    $pattern = $null
    if ($Control.Element.TryGetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.LegacyIAccessiblePattern]$pattern).DoDefaultAction()
        return $true
    }
    $false
}

function Start-Target($App, [string]$Executable) {
    $arguments = @($App.launchArguments) -join ' '
    Write-Log ("Starting {0} with accessibility enabled." -f $App.displayName)
    Start-Process -FilePath $Executable -ArgumentList $arguments | Out-Null
}

function Close-Target($App) {
    $processes = @(Get-TargetProcesses $App)
    foreach ($process in $processes) { try { [void]$process.CloseMainWindow() } catch {} }
    Start-Sleep -Seconds 2
    foreach ($process in @(Get-TargetProcesses $App)) {
        try { Stop-Process -Id $process.Id -ErrorAction Stop } catch {}
    }
    Write-Log ("Closed {0}." -f $App.displayName)
}

function Save-Success($App, [string]$Reason) {
    $stateDir = Join-Path $script:Runtime 'state'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $marker = Join-Path $stateDir ('{0}-{1}.ok' -f $App.id, (Get-Date -Format 'yyyy-MM-dd'))
    Set-Content -LiteralPath $marker -Value $Reason -Encoding UTF8
    Write-Log ("{0}: {1}" -f $App.displayName, $Reason)
}

function Test-SucceededToday($App) {
    $marker = Join-Path (Join-Path $script:Runtime 'state') ('{0}-{1}.ok' -f $App.id, (Get-Date -Format 'yyyy-MM-dd'))
    Test-Path -LiteralPath $marker
}

function Save-Diagnostic($App, $Controls) {
    $dir = Join-Path $script:Runtime 'diagnostics'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir ('{0}-{1}.json' -f $App.id, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $data = @($Controls | Where-Object { $_.Name } | Select-Object Name, ControlType, ClassName, AutomationId, Enabled, Offscreen)
    $json = if ($data.Count -eq 0) { '[]' } else { $data | ConvertTo-Json -Depth 4 }
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    $path
}

function Save-DesktopCapture($App) {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AutoAgentsLoginNative {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
    $pids = @((Get-TargetProcesses $App) | Select-Object -ExpandProperty Id)
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition
    )
    $window = $null
    foreach ($candidate in $windows) {
        try {
            if ($pids -contains $candidate.Current.ProcessId -and $candidate.Current.NativeWindowHandle -ne 0) {
                $window = $candidate
                break
            }
        } catch {}
    }
    if (-not $window) { throw ("No interactive window found for {0}." -f $App.displayName) }
    $handle = [IntPtr]$window.Current.NativeWindowHandle
    [void][AutoAgentsLoginNative]::ShowWindowAsync($handle, 9)
    [void][AutoAgentsLoginNative]::SetForegroundWindow($handle)
    Start-Sleep -Seconds 1
    $rect = $window.Current.BoundingRectangle
    $bounds = New-Object System.Drawing.Rectangle(
        [int][Math]::Floor($rect.Left),
        [int][Math]::Floor($rect.Top),
        [int][Math]::Ceiling($rect.Width),
        [int][Math]::Ceiling($rect.Height)
    )
    if ($bounds.Width -le 1 -or $bounds.Height -le 1) { throw 'Target window has invalid bounds.' }
    $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
        $dir = Join-Path $script:Runtime 'screenshots'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir ('{0}-window-{1}.png' -f $App.id, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Log ("Saved interactive desktop capture to {0}" -f $path)
        $path
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Save-AutoCalibration($App, $Controls, [string]$Executable) {
    $claims = @(Find-Matches $Controls $App.claimPatterns -Actionable)
    if ($claims.Count -ne 1) { return $false }
    Ensure-Runtime
    [pscustomobject]@{
        savedAt = (Get-Date).ToString('o')
        executable = $Executable
        claim = [pscustomobject]@{
            name = $claims[0].Name
            controlType = $claims[0].ControlType
            automationId = $claims[0].AutomationId
        }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-CalibrationPath $App) -Encoding UTF8
    Write-Log ("{0}: auto-calibrated unique claim control '{1}' without clicking." -f $App.displayName, $claims[0].Name)
    $true
}

function Calibrate-Target($App) {
    $exe = Find-Executable $App
    if (-not $exe) { Write-Log ("{0}: not installed; skipped." -f $App.displayName) 'WARN'; return }
    $running = @(Get-TargetProcesses $App).Count -gt 0
    if ($running) {
        Write-Host ''
        Write-Host ("{0} is already running without guaranteed accessibility." -f $App.displayName) -ForegroundColor Yellow
        Write-Host 'Exit it completely, including its tray/background process. The script will not force a restart.'
        [void](Read-Host 'Press Enter after it is fully closed')
        if (@(Get-TargetProcesses $App).Count -gt 0) {
            Write-Log ("{0}: still running; calibration stopped without restarting it." -f $App.displayName) 'ERROR'
            return
        }
    }
    Start-Target $App $exe
    Write-Host ''
    Write-Host ("In {0}, log in and open the exact daily reward page." -f $App.displayName) -ForegroundColor Cyan
    Write-Host 'Calibration will only read controls; it will not claim anything.'
    [void](Read-Host 'Press Enter when the unclaimed reward button is visible')
    $controls = @(Wait-Controls $App 10)
    $diagnostic = Save-Diagnostic $App $controls
    if ($controls.Count -eq 0) {
        Write-Log ("{0}: no accessible controls. Close the app, rerun calibrate, and let this script launch it. Diagnostic: {1}" -f $App.displayName, $diagnostic) 'ERROR'
        return
    }
    $blocked = @(Find-Matches $controls (@($App.loginPatterns) + @($App.captchaPatterns)))
    if ($blocked.Count -gt 0) {
        Write-Log ("{0}: login or verification is visible; complete it manually first." -f $App.displayName) 'WARN'
        return
    }
    $claims = @(Find-Matches $controls $App.claimPatterns -Actionable)
    $success = @(Find-Matches $controls $App.successPatterns)
    if ($claims.Count -eq 1) {
        Ensure-Runtime
        [pscustomobject]@{
            savedAt = (Get-Date).ToString('o')
            executable = $exe
            claim = [pscustomobject]@{
                name = $claims[0].Name
                controlType = $claims[0].ControlType
                automationId = $claims[0].AutomationId
            }
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-CalibrationPath $App) -Encoding UTF8
        Write-Log ("{0}: calibrated claim control '{1}'. No click was performed." -f $App.displayName, $claims[0].Name)
    } elseif ($success.Count -gt 0) {
        Write-Log ("{0}: page is readable, but today's reward is already claimed. Calibrate again before claiming on another day." -f $App.displayName) 'WARN'
    } else {
        Write-Log ("{0}: found {1} accessible controls but {2} safe claim matches. Open the exact reward page and retry. Diagnostic: {3}" -f $App.displayName, $controls.Count, $claims.Count, $diagnostic) 'ERROR'
    }
}

function Run-Target($App) {
    if (Test-SucceededToday $App) { Write-Log ("{0}: already completed today." -f $App.displayName); return 'success' }
    $exe = Find-Executable $App
    if (-not $exe) { Write-Log ("{0}: not installed; skipped." -f $App.displayName) 'WARN'; return 'not-installed' }
    $uiaCalibrated = Test-Path -LiteralPath (Get-CalibrationPath $App)
    $imageCalibrated = Test-Path -LiteralPath (Get-ImageCalibrationPath $App)
    if (-not (Test-AppCalibrated $App)) {
        Write-Log ("{0}: not calibrated; no client launch or click performed." -f $App.displayName) 'ERROR'
        return 'needs-calibration'
    }
    if ($imageCalibrated -and -not $uiaCalibrated) { return Run-ImageTarget $App }
    $wasRunning = @(Get-TargetProcesses $App).Count -gt 0
    if (-not $wasRunning) { Start-Target $App $exe }
    $controls = @(Wait-Controls $App)
    if ($controls.Count -eq 0) {
        Write-Log ("{0}: no accessible controls; will retry later. Existing clients are never restarted." -f $App.displayName) 'WARN'
        if (-not $wasRunning) { Close-Target $App }
        return 'deferred'
    }
    for ($step = 0; $step -lt 4; $step++) {
        $success = @(Find-Matches $controls $App.successPatterns)
        if ($success.Count -gt 0) {
            Save-Success $App 'already claimed'
            Close-Target $App
            return 'success'
        }
        $blocked = @(Find-Matches $controls (@($App.loginPatterns) + @($App.captchaPatterns)))
        if ($blocked.Count -gt 0) {
            Write-Log ("{0}: login or verification requires manual action; no click performed." -f $App.displayName) 'ERROR'
            if (-not $wasRunning) { Close-Target $App }
            return 'blocked'
        }
        $claims = @(Get-CalibratedClaim $App $controls)
        if ($claims.Count -eq 0) { $claims = @(Find-Matches $controls $App.claimPatterns -Actionable) }
        if ($claims.Count -gt 1) {
            Write-Log ("{0}: ambiguous claim controls ({1}); no click performed." -f $App.displayName, $claims.Count) 'ERROR'
            if (-not $wasRunning) { Close-Target $App }
            return 'blocked'
        }
        if ($claims.Count -eq 1) {
            if (-not (Invoke-Control $claims[0])) {
                Write-Log ("{0}: matched '{1}' but it has no safe invoke action." -f $App.displayName, $claims[0].Name) 'ERROR'
                if (-not $wasRunning) { Close-Target $App }
                return 'blocked'
            }
            Write-Log ("{0}: invoked '{1}' once; verifying." -f $App.displayName, $claims[0].Name)
            $until = (Get-Date).AddSeconds(12)
            do {
                Start-Sleep -Milliseconds 750
                $controls = @(Get-Controls $App)
                if (@(Find-Matches $controls $App.successPatterns).Count -gt 0) {
                    Save-Success $App 'claimed and verified'
                    Close-Target $App
                    return 'success'
                }
            } while ((Get-Date) -lt $until)
            Write-Log ("{0}: click was not followed by a verified success state; no retry click." -f $App.displayName) 'ERROR'
            if (-not $wasRunning) { Close-Target $App }
            return 'failed'
        }
        $navigation = @(Find-Matches $controls $App.navigationPatterns -Actionable)
        if ($navigation.Count -ne 1 -or -not (Invoke-Control $navigation[0])) {
            Write-Log ("{0}: reward page not found and safe navigation count is {1}." -f $App.displayName, $navigation.Count) 'ERROR'
            if (-not $wasRunning) { Close-Target $App }
            return 'blocked'
        }
        Write-Log ("{0}: opened '{1}'." -f $App.displayName, $navigation[0].Name)
        Start-Sleep -Seconds 1
        $controls = @(Get-Controls $App)
    }
    Write-Log ("{0}: navigation limit reached." -f $App.displayName) 'ERROR'
    if (-not $wasRunning) { Close-Target $App }
    'failed'
}

function Show-FinalFailure($Results) {
    if ((Get-Date).Hour -lt 22) { return }
    $failed = @($Results.GetEnumerator() | Where-Object { $_.Value -notin @('success', 'not-installed') })
    if ($failed.Count -eq 0) { return }
    $message = 'Daily check-in failed: ' + (($failed | ForEach-Object { $_.Key + '=' + $_.Value }) -join ', ') + ". See $script:LogPath"
    try { & msg.exe $env:USERNAME $message 2>$null } catch {}
}

function Get-RunExitCode($Results) {
    if (@($Results.GetEnumerator() | Where-Object { $_.Value -notin @('success', 'not-installed') }).Count -gt 0) { return 1 }
    0
}

function Get-AccountSid([string]$Account) {
    (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Install-Task {
    $missing = @()
    foreach ($app in @(Get-Targets)) {
        if ((Find-Executable $app) -and -not (Test-AppCalibrated $app)) { $missing += $app.displayName }
    }
    if ($missing.Count -gt 0) { throw ('Calibrate installed clients first: ' + ($missing -join ', ')) }
    $RequestedTaskUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $requestedTaskSid = Get-AccountSid $RequestedTaskUser

    $scriptPath = (Resolve-Path -LiteralPath $script:ScriptPath).Path
    Unblock-File -LiteralPath $scriptPath
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    $taskArguments = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "{0}" -Mode Run' -f $scriptPath
    $action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $taskArguments -WorkingDirectory $script:Root
    $trigger = New-ScheduledTaskTrigger -Daily -At '14:00'
    $repetition = New-ScheduledTaskTrigger -Once -At '14:00' -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Hours 8)
    $trigger.Repetition = $repetition.Repetition
    $principal = New-ScheduledTaskPrincipal -UserId $RequestedTaskUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $definition = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'CheckinBox local daily reward check-in'
    Register-ScheduledTask -TaskName $script:TaskName -InputObject $definition -Force | Out-Null

    try {
        $registered = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
        $info = $registered | Get-ScheduledTaskInfo -ErrorAction Stop
        $registeredAction = @($registered.Actions)[0]
        $registeredTrigger = @($registered.Triggers)[0]
        $startHour = ([DateTimeOffset]::Parse([string]$registeredTrigger.StartBoundary)).ToLocalTime().Hour
        $errors = @()
        if (-not $registered.Settings.Enabled -or $registered.Settings.Hidden) { $errors += 'task is disabled or hidden' }
        if ((Get-AccountSid ([string]$registered.Principal.UserId)) -ne $requestedTaskSid) { $errors += 'run account mismatch' }
        if ([string]$registered.Principal.LogonType -ne 'Interactive') { $errors += 'logon type mismatch' }
        if ([string]$registered.Principal.RunLevel -ne 'Limited') { $errors += 'run level mismatch' }
        if ([string]$registeredAction.Execute -ne $powerShellExe -or [string]$registeredAction.Arguments -ne $taskArguments) { $errors += 'action mismatch' }
        if ([string]$registeredAction.WorkingDirectory -ne $script:Root) { $errors += 'working directory mismatch' }
        if ($startHour -ne 14 -or [string]$registeredTrigger.Repetition.Interval -ne 'PT1H' -or [string]$registeredTrigger.Repetition.Duration -ne 'PT8H') { $errors += 'trigger mismatch' }
        if (-not $info.NextRunTime) { $errors += 'next run time is missing' }
        if ($errors.Count -gt 0) { throw ('Task verification failed: ' + ($errors -join '; ')) }
    } catch {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        throw
    }

    $legacy = Get-ScheduledTask -TaskName $script:LegacyTaskName -ErrorAction SilentlyContinue
    if ($legacy) { $legacy | Unregister-ScheduledTask -Confirm:$false }
    Write-Log ("Installed and verified task '{0}' for {1}: daily 14:00, hourly through 22:00." -f $script:TaskName, $RequestedTaskUser)
    Write-Host ('Next run: ' + $info.NextRunTime)
}

function Show-Status {
    Write-Host "Project: $script:Root"
    Write-Host "Runtime: $script:Runtime"
    $rows = foreach ($app in @(Get-Targets)) {
        $installed = [bool](Find-Executable $app)
        $running = @(Get-TargetProcesses $app).Count -gt 0
        $done = Test-SucceededToday $app
        $calibrated = Test-AppCalibrated $app
        [pscustomobject]@{ Target=$app.displayName; Installed=$installed; Running=$running; Calibrated=$calibrated; DoneToday=$done }
    }
    $rows | Format-Table -AutoSize

    $task = $null
    $taskError = $null
    foreach ($name in @($script:TaskName, $script:LegacyTaskName)) {
        try {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
            break
        } catch {
            if ($_.FullyQualifiedErrorId -notmatch 'NotFound') { $taskError = $_; break }
        }
    }
    if ($taskError) {
        Write-Host ('Scheduled task: query failed (' + $taskError.Exception.Message.Trim() + ')') -ForegroundColor Yellow
        return
    }
    if (-not $task) {
        Write-Host 'Scheduled task: not installed' -ForegroundColor Yellow
        return
    }
    try {
        $info = $task | Get-ScheduledTaskInfo -ErrorAction Stop
        $lastRun = if ($info.LastRunTime.Year -lt 2000) { 'never' } else { [string]$info.LastRunTime }
        $lastResult = '0x{0:X8} ({1})' -f ([uint32]$info.LastTaskResult), $info.LastTaskResult
        Write-Host ("Scheduled task: {0} [{1}]" -f $task.TaskName, $task.State)
        Write-Host ('Run account: ' + $task.Principal.UserId)
        Write-Host ('Last run: ' + $lastRun)
        Write-Host ('Last result: ' + $lastResult)
        Write-Host ('Next run: ' + $info.NextRunTime)
    } catch {
        Write-Host ('Scheduled task info: query failed (' + $_.Exception.Message.Trim() + ')') -ForegroundColor Yellow
    }
}

function Remove-Tasks {
    $removed = @()
    foreach ($name in @($script:TaskName, $script:LegacyTaskName)) {
        try {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
            $task | Unregister-ScheduledTask -Confirm:$false
            $removed += $name
        } catch {
            if ($_.FullyQualifiedErrorId -notmatch 'NotFound') { throw }
        }
    }
    if ($removed.Count -gt 0) { Write-Log ('Removed scheduled task(s): ' + ($removed -join ', ')) }
    else { Write-Log 'No CheckinBox scheduled task was installed.' }
}

function Invoke-SelfTest {
    $config = Get-Config
    if ($config.schemaVersion -ne 1) { throw 'Unsupported config schema.' }
    if (@($config.targets).Count -lt 2) { throw 'Expected TRAE and WorkBuddy targets.' }
    if (-not (Matches-Any '今日可领 100 积分' @('今日可领.*积分'))) { throw 'Matcher self-test failed.' }
    if (Matches-Any '升级 Pro' @('^(签到|领取)$')) { throw 'Matcher safety self-test failed.' }
    if ((Get-RunExitCode @{ trae='success'; workbuddy='not-installed' }) -ne 0) { throw 'Successful exit-code self-test failed.' }
    if ((Get-RunExitCode @{ trae='failed' }) -eq 0) { throw 'Failure exit-code self-test failed.' }
    if (-not (Get-AccountSid ([Security.Principal.WindowsIdentity]::GetCurrent().Name))) { throw 'Account SID self-test failed.' }
    Ensure-Runtime
    Write-Host 'SELFTEST OK: config, safe matchers, exit codes, runtime path, and PowerShell syntax are usable.'
}

try {
Import-UIAutomation
switch ($Mode) {
    'Run' {
        $lockName = 'Local\AutoAgentsLogin-' + ($machineKey -replace '[^A-Za-z0-9]', '')
        $created = $false
        $mutex = New-Object System.Threading.Mutex($true, $lockName, [ref]$created)
        if (-not $created) { Write-Log 'Another run is active; exiting.' 'WARN'; exit 0 }
        try {
            $results = @{}
            foreach ($app in @(Get-Targets)) { $results[$app.id] = Run-Target $app }
            Show-FinalFailure $results
        } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
        exit (Get-RunExitCode $results)
    }
    'Calibrate' { foreach ($app in @(Get-Targets)) { Calibrate-Target $app } }
    'ImageCalibrate' { foreach ($app in @(Get-Targets)) { Calibrate-ImageTarget $app } }
    'Diagnose' {
        foreach ($app in @(Get-Targets)) {
            $controls = @(Get-Controls $app)
            $path = Save-Diagnostic $app $controls
            Write-Log ("{0}: saved {1} named controls to {2}" -f $app.displayName, @($controls | Where-Object Name).Count, $path)
            $exe = Find-Executable $app
            if ($exe) { [void](Save-AutoCalibration $app $controls $exe) }
        }
    }
    'Capture' { foreach ($app in @(Get-Targets)) { [void](Save-DesktopCapture $app) } }
    'Status' { Show-Status }
    'Install' { Install-Task }
    'Uninstall' { Remove-Tasks }
    'SelfTest' { Invoke-SelfTest }
}
} catch {
    $failure = $_
    $detail = ($failure | Out-String).Trim()
    try { Write-Log $detail 'ERROR' } catch { Write-Host ('ERROR: ' + $detail) -ForegroundColor Red }
    exit 1
}
