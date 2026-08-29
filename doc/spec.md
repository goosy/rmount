# rmount — Specification

## Goal

Provide a small set of PowerShell shell functions that make mounting, listing, flushing, and
unmounting [rclone](https://rclone.org/) remotes on Windows quick and forgiving to use from an
interactive session.

## Scope

`rmount.ps1` defines four user-facing functions plus internal helpers:

| Function | Purpose |
| --- | --- |
| `rmount <remote:path> <target>` | Mount a remote at a local path (drive letter or directory). |
| `rlist` | Show active mounts, configured rclone remotes, and de-duplicated mount history. |
| `rflush [target]` | Flush the VFS write cache for one mount, or all mounts. |
| `rstop [target] [-All]` | Drain pending uploads, then unmount one mount; `rstop --all` unmounts everything and stops the daemon. |

Out of scope: managing the rclone config itself (remotes are created with `rclone config`),
non-Windows platforms, and non-interactive/service usage.

## Behavior and constraints

- All mounts are served by **one persistent `rclone rcd` daemon** on a fixed loopback address
  (`127.0.0.1:5572`, `--rc-no-auth`). Mounts are added and removed without restarting it.
- `rmount` starts the daemon on demand and adopts an already-running RC server if one is present.
- `rstop` waits for VFS uploads to drain (bounded timeout) before unmounting so writes are not lost.
- Operations degrade gracefully: a missing config credential only warns; history-file failures
  never abort a mount; RC errors surface rclone's structured `.error` message.
- User input is normalised (backslashes → forward slashes; WinFsp `volname` derived from the remote).

## Tools and dependencies

Runtime (not vendored — must be present on the user's machine):

- PowerShell 7.6+
- `rclone` on `PATH`
- [WinFsp](https://winfsp.dev/) (required for `rclone mount` on Windows)
- PowerShell `CredentialManager` module — supplies the rclone config password from Windows
  Credential Manager (`Get-StoredCredential -Target rclone` → `$env:RCLONE_CONFIG_PASS`)

No build step, no package manifest, no test framework. The deliverable is `rmount.ps1`, consumed
by dot-sourcing it from a PowerShell `$PROFILE`.

## State on disk

Under `$env:USERPROFILE`:

- `.config/rclone_logs/rcd_<timestamp>.log` — one daemon log per start.
- `.config/rmount_history.tsv` — de-duplicated `<remote>\t<local path>` records.
