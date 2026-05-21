# experiments/tmux-survival/collect.ps1
#
# Runs in an always() step after the treatment.  Gathers all evidence
# into the evidence/ directory for artifact upload.

$ErrorActionPreference = 'Continue'

$evidenceDir = Join-Path $PWD 'evidence'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

$uptermData = $env:UPTERM_DATA

Write-Host "========================================="
Write-Host "  EVIDENCE COLLECTION"
Write-Host "========================================="
Write-Host ""

# 1. Current timestamp
$now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
Write-Host "Collection time: $now"
$now | Out-File "$evidenceDir\collection-time.txt"

# 2. Process snapshot
Write-Host ""
Write-Host "=== Current process snapshot ==="
$allProcs = Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match 'tmux|upterm|bash|node|pwsh|powershell' } |
    Select-Object ProcessId,ParentProcessId,Name,CommandLine,CreationDate
$allProcs | Format-Table -AutoSize | Out-String | Tee-Object -FilePath "$evidenceDir\process-snapshot.txt" | Write-Host

# 3. tmux status
Write-Host ""
Write-Host "=== tmux status ==="
$bashExe = 'C:\msys64\usr\bin\bash.exe'
$env:MSYS2_PATH_TYPE = 'inherit'
$env:CHERE_INVOKING = '1'
$env:MSYSTEM = 'MINGW64'

try {
    $tmuxList = & $bashExe -lc 'tmux list-sessions 2>&1; echo "EXIT:$?"' 2>&1
    $tmuxList | Tee-Object -FilePath "$evidenceDir\tmux-list-sessions.txt" | Write-Host
} catch {
    "ERROR: $_" | Tee-Object -FilePath "$evidenceDir\tmux-list-sessions.txt" | Write-Host
}

try {
    $tmuxClients = & $bashExe -lc "tmux list-clients -t upterm 2>&1; echo 'EXIT:`$?'" 2>&1
    $tmuxClients | Tee-Object -FilePath "$evidenceDir\tmux-list-clients.txt" | Write-Host
} catch {
    "ERROR: $_" | Tee-Object -FilePath "$evidenceDir\tmux-list-clients.txt" | Write-Host
}

# 4. Socket file check
Write-Host ""
Write-Host "=== Socket files ==="
$socketDir = Join-Path $uptermData 'runtime\upterm'
if (Test-Path $socketDir) {
    $socks = Get-ChildItem $socketDir -ErrorAction SilentlyContinue
    if ($socks) {
        $socks | Format-Table Name,Length,LastWriteTime | Out-String |
            Tee-Object -FilePath "$evidenceDir\socket-files.txt" | Write-Host
    } else {
        "Directory exists but no files found" |
            Tee-Object -FilePath "$evidenceDir\socket-files.txt" | Write-Host
    }
} else {
    "Socket directory does not exist: $socketDir" |
        Tee-Object -FilePath "$evidenceDir\socket-files.txt" | Write-Host
}

# 5. Upterm data directory listing
Write-Host ""
Write-Host "=== Upterm data directory ==="
if (Test-Path $uptermData) {
    Get-ChildItem $uptermData -Recurse -ErrorAction SilentlyContinue |
        Select-Object FullName,Length,LastWriteTime |
        Format-Table -AutoSize | Out-String |
        Tee-Object -FilePath "$evidenceDir\upterm-data-listing.txt" | Write-Host
}

# 6. Upterm command log
Write-Host ""
Write-Host "=== Upterm command log ==="
$cmdLog = Join-Path $uptermData 'state\upterm-command.log'
if (Test-Path $cmdLog) {
    Get-Content $cmdLog |
        Tee-Object -FilePath "$evidenceDir\upterm-command.log" | Write-Host
} else {
    "No upterm command log found" | Write-Host
}

# 7. Tmux error log
$tmuxErrLog = Join-Path $uptermData 'state\tmux-error.log'
if (Test-Path $tmuxErrLog) {
    Write-Host ""
    Write-Host "=== Tmux error log ==="
    Get-Content $tmuxErrLog |
        Tee-Object -FilePath "$evidenceDir\tmux-error.log" | Write-Host
}

