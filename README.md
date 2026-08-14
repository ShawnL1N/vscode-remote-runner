# VS Code Remote Runner

`vscode-remote-runner` lets local Codex enter a command into an already authenticated VS Code Remote SSH terminal after an explicit user request. It does not establish its own SSH connection or obtain the server password or private key.

The current version supports two modes:

- **One-shot execution (default):** Enter one command, press Enter by default, and exit immediately.
- **Managed monitoring (explicit opt-in only):** Start a background job, create managed result files, and poll until the job completes or fails.

## Why Use It Instead of Direct Codex SSH?

Compared with giving Codex its own direct SSH connection, this skill provides a narrower and more user-controlled bridge:

- **No separate server credentials are entrusted to Codex.** The skill reuses the VS Code Remote SSH session that the user has already authenticated, instead of giving Codex a password, private key, SSH agent, or independent login configuration.
- **Codex cannot independently reconnect later.** Closing the VS Code SSH session removes the bridge; the skill does not retain a reusable path into the server.
- **Existing access controls are preserved.** The connection can continue to use the user's approved VS Code setup, jump host, MFA flow, or other organization-specific login process without reproducing that authentication inside Codex.
- **Commands remain visible and interruptible.** Submitted commands appear in the selected terminal, so the user can inspect, stop, or take over the session using familiar VS Code controls.
- **The default authority is intentionally narrow.** One-shot mode enters only the explicitly requested command into the currently selected terminal. It does not create a new terminal, choose another server, or obtain unrestricted remote-shell access on its own.
- **Less connection setup is required.** There is no need to configure a separate Codex SSH client, copy keys into the Codex environment, expose another remote entry path, or install a server-side agent.
- **It can bridge local sandbox or network restrictions.** If Codex cannot establish its own SSH connection but VS Code Remote SSH is already connected, Codex can still submit the requested terminal command through the existing desktop session.
- **It works across different Remote SSH servers.** Window detection does not hard-code a username, hostname, IP address, project path, or specific server.

This is not a universal replacement for direct SSH. Direct SSH is more reliable for unattended automation, interactive shell workflows, large file transfers, and high-volume command execution. This skill is most useful when credential isolation, explicit user control, and reuse of an existing VS Code session matter more than maximum automation reliability.

## 1. How It Works

```text
The user explicitly invokes the skill
        ↓
Codex builds one single-line command and classifies its risk
        ↓
A local PowerShell script finds a VS Code Remote SSH window
        ↓
Windows UI Automation locates the existing terminal input control
        ↓
The script pastes the command, submits when appropriate,
and restores the original clipboard
        ↓
The command runs in the already authenticated remote shell
```

The skill reuses the VS Code Remote SSH session that the user has already established. Codex does not run on the server, and the server does not need access to OpenAI. The server needs external network access only when the submitted command itself downloads code, dependencies, models, or other external resources.

## 2. Intended Use Cases

Use this skill when:

- Local Codex works normally, but the server cannot conveniently access OpenAI.
- The user is already connected to the server through VS Code Remote SSH.
- Codex cannot or should not receive a separate SSH private key and unrestricted remote access.
- The user wants Codex to enter commands such as `nvidia-smi`, launch a script, or start a training run.
- Server files are mounted locally, allowing Codex to monitor logs and results through the mounted directory.
- The user explicitly asks Codex to monitor a long-running command until it succeeds or fails.

Do not use this skill when:

- Codex would need to log in, enter a password, complete MFA, or handle a security prompt.
- VS Code Remote SSH is not already connected.
- The task requires an interactive editor, REPL, full-screen application, or multi-step terminal dialogue.
- The desktop will be locked or VS Code will be unavailable during unattended terminal control.
- The task requires unrestricted server file transfer, arbitrary directory access, or a stable remote API. Use a controlled SSH, SFTP, or MCP integration instead.

## 3. Requirements

### One-shot execution

- Windows 10 or Windows 11.
- An unlocked desktop session.
- A standard Visual Studio Code window already connected through Remote SSH.
- A window title containing both `[SSH: ...]` and `Visual Studio Code`.
- A visible, selected, idle integrated terminal with an empty input line.
- When terminal panes are split, the intended pane must already have keyboard focus. If several panes are visible and none is uniquely focused, the skill fails closed instead of selecting the first pane it finds.
- Local access to Windows PowerShell, Windows UI Automation, and the clipboard.

### Built-in managed monitoring

Managed monitoring additionally requires:

- A Linux-like remote shell.
- `bash`, `base64`, and `nohup` on the remote system.
- Working VS Code terminal shell integration.
- The selected terminal to remain reserved for Codex during monitoring.
- The built-in VS Code command `Terminal: Copy Last Command Output`. A localized VS Code interface may require the localized command label.

## 4. Installation

Keep the extracted directory structure intact:

```text
vscode-remote-runner/
├── SKILL.md
├── agents/
│   └── openai.yaml
└── scripts/
    ├── vscode_remote_terminal.ps1
    └── vscode_remote_monitor.ps1
```

