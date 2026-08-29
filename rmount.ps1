# rclone mount helpers
# Architecture: one persistent rclone rcd daemon manages all mounts through the RC API,
# instead of starting a separate rclone process for each mount. A single fixed port is used,
# so rmount/rstop/rflush/rlist all call the same RC endpoint and mounts can be added or
# removed while rcd remains running.
$cred = Get-StoredCredential -Target rclone -ErrorAction SilentlyContinue
if ($cred) {
    $env:RCLONE_CONFIG_PASS = $cred.GetNetworkCredential().Password
} else {
    Write-Warning "No stored credential found for 'rclone'. Rclone config password not set."
}
$rc_addr      = "127.0.0.1:5572"
$logDir       = Join-Path $env:USERPROFILE ".config/rclone_logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# Tab-separated "<remote>`t<localPath>" records, one per line, appended by rmount
# and de-duplicated so rlist history shows each remote/target pair only once.
$historyFile  = Join-Path $env:USERPROFILE ".config/rmount_history.tsv"

# Always pass RC parameters as flat key=value pairs (for example,
# vfs_cache_mode=writes and volname=xxx). Do not use the JSON form of vfsOpt/mountOpt:
# PowerShell strips the embedded double quotes when passing arguments to native processes
# in both Windows and Legacy PSNativeCommandArgumentPassing modes, so rclone receives
# invalid JSON such as {CacheMode:2}.
function rc_call {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter()] [string[]]$Params = @()
    )
    # Merge streams, then split them back apart by type: with 2>&1 a native
    # command's stderr lines arrive as ErrorRecord objects while stdout lines
    # stay plain strings. This keeps stray stderr (client warnings, the
    # "NOTICE: Failed to rc:" line) out of the text we hand to ConvertFrom-Json.
    $merged = & rclone rc $Method @Params --rc-addr $rc_addr 2>&1
    $exit   = $LASTEXITCODE
    $stdout = (($merged | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Out-String).Trim()
    $stderr = (($merged | Where-Object { $_ -is    [System.Management.Automation.ErrorRecord] }) | Out-String).Trim()

    if ($exit -ne 0) {
        # On failure rclone writes a JSON error object to stdout; pull the
        # structured .error field out of it rather than throwing the raw blob.
        $msg = $null
        if ($stdout) { try { $msg = ($stdout | ConvertFrom-Json).error } catch { } }
        if (-not $msg) { $msg = (@($stdout, $stderr) | Where-Object { $_ }) -join "`n" }
        if (-not $msg) { $msg = "rclone rc $Method failed (exit $exit)" }
        throw $msg
    }

    if ($stdout) { return ($stdout | ConvertFrom-Json) }
    return $null
}

# A live RC service may already be listening on the port (for example, an old
# `rclone mount ... --rc` process left behind after the terminal was closed without
# calling rcd_stop). Probe the service first and adopt it if reachable instead of
# blindly starting another process that would contend for the same port.
function rcd_ensure {
    try {
        $probe = rc_call -Method "core/pid"
        if ($probe.pid -and (Get-Process -Id $probe.pid -ErrorAction SilentlyContinue)) {
            Write-Host "Adopted existing rc server already listening on $rc_addr (PID: $($probe.pid))."
            Write-Warning "If that PID is an old-style 'rclone mount ... --rc' process, its own CLI mount won't show up in rlist/rstop (rclone limitation) -- only mounts added via rmount from now on will."
            return $true
        }
    } catch {}

    $logFile  = Join-Path $logDir ("rcd_" + (Get-Date -Format "yyyyMMdd_HHmmss_fff") + ".log")
    $rcd_args = @(
        "rcd"
        "--rc-addr", $rc_addr
        "--rc-no-auth"
        "--sftp-disable-hashcheck"
        "--log-file", $logFile
        "--log-level", "INFO"
    )
    $proc = Start-Process rclone -ArgumentList $rcd_args -WindowStyle Hidden -PassThru

    # Use a real wall-clock deadline: each loop also spends ~0.3-0.5s spawning
    # `rclone rc`, so counting only the Start-Sleep time would undershoot badly.
    $ready    = $false
    $maxWait  = 15
    $deadline = (Get-Date).AddSeconds($maxWait)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
            Write-Warning "rclone rcd exited early. Check log: $logFile"
            break
        }
        try {
            $probe = rc_call -Method "core/pid"
            if ($probe.pid -eq $proc.Id) {
                $ready = $true
                break
            }
            # Another process owns the port, so the new process must have failed to bind.
            Write-Warning "Port $rc_addr is already held by PID $($probe.pid), not our new rcd (PID $($proc.Id)). Adopting the existing one instead."
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            return $true
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) {
        Write-Warning "rcd not confirmed ready after ${maxWait}s. Check log: $logFile"
        return $null
    }

    Write-Host "rclone rcd started (PID: $($proc.Id), log: $logFile)"
    return $true
}

