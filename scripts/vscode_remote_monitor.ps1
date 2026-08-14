[CmdletBinding()]
param(
    [ValidateSet('Start', 'Prepare', 'Submit', 'Poll')]
    [string]$Action,

    [string]$Command,

    [string]$RunId,

    [string]$WindowTitle,

    [ValidateRange(512, 65536)]
    [int]$TailBytes = 16384,

    [ValidateRange(500, 10000)]
    [int]$ProbeWaitMilliseconds = 1500,

    [string]$CopyCommandLabel = 'Terminal: Copy Last Command Output',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$terminalScript = Join-Path $PSScriptRoot 'vscode_remote_terminal.ps1'
$runIdPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
$sshWindowPattern = '\[SSH:[^\]]+\].*Visual Studio Code'

function ConvertTo-Base64Utf8 {
    param([string]$Text)

    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function New-MonitorRunId {
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    'run_{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $suffix
}

function New-StartCommand {
    param(
        [string]$Id,
        [string]$UserCommand
    )

    $runner = @'
#!/usr/bin/env bash
set +e
run_dir="$HOME/.codex-runs/__RUN_ID__"
work_dir="$(cat "$run_dir/work_dir" 2>/dev/null)"
printf 'running\n' > "$run_dir/status"
date -u +%Y-%m-%dT%H:%M:%SZ > "$run_dir/started_at"
export CODEX_RUN_DIR="$run_dir"
if ! cd "$work_dir"; then
    printf 'Could not enter remote working directory: %s\n' "$work_dir" > "$run_dir/run.log"
    rc=200
else
    command_text="$(base64 -d < "$run_dir/command.b64")"
    bash -lc "$command_text" > "$run_dir/run.log" 2>&1
    rc=$?
fi
printf '%s\n' "$rc" > "$run_dir/exit_code"
date -u +%Y-%m-%dT%H:%M:%SZ > "$run_dir/finished_at"
if [ "$rc" -eq 0 ]; then
    printf 'completed\n' > "$run_dir/status"
else
    printf 'failed\n' > "$run_dir/status"
fi
exit "$rc"
'@.Replace('__RUN_ID__', $Id)

    $commandBase64 = ConvertTo-Base64Utf8 $UserCommand
    $runnerBase64 = ConvertTo-Base64Utf8 $runner
    $parts = @(
        "run_id='$Id'"
        'run_dir="$HOME/.codex-runs/$run_id"'
        'umask 077'
        'mkdir -p "$run_dir"'
        'pwd > "$run_dir/work_dir"'
        "printf '%s' '$commandBase64' > `"`$run_dir/command.b64`""
        "printf '%s' '$runnerBase64' | base64 -d > `"`$run_dir/runner.sh`""
        'chmod 700 "$run_dir/runner.sh"'
        "printf 'queued\n' > `"`$run_dir/status`""
        'nohup bash "$run_dir/runner.sh" >/dev/null 2>&1 </dev/null & runner_pid=$!'
        "printf '%s\n' `"`$runner_pid`" > `"`$run_dir/pid`""
        "printf 'monitor_started %s\n' `"`$run_id`""
    )
    $parts -join '; '
}

function New-PollCommand {
    param(
        [string]$Id,
        [int]$Bytes
    )

    $template = @'
run_id='__RUN_ID__'; run_dir="$HOME/.codex-runs/$run_id"; if [ ! -d "$run_dir" ]; then printf '__CODEX_MONITOR_V1__\nrun_id=%s\nstatus=missing\npid=\nalive=0\nexit_code=\nlog_b64=\n__CODEX_MONITOR_END__\n' "$run_id"; else monitor_status="$(tr -d '\r\n' < "$run_dir/status" 2>/dev/null)"; monitor_pid="$(tr -d '\r\n' < "$run_dir/pid" 2>/dev/null)"; monitor_exit="$(tr -d '\r\n' < "$run_dir/exit_code" 2>/dev/null)"; monitor_alive=0; if [ -n "$monitor_pid" ] && kill -0 "$monitor_pid" 2>/dev/null; then monitor_alive=1; fi; monitor_log="$(tail -c __TAIL_BYTES__ "$run_dir/run.log" 2>/dev/null | base64 | tr -d '\r\n')"; printf '__CODEX_MONITOR_V1__\nrun_id=%s\nstatus=%s\npid=%s\nalive=%s\nexit_code=%s\nlog_b64=%s\n__CODEX_MONITOR_END__\n' "$run_id" "$monitor_status" "$monitor_pid" "$monitor_alive" "$monitor_exit" "$monitor_log"; fi
'@
    $template.Replace('__RUN_ID__', $Id).Replace('__TAIL_BYTES__', [string]$Bytes).Trim()
}

function Invoke-TerminalCommand {
    param(
        [ValidateSet('Run', 'Paste', 'Submit')]
        [string]$TerminalAction,
        [string]$RemoteCommand
    )

    $arguments = @{
        Action = $TerminalAction
    }
    if ($TerminalAction -in @('Run', 'Paste')) {
        $arguments.Command = $RemoteCommand
    }
    if ($WindowTitle) {
        $arguments.WindowTitle = $WindowTitle
    }
    $rawReceipt = (& $terminalScript @arguments | Out-String).Trim()
    $rawReceipt | ConvertFrom-Json
}

function Copy-LastCommandOutput {
    param([string]$ResolvedWindowTitle)

    $selectedWindow = Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.MainWindowHandle -ne 0 -and
            $_.ProcessName -like 'Code*' -and
            $_.MainWindowTitle -eq $ResolvedWindowTitle -and
            $_.MainWindowTitle -match $sshWindowPattern
        } |
        Select-Object -First 1
    if ($null -eq $selectedWindow) {
        throw 'The monitored VS Code Remote SSH window is no longer visible.'
    }

    $keyboard = New-Object -ComObject WScript.Shell
    if (-not $keyboard.AppActivate($ResolvedWindowTitle)) {
        throw 'Could not reactivate the monitored VS Code Remote SSH window.'
    }

    Add-Type -AssemblyName System.Windows.Forms
    $originalClipboard = [System.Windows.Forms.Clipboard]::GetDataObject()
    try {
        [System.Windows.Forms.Clipboard]::SetText($CopyCommandLabel)
        $keyboard.SendKeys('{F1}')
        Start-Sleep -Milliseconds 400
        $keyboard.SendKeys('^v')
        Start-Sleep -Milliseconds 500
        $keyboard.SendKeys('{ENTER}')
        Start-Sleep -Milliseconds 900
        $copiedOutput = [System.Windows.Forms.Clipboard]::GetText()
    } finally {
        if ($null -ne $originalClipboard) {
            [System.Windows.Forms.Clipboard]::SetDataObject($originalClipboard, $true)
        } else {
            [System.Windows.Forms.Clipboard]::Clear()
        }
    }

    if ($copiedOutput -notmatch '__CODEX_MONITOR_V1__') {
        throw 'The non-visual result bridge did not receive the monitor sentinel. Check VS Code shell integration or CopyCommandLabel.'
    }
    $copiedOutput
}

if (-not $Action) {
    throw 'Action is required.'
}

if (-not $RunId) {
    if ($Action -in @('Start', 'Prepare')) {
        $RunId = New-MonitorRunId
    } else {
        throw "$Action requires RunId."
    }
}
if ($RunId -notmatch $runIdPattern) {
    throw 'RunId must use 1-64 letters, digits, dots, underscores, or hyphens and start with a letter or digit.'
}

if ($Action -in @('Start', 'Prepare')) {
    if ([string]::IsNullOrWhiteSpace($Command)) {
        throw "$Action requires a non-empty Command."
    }
    if ($Command.Contains("`r") -or $Command.Contains("`n")) {
        throw 'Command must be a single line.'
    }
    $remoteCommand = New-StartCommand -Id $RunId -UserCommand $Command
} elseif ($Action -eq 'Poll') {
    if ($Command) {
        throw 'Poll accepts no Command.'
    }
    $remoteCommand = New-PollCommand -Id $RunId -Bytes $TailBytes
} else {
    if ($Command) {
        throw 'Submit accepts no Command.'
    }
    $remoteCommand = $null
}

if ($DryRun) {
    [ordered]@{
        status = 'dry_run'
        action = $Action
        run_id = $RunId
        run_dir = "~/.codex-runs/$RunId"
        window_selector = if ($WindowTitle) { $WindowTitle } else { 'auto-detect-ssh' }
        remote_command_length = if ($null -eq $remoteCommand) { 0 } else { $remoteCommand.Length }
        input_sent = $false
    } | ConvertTo-Json -Compress
    exit 0
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Run this script with powershell.exe -STA.'
}

$terminalAction = switch ($Action) {
    'Prepare' { 'Paste' }
    'Submit' { 'Submit' }
    default { 'Run' }
}
$receipt = Invoke-TerminalCommand -TerminalAction $terminalAction -RemoteCommand $remoteCommand
if ($Action -eq 'Prepare') {
    [ordered]@{
        status = 'monitor_prepared_not_submitted'
        action = 'Prepare'
        run_id = $RunId
        run_dir = "~/.codex-runs/$RunId"
        window_title = $receipt.window_title
        terminal_mode = 'existing_only_waiting_for_explicit_confirmation'
    } | ConvertTo-Json -Compress
    exit 0
}
if ($Action -eq 'Submit') {
    [ordered]@{
        status = 'monitor_submitted_after_confirmation'
        action = 'Submit'
        run_id = $RunId
        run_dir = "~/.codex-runs/$RunId"
        window_title = $receipt.window_title
        terminal_mode = 'existing_only_reserved_for_monitoring'
    } | ConvertTo-Json -Compress
    exit 0
}
if ($Action -eq 'Start') {
    [ordered]@{
        status = 'monitor_submitted'
        action = 'Start'
        run_id = $RunId
        run_dir = "~/.codex-runs/$RunId"
        window_title = $receipt.window_title
        terminal_mode = 'existing_only_reserved_for_monitoring'
    } | ConvertTo-Json -Compress
    exit 0
}

Start-Sleep -Milliseconds $ProbeWaitMilliseconds
$copiedOutput = Copy-LastCommandOutput -ResolvedWindowTitle $receipt.window_title
$match = [regex]::Match(
    $copiedOutput,
    '(?s)__CODEX_MONITOR_V1__\r?\n(?<body>.*?)\r?\n__CODEX_MONITOR_END__'
)
if (-not $match.Success) {
    throw 'The monitor sentinel was copied but its payload was malformed.'
}

$fields = @{}
foreach ($line in ($match.Groups['body'].Value -split '\r?\n')) {
    $separator = $line.IndexOf('=')
    if ($separator -gt 0) {
        $fields[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
    }
}

$logTail = ''
if ($fields.log_b64) {
    try {
        $logTail = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($fields.log_b64)
        )
    } catch {
        throw 'The monitor log payload was not valid base64.'
    }
}

$exitCode = $null
if ($fields.exit_code -match '^-?\d+$') {
    $exitCode = [int]$fields.exit_code
}

[ordered]@{
    status = 'polled'
    action = 'Poll'
    run_id = $fields.run_id
    run_dir = "~/.codex-runs/$RunId"
    remote_status = $fields.status
    pid = $fields.pid
    alive = ($fields.alive -eq '1')
    exit_code = $exitCode
    log_tail = $logTail
    evidence_source = 'managed_result_files'
    window_title = $receipt.window_title
} | ConvertTo-Json -Depth 4 -Compress