Place the entire `vscode-remote-runner` directory in a personal skill directory recognized by Codex. The Windows path verified for the current package is:

```text
%USERPROFILE%\.codex\skills\vscode-remote-runner\
```

If another Codex installation discovers personal skills under `%USERPROFILE%\.agents\skills\`, place the same folder there instead. Restart Codex if the skill does not appear automatically.

## 5. Mode Selection

| User intent | Mode | Result files | Press Enter automatically |
|---|---|---:|---:|
| Check GPUs, the working directory, or Git status | One-shot | No | Yes |
| Launch a normal script or training run without persistent supervision | One-shot | No | Yes |
| Explicitly “monitor continuously,” “watch until done,” or equivalent | Managed monitoring | Yes | Yes |
| Delete, overwrite, terminate, modify an environment, or transmit a secret | Review first | Task-dependent | No; submit only after a second confirmation |

A long runtime alone does not enable monitoring. Managed monitoring is allowed only when the latest user request explicitly asks for persistent supervision.

## 6. One-Shot Workflow

1. Connect to the server through VS Code Remote SSH.
2. Open an existing integrated terminal and wait for the remote prompt.
3. Confirm that the terminal is idle and its input line is empty.
4. Explicitly invoke the skill, for example:

   ```text
   $vscode-remote-runner Check the current GPU usage on the server.
   ```

5. The skill searches for visible VS Code Remote SSH windows.
6. If exactly one candidate exists, the skill selects it automatically. If multiple candidates exist, it fails closed and requires an explicit target.
7. The script focuses the existing terminal, pastes the command, and presses Enter by default.
8. The script restores the original Windows clipboard and exits.
9. The user reads immediate output directly in the terminal.

For short inspection commands such as `nvidia-smi`, `pwd`, `ls`, and `git status`, the skill does not create a run directory, log, PID file, status file, or structured result.

The JSON receipt returned by the local script proves only that input was delivered. It does not prove that the remote command completed successfully.

## 7. Review-First Workflow for High-Risk Commands

The following operations require paste-only review before submission:

- Deleting files, directories, environments, branches, or records.
- Overwriting, truncating, force-replacing, resetting, or irreversibly migrating data.
- Terminating a process, training run, service, container, or session.
- Installing, removing, or upgrading packages, or changing system settings, environments, permissions, or ownership.
- Entering a password, token, private key, or other secret in a command.

Workflow:

1. Codex displays the exact command and identifies its risk category.
2. The skill pastes the command without pressing Enter.
3. The user inspects the actual command in the terminal.
4. The user sends a new message confirming that the command remains unchanged and may be submitted.
5. The skill sends Enter only; it does not paste the command again.

If the user edited or submitted the line, or terminal state is uncertain, the skill must stop. It must never submit blindly or run the command twice.

## 8. Long-Running Tasks: Recommended Monitoring Architecture

When the server directory is already mounted locally, prefer this separated architecture:

```text
Execution channel: vscode-remote-runner → authenticated remote terminal
Result channel: server logs and JSON → locally mounted directory
Monitoring channel: scheduled Codex task → periodic read-only checks
Intervention authority: retained by the user
```

End-to-end workflow:

1. The training controller writes logs, status, metrics, and final results into the server project directory.
2. The directory is exposed locally through a mapped drive or another read-only-visible mount.
3. Use `vscode-remote-runner` to launch the training command.
4. Create a scheduled Codex monitor, for example every five minutes, that checks:
   - Controller state and last-update time.
   - Current stage, seed, epoch, and final epoch.
   - Whether `history.json` continues to advance.
   - `traceback`, `CUDA OOM`, and `failed` markers in the log.
   - Stage validation outputs and final summaries.
5. Report only stage transitions, new seeds, repeated lack of progress, errors, and completion.
6. Do not let the monitor start, restart, terminate, or modify any process or file.
7. After completion, review the final metrics and stop the monitor.

The monitor must distinguish between:

- A disconnected, inaccessible, or stale mapped directory.
- A training process that has genuinely stopped making progress.

Prefer this architecture when available. It does not give Codex an SSH private key and does not reserve the training terminal for polling.

## 9. Long-Running Tasks: Built-In Managed Monitoring

Use the built-in mode only when the user explicitly requests continuous monitoring and no better mounted-directory monitoring path is available.

Example request:

```text
$vscode-remote-runner Start this training command and monitor it until completion or failure.
```

Managed monitoring:

1. Captures the command and the terminal's current remote working directory.
2. Creates a private run directory under:

   ```text
   ~/.codex-runs/<run_id>/
   ```

3. Starts a background runner with `nohup`.
4. Writes standard output and standard error to `run.log`.
5. Periodically submits a polling command for only that `run_id`.
6. Uses VS Code's built-in Copy Last Command Output capability to transport managed result-file content. It does not use screenshots or visual terminal interpretation.
7. Gives every poll a fresh probe ID and accepts copied output only when the run ID, probe ID, and both protocol sentinels match.
8. Invokes Copy Last Command Output exactly once per poll and fails closed instead of retrying an uncertain UI transfer.
9. Returns only the newest log line, capped at 2 KB by default; larger tails are requested only for explicit failure diagnosis.
10. Stops polling when the status is `completed` or `failed`, the user asks to stop, terminal ownership becomes uncertain, or the result bridge fails.

The managed run directory contains:

| File | Purpose |
|---|---|
| `status` | `queued`, `running`, `completed`, or `failed` |
| `pid` | Background runner PID |
| `run.log` | Unmodified standard output and standard error |
| `exit_code` | Final process exit code |
| `started_at` | UTC start time |
| `finished_at` | UTC finish time |
| `work_dir` | Remote working directory at submission time |
| `command.b64` | Base64-encoded original command |
| `runner.sh` | Private background runner script |
| `result.json` | Optional structured result written by the task |

This mode temporarily reserves the selected terminal as a polling channel. Do not use the same terminal manually while monitoring is active.

## 10. Security Boundaries

- The skill runs only after explicit invocation; implicit invocation is disabled.
- It never creates or switches terminals and never logs in to a server.
- It never handles passwords, MFA, security prompts, or privacy prompts.
- It never treats screenshots, terminal layout, or scrollback as execution evidence.
- It fails closed when more than one SSH window is available and no target is specified.
- Before every system-wide keystroke, it verifies that the exact recorded VS Code window handle is still the foreground window; a matching title alone is not enough.
- During managed polling, it also verifies that the same enabled Command Palette input remains focused before pasting the command label and before pressing Enter.
- It accepts only a single-line command by default.
- It restores the original clipboard after each operation.
- High-risk commands require paste-only review and a new explicit confirmation before submission.
- It never retries uncertain input blindly.
- Remote commands execute with the permissions of the current remote account and are not protected by the local filesystem sandbox.

## 11. Limitations

- The current implementation supports a Windows local desktop only.
- It depends on the standard VS Code window title and the `xterm-helper-textarea` terminal control. A VS Code update may change these implementation details.
- Cursor, VSCodium, browser-based VS Code, and other editors are not verified.
- The scripts cannot determine whether the terminal is truly idle, whether the input line is empty, or whether an interactive program currently owns the terminal.
- A locked desktop, hidden terminal, authentication dialog, or permission prompt causes the workflow to fail.
- One-shot mode cannot read or verify visible terminal output.
- Managed monitoring depends on VS Code shell integration and the built-in copy command. A localized interface may require a different command label.
- Managed polling briefly opens the VS Code Command Palette and may invoke only Copy Last Command Output.
- Managed monitoring is unavailable when the remote environment lacks `bash`, `base64`, or `nohup`.
- Mounted-directory monitoring depends on mount availability and cache freshness. A disconnected mount must not be treated as proof that training failed.
- The skill does not bypass server permissions, SSH policy, network policy, or local Codex approval requirements.

## 12. Troubleshooting

### No SSH window found

- Confirm that the VS Code window is visible and connected through Remote SSH.
- Confirm that the title contains `[SSH: ...]` and `Visual Studio Code`.
- Confirm that standard VS Code is being used rather than an unsupported editor fork.

### Multiple SSH windows found

- Specify the target window explicitly, or leave only the intended SSH window open.
- Never ask the skill to guess based on recent activity.

### No terminal input found

- Open an existing integrated terminal and keep it visible.
- Confirm that the terminal is not collapsed, closed, or offscreen.
- The skill will not create a terminal for the user.

### Command submitted but no result confirmed

- The JSON receipt proves only that the command was entered.
- The user reads immediate output directly in the terminal.
- Confirm long-running work through mounted files or managed result files.
- Never submit the same command again while execution state is uncertain.

### Managed monitoring cannot retrieve status

- Confirm that VS Code terminal shell integration is working.
- Confirm that the Copy Last Command Output command label matches the VS Code interface language.
- Confirm that the monitored terminal has not been used for another command.
- If the sentinel cannot be verified, stop managed monitoring and use mounted-directory monitoring instead.

### Mounted files stop updating

- First confirm that the mapped drive or mount is still accessible.
- Compare file modification times with the controller heartbeat.
- Require repeated lack of progress before reporting a stall, so transient cache or network delays are not misclassified as training failure.

## 13. Recommended Operating Rules

1. Run immediate inspection commands directly and let the user read their terminal output.
2. Submit ordinary launch commands once; do not enable monitoring automatically.
3. When a local mount exists, prefer skill-based launch plus a scheduled read-only monitor.
4. Use built-in managed monitoring only after an explicit persistent-monitoring request and when the mounted-directory approach is unavailable.
5. Always use paste, user review, a new confirmation, and submit-only for high-risk commands.
6. Do not provide the skill with a primary SSH key, server password, or long-lived token.
7. Monitoring observes and reports only. Restarting, terminating, or changing training parameters requires separate authorization.
