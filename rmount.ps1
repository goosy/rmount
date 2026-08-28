
# rclone mount helpers
$cred = Get-StoredCredential -Target rclone -ErrorAction SilentlyContinue
if ($cred) {
    $env:RCLONE_CONFIG_PASS = $cred.GetNetworkCredential().Password
} else {
    Write-Warning "No stored credential found for 'rclone'. Rclone config password not set."
}
$rc_addr_base = 5572
$stateFile = Join-Path $env:USERPROFILE ".config/rclone_mounts.json"
$logDir    = Join-Path $env:USERPROFILE ".config/rclone_logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# 每个挂载实例需要独立的 rc 端口，否则第二个实例绑定时会因端口占用而启动失败
function get_free_rc_port {
    param([int]$StartPort = $rc_addr_base)
    $port = $StartPort
    while ($port -lt ($StartPort + 200)) {
        $listener = $null
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
            $listener.Start()
            return $port
        } catch {
            $port++
        } finally {
            if ($listener) { $listener.Stop() }
        }
    }
    throw "No free rc port found in range $StartPort-$($StartPort + 200)."
}

function get_rclone_state {
    if (Test-Path $stateFile) {
        try {
            $raw = Get-Content $stateFile -Raw -ErrorAction SilentlyContinue
            if ($raw) { return $raw | ConvertFrom-Json }
        } catch {}
    }
    return @()
}

function save_rclone_state($state) {
    $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8
}

function rmount {
    param(
        [Parameter(Position=0)] $Source,
        [Parameter(Position=1)] $Target
    )

    $state = get_rclone_state

    # 清理已死进程的僵尸记录
    $alive = @()
    foreach ($e in $state) {
        $p = Get-Process -Id $e.pid -ErrorAction SilentlyContinue
        if ($p) { $alive += $e }
    }
    if ($alive.Count -ne $state.Count) {
        save_rclone_state $alive
        $state = $alive
    }

    # 阻止重复挂载同一目标
    $dup = $state | Where-Object { $_.target -eq $Target }
    if ($dup) {
        Write-Warning "Target '$Target' is already mounted (PID: $($dup.pid)). Run rstop first."
        return
    }

    $thisRcAddr = "127.0.0.1:$(get_free_rc_port)"

    $safeName = ($Target -replace '[:\\/]', '') + "_" + (Get-Date -Format "yyyyMMdd_HHmmss")
    $logFile  = Join-Path $logDir "$safeName.log"

    $mount_args = @(
        "mount"
        "$Source"
        "$Target"
        "--vfs-cache-mode", "writes"
        "--rc"
        "--rc-addr", $thisRcAddr
        "--rc-no-auth"
        "--sftp-disable-hashcheck"
        "--volname", "$Source"
        "--log-file", "$logFile"
        "--log-level", "INFO"
    )

    $proc = Start-Process rclone -ArgumentList $mount_args -WindowStyle Hidden -PassThru

    # 等待挂载真正就绪（而不是仅仅进程存在），并检测早期崩溃
    $ready   = $false
    $maxWait = 15
    $waited  = 0
    while ($waited -lt $maxWait) {
        if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
            Write-Warning "rclone exited early. Check log: $logFile"
            break
        }
        if (Test-Path $Target) {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 500
        $waited += 0.5
    }

    if (-not $ready) {
        Write-Warning "Mount not confirmed ready after ${maxWait}s. Check log: $logFile"
        return
    }

    $newEntry = [PSCustomObject]@{
        pid       = $proc.Id
        source    = $Source
        target    = $Target
        rcAddr    = $thisRcAddr
        logFile   = $logFile
        mountedAt = (Get-Date -Format "o")
    }

    $state += $newEntry
    save_rclone_state $state
    $script:rcloneMountPid = $proc.Id

    Write-Host "Mounted $Source to $Target (PID: $($proc.Id), log: $logFile)"
}

