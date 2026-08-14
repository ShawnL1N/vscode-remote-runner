---
name: vscode-remote-runner
description: Enter one single-line command into the currently selected existing terminal of any visible, already authenticated VS Code Remote SSH window on Windows. Auto-detect SSH windows without hard-coding a username, host, IP address, project, local drive letter, mapped path, or window title. Use only after an explicit user request. Keep one-shot submission as the default. Enable managed background execution and non-visual result-file polling only when the latest user request explicitly asks for continuous monitoring, babysitting, or staying until completion. Run queries and ordinary launches directly, but paste without Enter and await a second explicit confirmation for deletion, overwrite, process termination, environment modification, or commands containing secrets. Never create or switch terminals, handle authentication, or intervene in ordinary manual terminal use.
---

# VS Code Remote Runner

Use the bundled scripts for explicit one-shot terminal input and optional managed monitoring. Install no hooks, services, keybindings, or VS Code settings.

## Mode gate

- Default to one-shot mode. Requests such as "run", "start", "paste", or "check GPU" do not enable monitoring.
- Enable monitoring mode only when the latest user request explicitly asks to continuously monitor, babysit, keep watching, train until completion, or an equivalent persistent outcome.
- Never infer monitoring from command duration. If the request is not explicit, submit once and stop.
- Monitoring mode temporarily reserves the selected terminal for Codex polling. Do not enable it while the user intends to type in that terminal manually.

## Preconditions

- Require an already authenticated VS Code Remote SSH window.
- Require the currently selected integrated terminal to be visible, idle, and empty for `Run`, `Paste`, `Start`, and `Prepare`. For `Submit`, require the exact previously prepared line to remain present and unchanged. The scripts confirm that an existing terminal input control is present but cannot determine shell state.
- With split terminal panes, require the intended pane to have keyboard focus before invocation. Use that focused pane; when only one pane is visible, use it directly. If multiple panes are visible and none is uniquely focused, stop without sending input and ask the user to focus the intended pane.
- Stop for a locked desktop, authentication dialog, uncertain target window, or permission/security prompt.
- Keep commands single-line. Never place passwords, tokens, or other sensitive values in a command unless the user explicitly approved that exact transmission.
- For monitoring mode, require a Linux-like remote shell with `bash`, `base64`, and `nohup`, plus working VS Code terminal shell integration. If the non-visual result bridge cannot verify its sentinel, fail closed and report that monitoring is unavailable.

## Command safety gate

Classify the final command before choosing `Run`, `Paste`, or monitored `Start`. Include pipelines, redirections, substitutions, and the underlying command inside a monitoring wrapper.

Execute directly with `Run` or monitored `Start` only for:

- Read-only queries and inspection, such as `nvidia-smi`, `pwd`, `ls`, and `git status`.
- Ordinary program, script, service-client, or training launches that do not explicitly perform a review-required operation below.

Require review-first mode for any command that:

- Deletes files, directories, records, environments, branches, or other state.
- Overwrites, truncates, force-replaces, resets, or irreversibly migrates existing data or configuration.
- Terminates processes, jobs, services, sessions, or containers.
- Installs, removes, upgrades, or otherwise modifies packages, environments, shell profiles, system configuration, permissions, ownership, or services.
- Contains a password, token, private key, credential, or other secret. Prefer a safer secret mechanism; include a secret in terminal input only after the user explicitly approves that exact transmission.
- Has an ambiguous destructive target or combines an otherwise safe command with any operation above.

For every review-required command:

1. Show the exact human-readable command and name the risk category.
2. Paste it without Enter and stop. Report that it has not executed.
3. Require a new user message explicitly confirming the exact command and that the pasted terminal line remains unchanged.
4. Only then use `Submit`, which presses Enter without re-pasting. If the user edited the line, may already have pressed Enter, or terminal state is uncertain, do not submit.
5. Treat an initial request to perform a risky action as authorization to prepare it, not as the second confirmation.

## One-shot workflow

1. Build the exact command without a trailing newline.
2. Re-check the latest user message immediately before invoking the script. Stop if the user said wait, stop, or do not send.
3. List candidates without sending input only when more than one SSH window may be open:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<skill>/scripts/vscode_remote_terminal.ps1" -ListWindows
```

4. For a direct-execution command, omit `-WindowTitle` when one SSH window exists; the script auto-detects it, focuses its already selected terminal, pastes, and presses Enter:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<skill>/scripts/vscode_remote_terminal.ps1" `
  -Command "<single-line command>"
```

5. If multiple SSH windows exist, choose one title returned by `-ListWindows` and pass that exact title with `-WindowTitle`.
6. For every review-required command, paste without submitting:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<skill>/scripts/vscode_remote_terminal.ps1" `
  -Action Paste `
  -Command "<single-line command>"
```

7. After the required second confirmation, submit the already-pasted unchanged line:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<skill>/scripts/vscode_remote_terminal.ps1" `
  -Action Submit
```

8. Treat returned JSON only as an input-delivery receipt. It does not prove that the remote command succeeded.

## Managed monitoring workflow

1. Confirm that the latest user request passes the monitoring mode gate and that the selected terminal can remain reserved.
2. Use managed monitoring directly. Do not also create a Codex heartbeat or scheduled automation for the same run unless the user explicitly asks for both.
3. For a direct-execution command, start the managed job. Omit `-RunId` to generate one automatically:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<skill>/scripts/vscode_remote_monitor.ps1" `
  -Action Start `
  -Command "<single-line command>"
```

4. For a review-required monitored command, prepare without Enter and record the returned `run_id`, `run_dir`, and `window_title`:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<skill>/scripts/vscode_remote_monitor.ps1" `
  -Action Prepare `
  -Command "<single-line command>"
```

