# arq-gfn-guard

English | [Polski](README.pl.md)

A lightweight macOS LaunchAgent that pauses [Arq 7](https://www.arqbackup.com/) only while a real [GeForce NOW](https://www.nvidia.com/geforce-now/) streaming session is active.

## Why

Cloud gaming is sensitive to upload saturation and latency. A background backup can turn an otherwise stable GeForce NOW session into stuttering or packet loss. Pausing Arq based only on whether the GeForce NOW app is open is too broad: many users leave its launcher running all day.

## What it does

- Watches NVIDIA's local reliability log for actual streaming lifecycle events.
- Pauses all Arq backup plans at session preparation, before streaming starts.
- Uses a 10-minute Arq pause lease and renews it every 4 minutes while streaming.
- Resumes Arq within a few seconds after streaming mode exits, even if the GeForce NOW app stays open.
- Falls back to a 60-second safety reconciliation if a log event is missed.
- Runs as the current user, needs no `sudo`, makes no network requests, and uses about 2 MB of RAM with effectively 0% idle CPU on the reference Intel Mac.
- Keeps macOS notifications **off by default**. Optional notifications are localized to English or Polish.

The guard only resumes a pause it owns. If it crashes or is unloaded, Arq's lease expires automatically within 10 minutes.

## Install

Requirements:

- macOS with Arq 7 in `/Applications/Arq.app`
- GeForce NOW in `/Applications/GeForceNOW.app`
- Arq application password disabled, so the user LaunchAgent can call `arqc` non-interactively; this does not disable backup encryption

```bash
git clone https://github.com/adriank1410/arq-gfn-guard.git
cd arq-gfn-guard
./install.sh
```

The default installation is silent. To enable notifications:

```bash
ARQ_GFN_NOTIFICATIONS=1 ./install.sh
```

Notification language follows macOS automatically. It can be forced during installation:

```bash
ARQ_GFN_NOTIFICATIONS=1 ARQ_GFN_LANG=en ./install.sh
ARQ_GFN_NOTIFICATIONS=1 ARQ_GFN_LANG=pl ./install.sh
```

Re-running the installer without overrides preserves the currently installed notification settings.

## Notifications

| Event | English | Polski |
|---|---|---|
| Stream starts | Backup paused for the active GeForce NOW session. | Backup wstrzymany na czas aktywnej sesji GeForce NOW. |
| Stream ends | GeForce NOW session ended; backup resumed. | Sesja GeForce NOW zakończona; backup wznowiony. |

Set `ARQ_GFN_NOTIFICATIONS=0` and run `./install.sh` to return to silent mode.

## Configuration

The installer stores these variables in the generated LaunchAgent plist:

| Variable | Default | Description |
|---|---:|---|
| `ARQ_GFN_NOTIFICATIONS` | `0` | `1` enables start/end notifications; `0` keeps the guard silent |
| `ARQ_GFN_LANG` | empty | `en`, `pl`, or empty for macOS locale auto-detection |
| `ARQ_GFN_LOOP_SECONDS` | `2` | Lightweight log-signature polling interval |
| `ARQ_GFN_SAFETY_SECONDS` | `60` | Full safety reconciliation interval |

The pause lease is intentionally 10 minutes and is renewed every 4 minutes. This provides enough overlap for temporary scheduling delays while guaranteeing automatic recovery if the agent disappears.

## Why a two-second check

The guard does not parse the NVIDIA log or call `pgrep` every two seconds. Its idle fast path consists only of the in-process `zsh/stat` file signature check followed by `zselect` sleep. `tail`, `awk`, the process check, and the wall-clock read run only when the log changes or during the 60-second safety reconciliation.

An earlier `launchd` `WatchPaths` design was more elegant on paper, but macOS coalesced or delayed events enough to postpone both pause and resume. `fswatch` would add a Homebrew dependency, while a native Swift/kqueue helper would require shipping and maintaining a compiled binary with higher resident memory. The current implementation measured around 2 MB RAM and effectively 0% idle CPU on the reference Intel Mac. The interval remains configurable for users who prefer a slower response.

## Usage

```bash
# Watch guard decisions and arqc output
tail -f ~/Library/Logs/ArqGFNGuard/guard.log

# Check the running LaunchAgent
launchctl print gui/$UID/com.local.arq-gfn-guard

# Apply code or configuration changes
./install.sh
```

## Uninstall

```bash
./uninstall.sh
```

Logs are intentionally retained. If the guard owned an active pause, that lease expires within 10 minutes.

## Tests

The test suite uses isolated temporary logs, state, a fake `arqc`, and a fake notification boundary. It never pauses the real Arq installation.

```bash
zsh -n arq-gfn-guard.sh install.sh uninstall.sh tests/test_guard.zsh
zsh tests/test_guard.zsh
plutil -lint com.local.arq-gfn-guard.plist
```

## Security and privacy

- No root privileges and no network access.
- Fixed system-only `PATH` and absolute paths for security-sensitive commands.
- Private state and logs (`700` directories, `600` files).
- Atomic ownership-state writes and bounded log reads.
- Notification text is passed to AppleScript as an argument, never interpolated as code.
- Only the final 1 MB of NVIDIA's local reliability log is inspected; game titles and account data are not uploaded anywhere.

## License

[MIT](LICENSE)