function rlist {
    $state = get_rclone_state
    if (-not $state) {
        Write-Host "No active mount records found."
        return
    }
    Write-Host "Current mount records:`n"
    $state | Format-Table -AutoSize pid, source, target, rcAddr, mountedAt
}

function rflush {
    param(
        [Parameter(Position=0)] $Target
    )

    $state = get_rclone_state
    if (-not $state) {
        Write-Host "No active mount records found."
        return
    }

    $entries = if ($Target) { $state | Where-Object { $_.target -eq $Target } } else { $state }
    if (-not $entries) {
        Write-Error "No rclone mount found for target '$Target'. Use rlist to see active mounts."
        return
    }

    foreach ($e in $entries) {
        rclone rc vfs/forget --rc-addr $e.rcAddr
        Write-Host "VFS cache flushed for $($e.target) (rcAddr: $($e.rcAddr))."
    }
}

function rstop {
    param(
        [Parameter(Position=0)] $Target,
        [Parameter()] $addr
    )

    $state = get_rclone_state
    $entry = $null
    if ($Target) {
        $entry = $state | Where-Object { $_.target -eq $Target } | Select-Object -First 1
    } elseif ($addr) {
        $entry = $state | Where-Object { $_.rcAddr -eq $addr } | Select-Object -First 1
    } elseif ($state.Count -eq 1) {
        $entry = $state[0]
    }

    # 如果文件记录丢失，回退到进程匹配（需要显式提供 -addr）
    if (-not $entry -and $addr) {
        $matched = Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*--rc-addr*${addr}*" } |
            Select-Object -First 1
        if ($matched) {
            $entry = [PSCustomObject]@{ pid = $matched.ProcessId; target = "unknown"; rcAddr = $addr }
            Write-Warning "No state file record found. Fallback to process match (PID: $($entry.pid))."
        }
    }

    if (-not $entry) {
        Write-Error "No rclone mount found. Specify a target (rstop Q:) or -addr <host:port>. Use rlist to see active mounts."
        return
    }

    $addr = $entry.rcAddr

    # Step 1
    $maxWait      = 60
    $waited       = 0
    $pending      = $true
    $rcFailures   = 0
    $maxRcRetries = 3
    while ($waited -lt $maxWait) {
        try {
            $stats      = Invoke-RestMethod -Uri "http://$addr/vfs/stats" -Method Post -TimeoutSec 5
            $queued     = $stats.diskCache.uploadsQueued
            $inProgress = $stats.diskCache.uploadsInProgress
            $rcFailures = 0
        } catch {
            $rcFailures++
            if ($rcFailures -ge $maxRcRetries) {
                Write-Warning "RC query failed $rcFailures times in a row, rclone may already be dead. Last error: $($_.Exception.Message)"
                $pending = $false
                break
            }
            Write-Warning "RC query failed (attempt $rcFailures/$maxRcRetries): $($_.Exception.Message). Retrying..."
            Start-Sleep -Seconds 1
            $waited += 1
            continue
        }

        if ($queued -eq 0 -and $inProgress -eq 0) {
            Write-Host "All uploads finished."
            $pending = $false
            break
        }
        Write-Host "Waiting for uploads... Queued: $queued, InProgress: $inProgress"
        Start-Sleep -Seconds 2
        $waited += 2
    }
    if ($pending) {
        Write-Warning "Timed out after ${maxWait}s with pending uploads."
    }

    # Step 2
    try {
        Invoke-RestMethod -Uri "http://$addr/core/quit" -Method Post -TimeoutSec 5 | Out-Null
        Write-Host "Rclone mount gracefully stopped."
    } catch {
        Write-Warning "core/quit request failed: $($_.Exception.Message)"
    }

    # Step 3
    Start-Sleep -Seconds 2
    $targetPid = $entry.pid
    $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Warning "Rclone still alive, forcing stop (PID: $($proc.Id))..."
        Stop-Process -Id $proc.Id -Force
    }

    # Step 4
    $cleaned = get_rclone_state | Where-Object { $_.pid -ne $targetPid }
    save_rclone_state $cleaned
    Write-Host "Mount record removed from state file."
}
