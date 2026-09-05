# arq-gfn-guard

English | [Polski](README.pl.md)

Pauses [Arq 7](https://www.arqbackup.com/) backups while a real [GeForce NOW](https://www.nvidia.com/geforce-now/) streaming session is active, then resumes them automatically when the session ends.

## Problem

Cloud gaming is sensitive to upload saturation and latency. A backup running in the background can turn an otherwise stable GeForce NOW session into stuttering or packet loss.

Pausing Arq whenever the GeForce NOW app is open is too broad because its launcher may stay open all day. The useful signal is whether streaming mode is actually active.

## What it does

1. **Detects real streaming sessions** — watches NVIDIA's local reliability log for session preparation, start, termination, and streaming-mode exit events.
2. **Pauses before streaming starts** — calls Arq's official `arqc pauseBackups` command as soon as session preparation appears.
3. **Keeps the pause alive safely** — uses a 10-minute lease renewed every 4 minutes while streaming remains active.
4. **Resumes after the game exits** — calls `arqc resumeBackups` within a few seconds, even when the GeForce NOW launcher stays open.
5. **Fails safe** — a process-query error cannot falsely resume Arq; a missed event is reconciled within 60 seconds; an unloaded guard leaves only a pause that expires automatically.
6. **Tracks successful guard pauses** — resumes only when its private state confirms that the guard successfully issued a pause. Arq exposes one global pause, so overlapping an independent manual Arq pause is unsupported and may be replaced or resumed by the guard.
7. **Runs quietly and locally** — no root privileges, no network requests, about 2 MB RAM, and effectively 0% idle CPU on the reference Intel Mac.
8. **Offers optional macOS notifications** — off by default, with automatic English/Polish localization and no repeated message during lease renewals.

### Notifications

| Event | English | Polski |
|---|---|---|
| Stream starts | Backup paused for the active GeForce NOW session. | Backup wstrzymany na czas aktywnej sesji GeForce NOW. |
| Stream ends | GeForce NOW session ended; backup resumed. | Sesja GeForce NOW zakończona; backup wznowiony. |
| Lease renewal | *(silent)* | *(silent)* |

Enable notifications during installation with `ARQ_GFN_NOTIFICATIONS=1`. Their language follows macOS automatically; set `ARQ_GFN_LANG=en` or `ARQ_GFN_LANG=pl` to override it.

## Design notes

**Why inspect the GFN log instead of checking whether the app is open?**

The log exposes the actual streaming lifecycle. This lets the launcher remain open without keeping Arq paused.

**Why a persistent two-second check instead of `launchd` `WatchPaths`?**

An earlier `WatchPaths` version was more elegant on paper, but macOS coalesced or delayed events enough to postpone both pause and resume. The current idle fast path does not parse the log or call `pgrep`: it performs only an in-process `zsh/stat` signature check followed by `zselect` sleep. `tail`, `awk`, the process check, and the wall-clock read run only after a log change or during the 60-second safety reconciliation.

`fswatch` would add a Homebrew dependency. A native Swift/kqueue helper would remove the timer but require distributing and maintaining a compiled binary with higher resident memory. The two-second interval remains configurable.

**Why a 10-minute lease renewed every 4 minutes?**

The overlap tolerates temporary scheduling delays. If the guard crashes or is unloaded, Arq resumes automatically when the final lease expires.

**What about a separate manual Arq pause?**

Arq's CLI exposes one global pause and does not expose the previous pause state. Do not overlap an independent manual Arq pause with a GeForce NOW session: the guard's lease may replace it, and the automatic resume may end it. This limitation does not affect normal guard-controlled sessions.

## Install

No `sudo` required — this is a per-user LaunchAgent.

```bash
git clone https://github.com/adriank1410/arq-gfn-guard.git
cd arq-gfn-guard
./install.sh
```

The default installation is silent. Enable notifications with:

```bash
ARQ_GFN_NOTIFICATIONS=1 ./install.sh
```

Force their language if needed:

```bash
ARQ_GFN_NOTIFICATIONS=1 ARQ_GFN_LANG=en ./install.sh
ARQ_GFN_NOTIFICATIONS=1 ARQ_GFN_LANG=pl ./install.sh
```

Re-running `./install.sh` without overrides preserves the installed settings.

## Uninstall

```bash
./uninstall.sh
```

Logs remain in `~/Library/Logs/ArqGFNGuard/`. If the guard owned an active pause, it expires automatically within 10 minutes.

## Usage

```bash
# Watch guard decisions and arqc output
tail -f ~/Library/Logs/ArqGFNGuard/guard.log

# Check LaunchAgent status
launchctl print gui/$UID/com.local.arq-gfn-guard

# Apply code or configuration changes
./install.sh
```

## Configuration

Pass an override to `./install.sh`; the installer validates it and stores it in the generated LaunchAgent plist. Reinstallation without overrides preserves existing values.

| Variable | Default | Description |
|---|---:|---|
| `ARQ_GFN_NOTIFICATIONS` | `0` | `1` enables one start and one end notification per session; `0` is silent |
| `ARQ_GFN_LANG` | empty | `en`, `pl`, or empty for macOS locale auto-detection |
| `ARQ_GFN_LOOP_SECONDS` | `2` | Lightweight log-signature check interval |
| `ARQ_GFN_SAFETY_SECONDS` | `60` | Full safety reconciliation interval |

Example with a slower five-second response:

```bash
ARQ_GFN_LOOP_SECONDS=5 ./install.sh
```

## Files

| Repo file | Installed to |
|---|---|
| `arq-gfn-guard.sh` | `~/Library/Application Support/ArqGFNGuard/arq-gfn-guard.sh` |
| `com.local.arq-gfn-guard.plist` | `~/Library/LaunchAgents/com.local.arq-gfn-guard.plist` *(rendered by the installer)* |
| *(generated at runtime)* | `~/Library/Application Support/ArqGFNGuard/guard-paused` |
| *(generated at runtime)* | `~/Library/Logs/ArqGFNGuard/guard.log` |
| *(launchd output)* | `~/Library/Logs/ArqGFNGuard/launchd.out.log` and `launchd.err.log` |

## Tests

The suite uses isolated temporary logs and state plus fake `arqc`, clock, process-query, and notification boundaries. It never pauses the real Arq installation.

```bash
zsh -n arq-gfn-guard.sh install.sh uninstall.sh tests/test_guard.zsh
zsh tests/test_guard.zsh
plutil -lint com.local.arq-gfn-guard.plist
```

## Local dry run

Run from the repository in `zsh`. This simulates a session start in temporary files, prints the decision, and removes its test files. It does not install a LaunchAgent or call Arq. Expect `DRY-RUN arqc pauseBackups 10`. For the full pause/renew/resume lifecycle, run the test suite above.

```zsh
(
  test_root=$(mktemp -d /tmp/arq-gfn-preview.XXXXXX) || exit 1
  trap 'rm -rf "$test_root"' EXIT
  printf '%s\n' IPC_STREAMING_STARTED_EVENT > "$test_root/gfn.log"
  ARQ_GFN_GUARD_DRY_RUN=1 ARQ_GFN_GUARD_ONCE=1 \
    ARQ_GFN_FORCE_PROCESS=1 ARQ_GFN_NOTIFICATIONS=0 \
    ARQ_GFN_LOG_FILE="$test_root/gfn.log" \
    ARQ_GFN_STATE_DIR="$test_root/state" \
    ARQ_GFN_GUARD_LOG="$test_root/guard.log" \
    ./arq-gfn-guard.sh
  cat "$test_root/guard.log"
)
```

## Requirements

- macOS with Arq 7 installed in `/Applications/Arq.app`
- GeForce NOW installed in `/Applications/GeForceNOW.app`
- Arq application password disabled so the user LaunchAgent can call `arqc` non-interactively; this does **not** disable backup encryption

## Security and privacy

- Fixed system-only `PATH` and absolute paths for security-sensitive commands.
- Private state and logs (`700` directories and `600` files).
- Atomic state writes, bounded one-megabyte log reads, and automatic log rotation.
- Notification text reaches AppleScript as an argument, never interpolated code.
- No game titles, account data, log contents, or telemetry are sent anywhere.

## License

[MIT](LICENSE)
