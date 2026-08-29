# Design — Architecture

## Central decision: one `rcd` daemon, driven over RC

Introduced in commit `e7b039b`. Instead of spawning one `rclone mount` process per mount, the
script runs a single persistent `rclone rcd` daemon on a fixed address (`127.0.0.1:5572`) and
performs every operation through its RC (remote control) HTTP API. The script calls that API
directly with `Invoke-RestMethod` (no `rclone rc` subprocess). Mounts are added and removed
while the daemon keeps running.

## Call graph

- `rc_call` — the single choke point for every RC request. `POST`s to
  `http://127.0.0.1:5572/<method>` with `Invoke-RestMethod`, sending `$Params` (a hashtable) as
  a JSON body and getting the parsed response object back. On an HTTP error status it reads the
  JSON error body from `$_.ErrorDetails.Message` and throws rclone's structured `.error` field,
  falling back to the transport exception message when there is no body (e.g. rcd not running).
  `-NoProxy` keeps the loopback call away from any configured HTTP proxy.
- `rcd_ensure` — idempotent daemon bootstrap. Probes `core/pid` first and **adopts** an
  already-running RC server if one answers; otherwise `Start-Process rclone rcd` and polls
  `core/pid` against a wall-clock deadline until the new PID answers. If a different PID owns the
  port, the freshly spawned process is killed and the existing server adopted. Called at the top
  of `rmount`.
- `rmount` — `rcd_ensure` → normalise separators → check `mount/listmounts` for a duplicate
  target → derive `volname` → `mount/mount` → poll `Test-Path $target` until the volume is
  visible → `add_mount_history`.
- `rstop` / `stop_one_mount` — `stop_one_mount` polls `vfs/stats` for one fs until
  `uploadsQueued` and `uploadsInProgress` both reach 0 (or the 60s timeout), then
  `mount/unmount` for that single mount point. `rstop --all` (also accepts `all`, `-all`, `*`)
  loops every mount then `core/quit`, falling back to `Stop-Process` if quit fails.
- `rflush` — `vfs/forget` per fs; targets one mount or all.
- `rlist` — three independent sections: `show_active_mounts` (`core/pid` + `mount/listmounts`),
  `show_config_remotes` (`rclone listremotes`), `show_mount_history` (reads the TSV file).

## Internal mechanics that must be preserved

- **RC responses are read as UTF-8** (from the HTTP content type), not decoded with the console
  output code page. Talking to the daemon over HTTP instead of parsing a `rclone rc` subprocess's
  stdout is what makes this correct: on a zh-CN console `[Console]::OutputEncoding` is CP936 /
  GB2312, which mangled multi-byte fields such as `vfs/stats`' `diskCache.path` (rclone's path
  encoder puts full-width `:` / `?` there) and broke `ConvertFrom-Json`.
- **RC parameters are a hashtable serialised to a JSON body** (`rc_call` takes
  `[hashtable]$Params`). Flat keys like `vfs_cache_mode` still work; nested `vfsOpt` / `mountOpt`
  objects are now also fine — there is no native-argument quote stripping to avoid, because no
  native command is invoked.
- **`$null -eq 0` is `$false` in PowerShell.** In `stop_one_mount` the "no disk cache for this
  fs" guard (`$null -eq $queued -and $null -eq $inProgress`) must run before the numeric
  `-eq 0` check, or the drain loop never terminates when `vfs_cache_mode` is below `writes`.
- `rcd_ensure`'s readiness loop uses a real wall-clock deadline, because each iteration also
  spends time on the `core/pid` probe (a failing connect while rcd is still binding the port);
  counting only `Start-Sleep` time would undershoot.
- `stop_one_mount` retries a failed `vfs/stats` up to 3 consecutive times before giving up, so a
  transient RC hiccup does not skip the upload drain.
- WinFsp volume labels cannot contain `: / \`; `volname` is derived by replacing those with `_`
  and trimming, falling back to `rclone`.
- Config password: `Get-StoredCredential -Target rclone` (the `CredentialManager` module) sets
  `$env:RCLONE_CONFIG_PASS`. A missing credential only warns.
- An adopted old-style `rclone mount ... --rc` process will not expose its own CLI mount via
  `mount/listmounts` (documented rclone limitation), so such mounts stay invisible to
  `rlist` / `rstop`; `rcd_ensure` warns about this when it adopts.

## Manual verification

No automated tests. Requires `rclone` on `PATH`, at least one configured remote, and WinFsp.
In a fresh PowerShell session:

```powershell
. .\rmount.ps1
rmount gdrive:backup X:        # mount
rlist                          # active mounts / configured remotes / mount history
rflush X:                      # flush VFS write cache for one mount
rstop X:                       # drain uploads + unmount one mount
rstop --all                    # drain + unmount everything, then stop the rcd daemon
```