# 8. Stop and collect the watchdog log
Write-Host ""
Write-Host "=== Watchdog log (last 50 lines) ==="
$watchdogLog = Join-Path $evidenceDir 'watchdog.log'
if (Test-Path $watchdogLog) {
    $lines = Get-Content $watchdogLog
    Write-Host "Total watchdog log lines: $($lines.Count)"
    $lines | Select-Object -Last 50 | Write-Host

    # Find the transition point where tmux went from alive to dead
    Write-Host ""
    Write-Host "=== Death transition ==="
    $prevLine = $null
    foreach ($line in $lines) {
        if ($prevLine -and $prevLine -notmatch 'tmux=\[DEAD\]' -and $line -match 'tmux=\[DEAD\]') {
            Write-Host "LAST ALIVE: $prevLine"
            Write-Host "FIRST DEAD: $line"
        }
        $prevLine = $line
    }
    if ($lines[-1] -notmatch 'tmux=\[DEAD\]') {
        Write-Host "tmux was still ALIVE at last watchdog entry"
    }
} else {
    "No watchdog log found" | Write-Host
}

# 9. Stop the watchdog process
$watchdogPidFile = Join-Path $evidenceDir 'watchdog-pid.txt'
if (Test-Path $watchdogPidFile) {
    $wdPid = [int](Get-Content $watchdogPidFile).Trim()
    Write-Host ""
    Write-Host "Stopping watchdog (PID $wdPid)"
    Stop-Process -Id $wdPid -Force -ErrorAction SilentlyContinue
}

# 10. Windows Security event log: process termination events
Write-Host ""
Write-Host "=== Process termination events (Security log, last 5 min) ==="
try {
    $cutoff = (Get-Date).AddMinutes(-10)
    $events = Get-WinEvent -FilterHashtable @{
        LogName='Security'
        Id=4689
        StartTime=$cutoff
    } -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'tmux|upterm|bash' }

    if ($events) {
        $events | ForEach-Object {
            "$($_.TimeCreated) | EventID=$($_.Id) | $($_.Message)" |
                Tee-Object -Append -FilePath "$evidenceDir\security-events.txt" | Write-Host
        }
    } else {
        "No tmux/upterm/bash termination events found (audit policy may not be enabled)" |
            Tee-Object -FilePath "$evidenceDir\security-events.txt" | Write-Host
    }
} catch {
    "Could not read Security log: $_" |
        Tee-Object -FilePath "$evidenceDir\security-events.txt" | Write-Host
}

# 11. Application event log: any upterm/tmux errors
Write-Host ""
Write-Host "=== Application event log (last 10 min) ==="
try {
    $cutoff = (Get-Date).AddMinutes(-10)
    $appEvents = Get-WinEvent -FilterHashtable @{
        LogName='Application'
        StartTime=$cutoff
    } -MaxEvents 100 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'tmux|upterm' }

    if ($appEvents) {
        $appEvents | ForEach-Object {
            "$($_.TimeCreated) | Source=$($_.ProviderName) | $($_.Message)"
        } | Tee-Object -FilePath "$evidenceDir\app-events.txt" | Write-Host
    } else {
        "No relevant Application log events" | Write-Host
    }
} catch {
    "Could not read Application log: $_" | Write-Host
}

# 12. Watchdog reliability check
Write-Host ""
Write-Host "=== Watchdog reliability ==="
$methodFile = Join-Path $evidenceDir 'watchdog-method.txt'
if (Test-Path $methodFile) {
    $method = (Get-Content $methodFile).Trim()
    Write-Host "Watchdog launch method: $method"
    if ($method -match 'UNRELIABLE') {
        Write-Host "WARNING: Watchdog may have been killed by the step timeout."
        Write-Host "Evidence from the watchdog log may be INCOMPLETE."
    }
} else {
    Write-Host "WARNING: No watchdog method file found"
}

$parentFile = Join-Path $evidenceDir 'watchdog-parent.txt'
if (Test-Path $parentFile) {
    Get-Content $parentFile | Write-Host
}

# 13. Summary verdict
Write-Host ""
Write-Host "========================================="
Write-Host "  VERDICT"
Write-Host "========================================="

$tmuxAlive = [bool](Get-CimInstance Win32_Process -Filter "Name='tmux.exe'" -ErrorAction SilentlyContinue)
$uptermAlive = [bool](Get-CimInstance Win32_Process -Filter "Name='upterm.exe'" -ErrorAction SilentlyContinue)
$socketPresent = (Test-Path $socketDir) -and [bool](Get-ChildItem $socketDir -Filter '*.sock' -ErrorAction SilentlyContinue)

$verdict = @"
tmux.exe alive:   $tmuxAlive
upterm.exe alive: $uptermAlive
socket present:   $socketPresent
"@

$verdict | Tee-Object -FilePath "$evidenceDir\verdict.txt" | Write-Host