# Append a "<remote>`t<localPath>" record to the history file, skipping it if an
# identical pair is already present. Failures here must never break a mount.
function add_mount_history {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Target
    )
    try {
        $line     = "$Source`t$Target"
        $existing = @()
        if (Test-Path -LiteralPath $historyFile) {
            $existing = @(Get-Content -LiteralPath $historyFile -ErrorAction Stop | Where-Object { $_.Trim() })
        }
        if ($existing -contains $line) { return }
        Add-Content -LiteralPath $historyFile -Value $line -Encoding UTF8
    } catch {
        Write-Warning "Could not update mount history ($historyFile): $_"
    }
}

function rmount {
    param(
        [Parameter(Position=0)] $Source,
        [Parameter(Position=1)] $Target
    )

    if (-not (rcd_ensure)) { return }

    # Normalise path separators up front: everything downstream (the mount call,
    # the already-mounted check, the history file) works with forward slashes.
    if ($Source) { $Source = $Source -replace '\\', '/' }
    if ($Target) { $Target = $Target -replace '\\', '/' }

    $mounts = (rc_call -Method "mount/listmounts").mountPoints
    if ($mounts | Where-Object { $_.MountPoint -eq $Target }) {
        Write-Warning "Target '$Target' is already mounted. Run rstop first."
        return
    }

    # WinFsp volume labels can't contain ':' '/' '\' -- those get truncated or
    # rejected -- so derive a clean label from the remote string (e.g.
    # "gdrive:backup" -> "gdrive_backup").
    $volName = ($Source -replace '[:/\\]', '_').Trim('_')
    if (-not $volName) { $volName = "rclone" }

    try {
        rc_call -Method "mount/mount" -Params @(
            "fs=$Source",
            "mountPoint=$Target",
            "vfs_cache_mode=writes",
            "volname=$volName"
        ) | Out-Null
    } catch {
        Write-Error "Mount failed: $_"
        return
    }

    # Wait for the mount to become ready; a successful RC call does not guarantee that the volume is accessible yet.
    $ready = $false
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-Path $Target) { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) {
        Write-Warning "Mount RC call succeeded but '$Target' not visible yet. Check rcd logs in: $logDir"
        return
    }

    add_mount_history -Source $Source -Target $Target
    Write-Host "Mounted $Source to $Target"
}

# Section 1: mounts currently served by the rcd daemon.
function show_active_mounts {
    Write-Host "== Active mounts =="
    try {
        $rcdPid = (rc_call -Method "core/pid").pid
    } catch {
        Write-Host "rclone rcd is not running. No active mounts."
        return
    }
    $mounts = (rc_call -Method "mount/listmounts").mountPoints
    if (-not $mounts) {
        Write-Host "rcd is running (PID $rcdPid) but no active mounts."
        return
    }
    Write-Host "rcd PID: $rcdPid, rcAddr: $rc_addr"
    # Print each mount ourselves instead of Format-Table, which prepends a blank line.
    $fsWidth = ($mounts.Fs | Measure-Object -Maximum -Property Length).Maximum
    foreach ($m in $mounts) {
        Write-Host ("● {0,-$fsWidth}  {1}  {2}" -f $m.Fs, $m.MountPoint, $m.MountedOn)
    }
}

# Section 2: remotes defined in the rclone config (`rclone listremotes`).
function show_config_remotes {
    Write-Host "== Configured remotes (rclone config) =="
    $remotes = @(& rclone listremotes 2>$null | Where-Object { $_.Trim() })
    if ($LASTEXITCODE -ne 0 -or -not $remotes) {
        Write-Host "No remotes found in rclone config."
        return
    }
    $remotes | ForEach-Object { Write-Host "● $_" }
}

# Section 3: de-duplicated history of everything ever mounted via rmount.
function show_mount_history {
    Write-Host "== Mount history (remote_path local_path) =="
    if (-not (Test-Path -LiteralPath $historyFile)) {
        Write-Host "No mount history recorded yet."
        return
    }
    $entries = @(Get-Content -LiteralPath $historyFile | Where-Object { $_.Trim() } | Select-Object -Unique)
    if (-not $entries) {
        Write-Host "No mount history recorded yet."
        return
    }
    foreach ($line in $entries) {
        $parts = $line -split "`t", 2
        Write-Host ("● {0} {1}" -f $parts[0], $parts[1])
    }
}

function rlist {
    param(
        [Parameter(Position=0)] [string]$Section
    )

    show_active_mounts
    Write-Host ""
    show_config_remotes
    Write-Host ""
    show_mount_history
}

