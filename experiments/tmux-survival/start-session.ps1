# experiments/tmux-survival/start-session.ps1
#
# Starts the nested tmux/upterm session topology that the action uses,
# records PIDs of all involved processes, and saves a "birth certificate"
# with timestamps and process details.
#
# This script runs in PowerShell but invokes bash to start tmux, exactly
# as the action does (via execShellCommand which spawns bash.exe).

$ErrorActionPreference = 'Stop'

$uptermData = $env:UPTERM_DATA
$evidenceDir = Join-Path $PWD 'evidence'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

# Convert to MSYS2-style paths for XDG vars (same as toMsys2Path)
function ConvertTo-Msys2Path($p) {
    $p = $p -replace '\\','/'
    if ($p -match '^([A-Za-z]):') {
        $p = '/' + $matches[1].ToLower() + $p.Substring(2)
    }
    return $p
}

$xdgRuntime = ConvertTo-Msys2Path "$uptermData\runtime"
$xdgState   = ConvertTo-Msys2Path "$uptermData\state"
$xdgConfig  = ConvertTo-Msys2Path "$uptermData\config"

# Write tmux.conf (same as createUptermSession)
$tmuxConf = @"
set-environment -g XDG_RUNTIME_DIR "$xdgRuntime"
set-environment -g XDG_STATE_HOME "$xdgState"
set-environment -g XDG_CONFIG_HOME "$xdgConfig"
set-option -ga update-environment " UPTERM_ADMIN_SOCKET"
setw -g aggressive-resize on
"@

$tmuxConfPath = Join-Path $uptermData 'tmux.conf'
Set-Content -Path $tmuxConfPath -Value $tmuxConf -NoNewline
$tmuxConfShell = ($tmuxConfPath -replace '\\','/')
$tmuxConfPosix = ConvertTo-Msys2Path $tmuxConfPath

$uptermLog = ConvertTo-Msys2Path (Join-Path $uptermData 'state\upterm-command.log')
$tmuxErrLog = ConvertTo-Msys2Path (Join-Path $uptermData 'state\tmux-error.log')

# The exact command line the action builds in createUptermSession().
# We use the public upterm server with --skip-host-key-check and --accept
# (no authorized keys restriction, since this is a throwaway experiment).
$bashCmd = @"
tmux -f '$tmuxConfShell' new -d -s upterm-wrapper -x 132 -y 43 "upterm host --skip-host-key-check --accept --server ssh://uptermd.upterm.dev:22 --force-command 'tmux attach -t upterm' -- tmux -f $tmuxConfPosix new -s upterm -x 132 -y 43 2>&1 | tee $uptermLog" 2>$tmuxErrLog
"@

Write-Host "Starting tmux/upterm with:"
Write-Host $bashCmd

# Launch via bash.exe, same as execShellCommand on win32
$bashExe = 'C:\msys64\usr\bin\bash.exe'
$env:MSYS2_PATH_TYPE = 'inherit'
$env:CHERE_INVOKING = '1'
$env:MSYSTEM = 'MINGW64'

# Start bash as a background job so we can capture its PID.
# For the node-kill treatment, we want a long-running parent process
# (simulating the Node.js action host).  So we start a bash that:
#   1. runs the tmux command
#   2. then sleeps for 30 minutes (keeping the process tree alive)
# The node-kill job terminates this bash to test H2.
#
# We use Start-Process *without* -RedirectStandardOutput/-Error because
# MSYS2's tmux needs inherited console handles to initialize its PTY
# server.  -NoNewWindow ensures bash shares the current console.
$bashCmdWithSleep = "$bashCmd; sleep 1800"

$proc = Start-Process -FilePath $bashExe `
    -ArgumentList '-lc',$bashCmdWithSleep `
    -NoNewWindow -PassThru

# Record the launcher PID (for the node-kill treatment)
$proc.Id | Out-File -FilePath "$uptermData\launcher-pid.txt"
Write-Host "Launcher bash.exe PID: $($proc.Id)"

# Wait for tmux to be ready (the tmux new -d returns quickly, but we
# need upterm to initialize).  Poll for up to 30 seconds.
$ready = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep 2
    try {
        $sessions = & $bashExe -lc 'tmux list-sessions 2>&1' 2>&1 | Out-String
        if ($sessions -match 'upterm-wrapper' -and $sessions -match 'upterm') {
            Write-Host "tmux sessions ready after $((($i+1)*2)) seconds:"
            Write-Host $sessions
            $ready = $true
            break
        }
    } catch {}
}

if (-not $ready) {
    Write-Host "ERROR: tmux sessions not ready after 30 seconds"
    try { & $bashExe -lc 'tmux list-sessions 2>&1' 2>&1 | Write-Host } catch {}
    throw "tmux/upterm failed to start - experiment cannot proceed"
}

# Also verify the upterm socket appeared
$socketDir = Join-Path $uptermData 'runtime\upterm'
$socketReady = $false
for ($i = 0; $i -lt 10; $i++) {
    if ((Test-Path $socketDir) -and (Get-ChildItem $socketDir -Filter '*.sock' -ErrorAction SilentlyContinue)) {
        $socketReady = $true
        $socks = Get-ChildItem $socketDir -Filter '*.sock'
        Write-Host "Upterm socket ready: $($socks.Name -join ', ')"
        break
    }
    Start-Sleep 1
}

if (-not $socketReady) {
    Write-Host "WARNING: Upterm socket not found after 10 seconds (upterm may still be initializing)"
}

# Record all tmux/upterm process info as the "birth certificate"
Write-Host ""
Write-Host "=== Process snapshot after session start ==="
$snapshot = Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match 'tmux|upterm|bash' } |
    Select-Object ProcessId,ParentProcessId,Name,CommandLine,CreationDate |
    Format-Table -AutoSize | Out-String
Write-Host $snapshot
$snapshot | Out-File "$evidenceDir\birth-certificate.txt"

# Record specific tmux/upterm PIDs for targeted tracking
$tmuxProcs = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'tmux.exe' }
$uptermProcs = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'upterm.exe' }

$pidInfo = @()
foreach ($tp in $tmuxProcs) {
    $line = "tmux PID=$($tp.ProcessId) PPID=$($tp.ParentProcessId) CMD=$($tp.CommandLine)"
    Write-Host $line
    $pidInfo += $line
}
foreach ($up in $uptermProcs) {
    $line = "upterm PID=$($up.ProcessId) PPID=$($up.ParentProcessId) CMD=$($up.CommandLine)"
    Write-Host $line
    $pidInfo += $line
}
$pidInfo | Out-File "$evidenceDir\tracked-pids.txt"
