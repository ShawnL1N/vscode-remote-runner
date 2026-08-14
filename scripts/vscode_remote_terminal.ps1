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
$keyboard = New-Object -ComObject WScript.Shell
if (-not $keyboard.AppActivate($resolvedWindowTitle)) {
    throw 'Could not activate the selected VS Code Remote SSH window.'
}

Start-Sleep -Milliseconds $DelayMilliseconds
Add-Type -AssemblyName UIAutomationClient
$root = [System.Windows.Automation.AutomationElement]::FromHandle(
    [IntPtr]$selectedWindow.MainWindowHandle
)
$terminalCondition = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty,
    'xterm-helper-textarea'
)
$terminalElements = $root.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    $terminalCondition
)
$terminalInput = $null
for ($index = 0; $index -lt $terminalElements.Count; $index++) {
    $candidate = $terminalElements.Item($index)
    if ($candidate.Current.IsEnabled -and -not $candidate.Current.IsOffscreen) {
        $terminalInput = $candidate
        break
    }
}
if ($null -eq $terminalInput) {
    throw 'No visible existing terminal input was found. The skill will not create one.'
}
$terminalInput.SetFocus()
Start-Sleep -Milliseconds $DelayMilliseconds
$focusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement
if ($focusedElement.Current.ClassName -ne 'xterm-helper-textarea') {
    throw 'The existing terminal input could not be focused safely.'
}

Add-Type -AssemblyName System.Windows.Forms
$originalClipboard = [System.Windows.Forms.Clipboard]::GetDataObject()
try {
    if ($Action -eq 'Submit') {
        $keyboard.SendKeys('{ENTER}')
        Start-Sleep -Milliseconds $DelayMilliseconds
    } else {
        [System.Windows.Forms.Clipboard]::SetText($Command)
        $keyboard.SendKeys('^v')
        Start-Sleep -Milliseconds $DelayMilliseconds
        if ($Action -eq 'Run') {
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
    terminal_mode = 'existing_only'
    command_length = if ($null -eq $Command) { 0 } else { $Command.Length }
} | ConvertTo-Json -Compress