function rflush {
    param(
        [Parameter(Position=0)] $Target
    )

    try {
        rc_call -Method "core/pid" | Out-Null
    } catch {
        Write-Error "rclone rcd is not running."
        return
    }

    $mounts  = (rc_call -Method "mount/listmounts").mountPoints
    $entries = if ($Target) { $mounts | Where-Object { $_.MountPoint -eq $Target } } else { $mounts }
    if (-not $entries) {
        Write-Error "No rclone mount found$(if ($Target) { " for target '$Target'" }). Use rlist to see active mounts."
        return
    }

    foreach ($e in $entries) {
        rc_call -Method "vfs/forget" -Params @("fs=$($e.Fs)") | Out-Null
        Write-Host "VFS cache flushed for $($e.MountPoint) ($($e.Fs))."
    }
}

# Drain this fs's pending VFS uploads, then unmount just this one mount point.
# The rcd daemon and any other concurrent mounts are left untouched.
function stop_one_mount {
    param([Parameter(Mandatory)] $Entry)

    # Step 1: Wait for uploads to finish for this fs.
    $maxWait      = 60
    $waited       = 0
    $pending      = $true
    $rcFailures   = 0
    $maxRcRetries = 3
    while ($waited -lt $maxWait) {
        try {
            $stats      = rc_call -Method "vfs/stats" -Params @("fs=$($Entry.Fs)")
            $queued     = $stats.diskCache.uploadsQueued
            $inProgress = $stats.diskCache.uploadsInProgress
            $rcFailures = 0
        } catch {
            $rcFailures++
            if ($rcFailures -ge $maxRcRetries) {
                Write-Warning "RC query failed $rcFailures times in a row. Last error: $_"
                $pending = $false
                break
            }
            Write-Warning "RC query failed (attempt $rcFailures/$maxRcRetries): $_. Retrying..."
            Start-Sleep -Seconds 1
            $waited += 1
            continue
        }

        if ($null -eq $queued -and $null -eq $inProgress) {
            # No disk cache for this fs (vfs_cache_mode below 'writes') -- nothing
            # to drain. Note $null -eq 0 is $false in PowerShell, so this guard
            # must come before the numeric check or the loop never breaks.
            $pending = $false
            break
        }
        if ($queued -eq 0 -and $inProgress -eq 0) {
            Write-Host "All uploads finished for $($Entry.MountPoint)."
            $pending = $false
            break
        }
        Write-Host "Waiting for uploads on $($Entry.MountPoint)... Queued: $queued, InProgress: $inProgress"
        Start-Sleep -Seconds 2
        $waited += 2
    }
    if ($pending) {
        Write-Warning "Timed out after ${maxWait}s with pending uploads on $($Entry.MountPoint)."
    }

    # Step 2: Unmount only this mount point; keep the rcd daemon and other mounts running.
    try {
        rc_call -Method "mount/unmount" -Params @("mountPoint=$($Entry.MountPoint)") | Out-Null
        Write-Host "Unmounted $($Entry.MountPoint)."
    } catch {
        Write-Error "Unmount failed for $($Entry.MountPoint): $_"
    }
}

function rstop {
    param(
        [Parameter(Position=0)] $Target,
        [switch]$All
    )

    try {
        rc_call -Method "core/pid" | Out-Null
    } catch {
        Write-Error "rclone rcd is not running."
        return
    }

    # Accept `rstop --all` / `rstop all` / `rstop *` in addition to the -All switch.
    if ($Target -in '--all', '-all', 'all', '*') { $All = $true; $Target = $null }

    $mounts = @((rc_call -Method "mount/listmounts").mountPoints)

    if ($All) {
        if ($mounts.Count -eq 0) { Write-Host "No active mounts to stop." }
        foreach ($m in $mounts) { stop_one_mount $m }
        return
    }

    if ($mounts.Count -eq 0) {
        Write-Error "No active rclone mounts. Use rlist to check."
        return
    }

    if ($Target) {
        $entry = $mounts | Where-Object { $_.MountPoint -eq $Target } | Select-Object -First 1
        if (-not $entry) {
            Write-Error "No mount at '$Target'. Active: $($mounts.MountPoint -join ', '). Use rlist for details."
            return
        }
    } elseif ($mounts.Count -eq 1) {
        $entry = $mounts[0]
    } else {
        Write-Error "Multiple mounts active: $($mounts.MountPoint -join ', '). Specify one (rstop $($mounts[0].MountPoint)) or use rstop -All."
        return
    }

    stop_one_mount $entry
}

function rcd_stop {
    try {
        $rcdPid = (rc_call -Method "core/pid").pid
    } catch {
        Write-Host "rclone rcd is not running."
        return
    }

    rstop -All

    try {
        rc_call -Method "core/quit" | Out-Null
    } catch {
        Write-Warning "core/quit failed: $_. Forcing stop."
        Stop-Process -Id $rcdPid -Force -ErrorAction SilentlyContinue
    }
    Write-Host "rclone rcd stopped."
}