5. Stop and obtain the required second confirmation. If the exact prepared terminal line is confirmed unchanged, submit it using the same `run_id` and, when needed, the exact `window_title`:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<skill>/scripts/vscode_remote_monitor.ps1" `
  -Action Submit `
  -RunId "<run_id>"
```

6. Record the returned `run_id` and `run_dir`. The job runs from the terminal's current remote working directory while its state lives under `~/.codex-runs/<run_id>/`.
7. Poll only that run:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<skill>/scripts/vscode_remote_monitor.ps1" `
  -Action Poll `
  -RunId "<run_id>"
```

8. Treat an empty `exit_code` while `remote_status=running` as expected. The file is created only when the managed command exits.
9. Use only the returned `remote_status`, `alive`, `exit_code`, and `log_tail` as evidence. The source of truth is the managed result files, not visible terminal text.
   Routine polling returns only the newest log line, capped at 2 KB, to keep terminal output compact. Increase `-TailLines` and `-TailBytes` only for explicit failure diagnosis.
10. Poll at a task-appropriate interval, normally 15-60 seconds, and keep user updates within the host's commentary cadence. Stop polling when status is `completed` or `failed`, the user asks to stop, the terminal is no longer safely reserved, or the one-shot result bridge fails.
11. Diagnose failures from `log_tail` and the managed files. Do not blindly rerun the remote poll command, terminate, replace the job, or retry the UI result transfer. Each poll permits exactly one invocation of Copy Last Command Output and validates a unique probe ID so stale clipboard output cannot pass.
12. For a localized VS Code UI, pass the localized title of the built-in Copy Last Command Output command through `-CopyCommandLabel` if the English default is not found.

## Behavior

- Scan visible VS Code windows and accept only titles containing both `[SSH:` and `Visual Studio Code`.
- Auto-select exactly one matching window. Fail closed when none or multiple are available; never guess between servers.
- Select the existing `xterm` input that already has keyboard focus. Fall back to the sole visible terminal only when exactly one exists. Never choose the first pane by enumeration, create a terminal, or switch terminal tabs.
- In one-shot mode, `Run` pastes and submits, `Paste` does not press Enter, and `Submit` presses Enter without re-pasting.
- In monitoring mode, `Start` creates a private managed run directory and launches one background runner. `Prepare` pastes the same wrapper without Enter, `Submit` submits that already-prepared wrapper only after confirmation, and `Poll` reads only the managed directory.
- Managed `Start` and `Prepare` visibly paste a Base64-encoded bootstrap line. It can be long; this is expected transport, not terminal output or a second training launch. The terminal remains reserved until monitoring ends.
- Before every system-wide keystroke, require the exact recorded VS Code window handle to still be the foreground window. A matching title alone is insufficient. If focus changes, fail immediately and send no further keys.
- `Poll` includes a fresh probe ID and accepts copied output only when the run ID, probe ID, and both sentinels match. It invokes Copy Last Command Output once and never retries the UI transfer automatically.
- Never interpret screenshots, terminal layout, scrolling, or visible-page text. The clipboard transfer is only a transport for result-file content and must be restored after every poll.
- Never open the Command Palette in one-shot mode. Monitoring `Poll` may open it only to invoke Copy Last Command Output. Before pasting the command label and again before pressing Enter, verify that the focused element is the same enabled Command Palette edit control inside the exact target VS Code window.
- Every local script invocation is one-shot and exits. Monitoring leaves no local hook, service, or watcher running.
- Treat drive letters, UNC paths, mounted directories, usernames, hosts, and project paths as per-request runtime values. Never persist environment-specific values in this skill. The selected VS Code Remote SSH server is the authority for commands and results. A local mapping to that same server may be used as a read-only result bridge only when it is supplied or verified at runtime; never assume or hard-code a drive letter or mapped path. Otherwise, read the portable managed result files under the remote user's home directory.
- Use `-DryRun` to validate arguments and generated metadata without activating a window or sending input.

## Output strategy

- For a short, immediate inspection command whose result the user will read in the terminal, submit directly and do not create a run directory, log, PID, exit-code file, or structured result file. Examples include `nvidia-smi`, `pwd`, `ls`, and `git status`.
- Do not inspect or summarize visible terminal output. Report only that the command was submitted; the user reads the result in the terminal.
- Create managed result files only in explicitly enabled monitoring mode.

## Managed result files

Monitoring mode writes under `~/.codex-runs/<run_id>/`:

- `status`: `queued`, `running`, `completed`, or `failed`.
- `pid`: background runner PID.
- `run.log`: unmodified stdout and stderr.
- `exit_code`: final process exit code when finished.
- `started_at` and `finished_at`: UTC timestamps.
- `work_dir`: remote working directory captured at submission.
- `command.b64` and `runner.sh`: private execution records created with `umask 077`.
- `result.json`: optional structured output written by the task to `$CODEX_RUN_DIR/result.json`.

## Safety

- Never invoke either mode automatically or because the user is manually using a terminal.
- Never enable monitoring without an explicit persistent-monitoring request in the latest user message.
- Never use direct `Run` or monitored `Start` for a review-required command. Use `Paste` or monitored `Prepare`, then wait for the required second confirmation.
- Never clear a partial command, send `Ctrl+C`, or type into a terminal whose prompt is not known to be idle and empty.
- Never create a new terminal, switch terminal tabs, automate login, or handle password, MFA, security, or privacy prompts.
- Never delete, overwrite, terminate, modify an environment, or transmit a secret without both an explicit request and the review-first confirmation sequence.
- Stop monitoring if terminal ownership becomes uncertain. Do not retry an uncertain input or poll twice blindly.
