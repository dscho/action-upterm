# experiments/tmux-survival/start-via-schtasks.ps1
#
# Starts the tmux/upterm session via Windows Task Scheduler.
# Scheduled tasks run under the Task Scheduler service, outside
# the runner's Job Object.

$ErrorActionPreference = 'Stop'

$uptermData = $env:UPTERM_DATA
$evidenceDir = Join-Path $PWD 'evidence'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

# Reuse the startup script from WMI (or create one)
$startScript = Join-Path $uptermData 'start-tmux.sh'
if (-not (Test-Path $startScript)) {
    # Build minimal startup script
    $xdgBase = ($uptermData -replace '\\','/')
    if ($xdgBase -match '^([A-Za-z]):') { $xdgBase = '/' + $matches[1].ToLower() + $xdgBase.Substring(2) }

    $tmuxConf = @"
set-environment -g XDG_RUNTIME_DIR "$xdgBase/runtime"
set-environment -g XDG_STATE_HOME "$xdgBase/state"
set-environment -g XDG_CONFIG_HOME "$xdgBase/config"
set-option -ga update-environment " UPTERM_ADMIN_SOCKET"
setw -g aggressive-resize on
"@
    $tmuxConfPath = Join-Path $uptermData 'tmux.conf'
    Set-Content -Path $tmuxConfPath -Value $tmuxConf -NoNewline
    $tmuxConfPosix = "$xdgBase/tmux.conf"
    $uptermLog = "$xdgBase/state/upterm-command.log"

    $script = @"
#!/bin/bash
export PATH="/tmp/upterm-bin:`$PATH"
export MSYS2_PATH_TYPE=inherit
export CHERE_INVOKING=1
export MSYSTEM=MINGW64
tmux -f '$tmuxConfPosix' new -d -s upterm-wrapper -x 132 -y 43 \
  "upterm host --skip-host-key-check --accept --server ssh://uptermd.upterm.dev:22 \
   --force-command 'tmux attach -t upterm' \
   -- tmux -f '$tmuxConfPosix' new -s upterm -x 132 -y 43 \
   2>&1 | tee '$uptermLog'"
sleep 1800
"@
    Set-Content -Path $startScript -Value $script -NoNewline
}

Write-Host "Starting tmux via schtasks..."

$taskName = "UptermdTmuxStart"
$bashExe = 'C:\msys64\usr\bin\bash.exe'

# Create and immediately run a scheduled task
schtasks /create /tn $taskName /tr "$bashExe -l $startScript" `
    /sc once /st 00:00 /f /ru $env:USERNAME 2>&1 | Write-Host
schtasks /run /tn $taskName 2>&1 | Write-Host

"schtasks" | Out-File "$evidenceDir/launch-method.txt"

# Wait for tmux to become ready
for ($i = 1; $i -le 20; $i++) {
    Start-Sleep 2
    try {
        $sessions = & $bashExe -lc 'tmux list-sessions 2>&1' 2>&1 | Out-String
        if ($sessions -match 'upterm-wrapper' -and $sessions -match 'upterm') {
            Write-Host "tmux ready after $($i*2)s: $sessions"
            break
        }
    } catch {}
    if ($i -eq 20) {
        Write-Host "ERROR: tmux not ready after 40s"
        & $bashExe -lc 'tmux list-sessions 2>&1' 2>&1 | Write-Host
    }
}
