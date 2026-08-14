[CmdletBinding()]
param(
    [ValidateSet('Run', 'Paste', 'Submit')]
    [string]$Action = 'Run',

    [string]$WindowTitle,

    [string]$Command,

    [switch]$ListWindows,

    [ValidateRange(100, 5000)]
    [int]$DelayMilliseconds = 500,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$sshWindowPattern = '\[SSH:[^\]]+\].*Visual Studio Code'

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class VscodeRemoteForegroundGuard {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
}
'@

function Set-VerifiedForegroundWindow {
    param([IntPtr]$WindowHandle)

    if (-not [VscodeRemoteForegroundGuard]::SetForegroundWindow($WindowHandle)) {
        throw 'Could not activate the selected VS Code Remote SSH window.'
    }
    Start-Sleep -Milliseconds $DelayMilliseconds
    if ([VscodeRemoteForegroundGuard]::GetForegroundWindow() -ne $WindowHandle) {
        throw 'The selected VS Code Remote SSH window did not become the foreground window.'
    }
}

function Assert-SafeTerminalFocus {
    param([IntPtr]$WindowHandle)

    if ([VscodeRemoteForegroundGuard]::GetForegroundWindow() -ne $WindowHandle) {
        throw 'Foreground-window ownership changed before terminal input. Nothing was sent.'
    }
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused -or $focused.Current.ClassName -ne 'xterm-helper-textarea') {
        throw 'The existing terminal input lost focus before input. Nothing was sent.'
    }
}

function Get-VSCodeSshWindows {
    @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.MainWindowHandle -ne 0 -and
            $_.ProcessName -like 'Code*' -and
            $_.MainWindowTitle -match $sshWindowPattern
        } |
        Select-Object Id, MainWindowHandle, MainWindowTitle)
}

if ($WindowTitle -and $WindowTitle -notmatch $sshWindowPattern) {
    throw 'WindowTitle must identify a VS Code Remote SSH window containing [SSH: ...].'
}

if ($ListWindows) {
    $windows = @(Get-VSCodeSshWindows)
    [ordered]@{
        status = 'listed'
        count = $windows.Count
        windows = @($windows | ForEach-Object {
            [ordered]@{
                process_id = $_.Id
                title = $_.MainWindowTitle
            }
        })
    } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}

if ($Action -in @('Run', 'Paste')) {
    if ([string]::IsNullOrWhiteSpace($Command)) {
        throw 'Run and Paste require a non-empty Command.'
    }
    if ($Command.Contains("`r") -or $Command.Contains("`n")) {
        throw 'Command must be a single line.'
    }
} elseif ($Command) {
    throw 'Submit accepts no Command.'
}

if ($DryRun) {
    [ordered]@{
        status = 'dry_run'
        action = $Action
        window_selector = if ($WindowTitle) { $WindowTitle } else { 'auto-detect-ssh' }
        terminal_mode = 'existing_only'
        command_length = if ($null -eq $Command) { 0 } else { $Command.Length }
    } | ConvertTo-Json -Compress
    exit 0
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Run this script with powershell.exe -STA.'
}

$windows = @(Get-VSCodeSshWindows)
if ($WindowTitle) {
    $selectedWindow = $windows |
        Where-Object { $_.MainWindowTitle -eq $WindowTitle } |
        Select-Object -First 1
    if ($null -eq $selectedWindow) {
        throw 'The requested VS Code Remote SSH window is not currently visible.'
    }
} else {
    if ($windows.Count -eq 0) {
        throw 'No visible VS Code Remote SSH window was found.'
    }
    if ($windows.Count -gt 1) {
        $titles = ($windows.MainWindowTitle | ForEach-Object { "- $_" }) -join [Environment]::NewLine
        throw "Multiple VS Code Remote SSH windows were found. Use -ListWindows and pass -WindowTitle:`n$titles"
    }
    $selectedWindow = $windows[0]
}

$resolvedWindowTitle = $selectedWindow.MainWindowTitle
$resolvedWindowHandle = [IntPtr]$selectedWindow.MainWindowHandle
$keyboard = New-Object -ComObject WScript.Shell
Set-VerifiedForegroundWindow -WindowHandle $resolvedWindowHandle
Add-Type -AssemblyName UIAutomationClient
$root = [System.Windows.Automation.AutomationElement]::FromHandle(
    $resolvedWindowHandle
)
$terminalCondition = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty,
    'xterm-helper-textarea'
)
$terminalElements = $root.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    $terminalCondition
)
$visibleTerminalInputs = @()
for ($index = 0; $index -lt $terminalElements.Count; $index++) {
    $candidate = $terminalElements.Item($index)
    if ($candidate.Current.IsEnabled -and -not $candidate.Current.IsOffscreen) {
        $visibleTerminalInputs += $candidate
    }
}
if ($visibleTerminalInputs.Count -eq 0) {
    throw 'No visible existing terminal input was found. The skill will not create one.'
}
$focusedTerminalInputs = @(
    $visibleTerminalInputs | Where-Object { $_.Current.HasKeyboardFocus }
)
if ($focusedTerminalInputs.Count -eq 1) {
    $terminalInput = $focusedTerminalInputs[0]
    $terminalSelection = 'focused_terminal'
} elseif ($visibleTerminalInputs.Count -eq 1) {
    $terminalInput = $visibleTerminalInputs[0]
    $terminalSelection = 'sole_visible_terminal'
} else {
    throw 'Multiple visible terminal panes were found, but none was uniquely focused. Focus the terminal you want to use and try again. Nothing was sent.'
}
$terminalInput.SetFocus()
Start-Sleep -Milliseconds $DelayMilliseconds
Assert-SafeTerminalFocus -WindowHandle $resolvedWindowHandle

Add-Type -AssemblyName System.Windows.Forms
$originalClipboard = [System.Windows.Forms.Clipboard]::GetDataObject()
try {
    if ($Action -eq 'Submit') {
        Assert-SafeTerminalFocus -WindowHandle $resolvedWindowHandle
        $keyboard.SendKeys('{ENTER}')
        Start-Sleep -Milliseconds $DelayMilliseconds
    } else {
        [System.Windows.Forms.Clipboard]::SetText($Command)
        Assert-SafeTerminalFocus -WindowHandle $resolvedWindowHandle
        $keyboard.SendKeys('^v')
        Start-Sleep -Milliseconds $DelayMilliseconds
        if ($Action -eq 'Run') {
            Assert-SafeTerminalFocus -WindowHandle $resolvedWindowHandle
            $keyboard.SendKeys('{ENTER}')
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
} finally {
    if ($null -ne $originalClipboard) {
        [System.Windows.Forms.Clipboard]::SetDataObject($originalClipboard, $true)
    } else {
        [System.Windows.Forms.Clipboard]::Clear()
    }
}

[ordered]@{
    status = if ($Action -eq 'Paste') { 'pasted_not_submitted' } else { 'submitted' }
    action = $Action
    window_title = $resolvedWindowTitle
    window_handle = $resolvedWindowHandle.ToInt64()
    terminal_selection = $terminalSelection
    visible_terminal_count = $visibleTerminalInputs.Count
    terminal_mode = 'existing_only'
    command_length = if ($null -eq $Command) { 0 } else { $Command.Length }
} | ConvertTo-Json -Compress
