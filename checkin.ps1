[CmdletBinding()]
param(
    [ValidateSet('Run', 'Calibrate', 'ImageCalibrate', 'Diagnose', 'Capture', 'Status', 'Install', 'Uninstall', 'SelfTest')]
    [string]$Mode = 'Run',
    [string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:Root 'targets.json'
$script:TaskName = 'AutoAgentsLogin-DailyCheckin'
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

function Add-NativeDesktopType {
    if ('AutoAgentsLoginClickNative' -as [type]) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AutoAgentsLoginClickNative {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
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
    try { $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size) } finally { $graphics.Dispose() }
    [pscustomobject]@{ Bitmap=$bitmap; Bounds=$bounds }
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

function Run-ImageTarget($App) {
    Add-NativeDesktopType
    Add-Type -AssemblyName System.Drawing
    $calibration = Get-Content -Raw -LiteralPath (Get-ImageCalibrationPath $App) -Encoding UTF8 | ConvertFrom-Json
    $templatePath = Join-Path $script:Runtime ([string]$calibration.template)
    if (-not (Test-Path -LiteralPath $templatePath)) { Write-Log ("{0}: image template missing." -f $App.displayName) 'ERROR'; return 'needs-calibration' }
    $wasRunning = @(Get-TargetProcesses $App).Count -gt 0
    if (-not $wasRunning) {
        $exe = Find-Executable $App
        if (-not $exe) { return 'not-installed' }
        Start-Target $App $exe
        $deadline = (Get-Date).AddSeconds(30)
        do { Start-Sleep -Milliseconds 750; $window = Get-TargetWindow $App } while (-not $window -and (Get-Date) -lt $deadline)
    } else { $window = Get-TargetWindow $App }
    if (-not $window) { Write-Log ("{0}: interactive window not found." -f $App.displayName) 'ERROR'; return 'deferred' }
    $handle = [IntPtr]$window.Current.NativeWindowHandle
    [void][AutoAgentsLoginClickNative]::ShowWindowAsync($handle, 9)
    [void][AutoAgentsLoginClickNative]::SetForegroundWindow($handle)
    Start-Sleep -Seconds 1
    $capture = Capture-WindowBitmap $window
    $template = [System.Drawing.Bitmap]::FromFile($templatePath)
    $beforeCrop = $null
    try {
        if ([Math]::Abs($capture.Bounds.Width-[int]$calibration.windowWidth) -gt 3 -or [Math]::Abs($capture.Bounds.Height-[int]$calibration.windowHeight) -gt 3) {
            Write-Log ("{0}: window size changed; refusing coordinate click." -f $App.displayName) 'ERROR'
            return 'needs-calibration'
        }
        $beforeCrop = Get-CroppedBitmap $capture.Bitmap $calibration
        $difference = Get-ImageDifference $beforeCrop $template
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
        $after = Capture-WindowBitmap $window
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
        $template.Dispose(); $capture.Bitmap.Dispose()
    }
}

function Calibrate-ImageTarget($App) {
    Add-NativeDesktopType
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    $exe = Find-Executable $App
    if (-not $exe) { Write-Log ("{0}: not installed; skipped." -f $App.displayName) 'WARN'; return }
    if (@(Get-TargetProcesses $App).Count -eq 0) {
        Start-Target $App $exe
        Start-Sleep -Seconds 5
    }
    $window = Get-TargetWindow $App
    if (-not $window) { Write-Log ("{0}: interactive window not found." -f $App.displayName) 'ERROR'; return }
    $handle = [IntPtr]$window.Current.NativeWindowHandle
    [void][AutoAgentsLoginClickNative]::ShowWindowAsync($handle, 9)
    [void][AutoAgentsLoginClickNative]::SetForegroundWindow($handle)
    Write-Host ''
    Write-Host ("{0}: move the mouse to the CENTER of the unclaimed check-in button and leave it there." -f $App.displayName) -ForegroundColor Cyan
    Write-Host 'Capturing in 8 seconds. Calibration will not click.'
    Start-Sleep -Seconds 8
    $capture = Capture-WindowBitmap $window
    try {
        $cursor = [System.Windows.Forms.Cursor]::Position
        $centerX = $cursor.X - $capture.Bounds.Left
        $centerY = $cursor.Y - $capture.Bounds.Top
        if ($centerX -lt 50 -or $centerY -lt 24 -or $centerX -gt ($capture.Bounds.Width-50) -or $centerY -gt ($capture.Bounds.Height-24)) {
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
    if (-not $uiaCalibrated -and -not $imageCalibrated) {
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

function Install-Task {
    $missing = @()
    foreach ($app in @(Get-Targets)) {
        if ((Find-Executable $app) -and
            -not (Test-Path -LiteralPath (Get-CalibrationPath $app)) -and
            -not (Test-Path -LiteralPath (Get-ImageCalibrationPath $app))) { $missing += $app.displayName }
    }
    if ($missing.Count -gt 0) { throw ('Calibrate installed clients first: ' + ($missing -join ', ')) }
    $scriptPath = (Resolve-Path -LiteralPath $MyInvocation.ScriptName).Path
    $taskCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode Run' -f $scriptPath
    $arguments = @('/Create','/TN',$script:TaskName,'/TR',$taskCommand,'/SC','DAILY','/ST','14:00','/RI','60','/DU','08:05','/IT','/F')
    $output = & schtasks.exe @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('schtasks failed: ' + ($output -join ' ')) }
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Set-ScheduledTask -TaskName $script:TaskName -Settings $settings | Out-Null
    Write-Log ("Installed task '{0}': daily 14:00, hourly through 22:00, interactive user only." -f $script:TaskName)
}

function Show-Status {
    Write-Host "Project: $script:Root"
    Write-Host "Runtime: $script:Runtime"
    foreach ($app in @(Get-Targets)) {
        $installed = [bool](Find-Executable $app)
        $running = @(Get-TargetProcesses $app).Count -gt 0
        $done = Test-SucceededToday $app
        $calibrated = Test-Path -LiteralPath (Get-CalibrationPath $app)
        [pscustomobject]@{ Target=$app.displayName; Installed=$installed; Running=$running; Calibrated=$calibrated; DoneToday=$done }
    }
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Write-Host ('Scheduled task: ' + $(if ($task) { $task.State } else { 'not installed' }))
}

function Invoke-SelfTest {
    $config = Get-Config
    if ($config.schemaVersion -ne 1) { throw 'Unsupported config schema.' }
    if (@($config.targets).Count -lt 2) { throw 'Expected TRAE and WorkBuddy targets.' }
    if (-not (Matches-Any '今日可领 100 积分' @('今日可领.*积分'))) { throw 'Matcher self-test failed.' }
    if (Matches-Any '升级 Pro' @('^(签到|领取)$')) { throw 'Matcher safety self-test failed.' }
    Ensure-Runtime
    Write-Host 'SELFTEST OK: config, safe matchers, runtime path, and PowerShell syntax are usable.'
}

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
    'Status' { Show-Status | Format-Table -AutoSize }
    'Install' { Install-Task }
    'Uninstall' {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log ("Removed task '{0}'. Project files were not changed." -f $script:TaskName)
    }
    'SelfTest' { Invoke-SelfTest }
}
