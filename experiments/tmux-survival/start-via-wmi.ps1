# experiments/tmux-survival/start-via-wmi.ps1
#
# Starts the tmux/upterm session by launching bash.exe via WMI
# (Win32_Process::Create).  Processes created this way are parented
# by WmiPrvSE.exe, outside the runner step's Job Object.

$ErrorActionPreference = 'Stop'

$uptermData = $env:UPTERM_DATA
$evidenceDir = Join-Path $PWD 'evidence'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

# Write the tmux startup script to a file so WMI can run it
$startScript = Join-Path $uptermData 'start-tmux.sh'

# Build XDG paths
$xdgRuntime = ($uptermData -replace '\\','/') -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() }
if ($xdgRuntime -notmatch '^/') {
    $xdgRuntime = ($uptermData -replace '\\','/')
    if ($xdgRuntime -match '^([A-Za-z]):') { $xdgRuntime = '/' + $matches[1].ToLower() + $xdgRuntime.Substring(2) }
}
$xdgState = "$xdgRuntime/state"
$xdgConfig = "$xdgRuntime/config"

$tmuxConf = @"
set-environment -g XDG_RUNTIME_DIR "$xdgRuntime/runtime"
set-environment -g XDG_STATE_HOME "$xdgState"
set-environment -g XDG_CONFIG_HOME "$xdgConfig"
set-option -ga update-environment " UPTERM_ADMIN_SOCKET"
setw -g aggressive-resize on
"@
$tmuxConfPath = Join-Path $uptermData 'tmux.conf'
Set-Content -Path $tmuxConfPath -Value $tmuxConf -NoNewline

$tmuxConfPosix = $xdgRuntime -replace '/runtime$','/tmux.conf'
# Fix: use the actual conf path
$tmuxConfPosix = ($tmuxConfPath -replace '\\','/') -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() }
if ($tmuxConfPosix -notmatch '^/') {
    if ($tmuxConfPosix -match '^([A-Za-z]):') { $tmuxConfPosix = '/' + $matches[1].ToLower() + $tmuxConfPosix.Substring(2) }
}

$uptermLog = "$xdgState/upterm-command.log"

# The bash script that starts tmux
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

# Keep running so tmux server stays alive
sleep 1800
"@
Set-Content -Path $startScript -Value $script -NoNewline

Write-Host "Starting tmux via WMI..."
$bashExe = 'C:\msys64\usr\bin\bash.exe'
$cmdLine = "$bashExe -l $startScript"

$result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = $cmdLine
}

if ($result.ReturnValue -eq 0) {
    Write-Host "WMI spawn succeeded, PID: $($result.ProcessId)"
    $result.ProcessId | Out-File "$evidenceDir/wmi-pid.txt"
    "wmi" | Out-File "$evidenceDir/launch-method.txt"
} else {
    Write-Host "ERROR: WMI spawn failed with return value $($result.ReturnValue)"
    "wmi-FAILED" | Out-File "$evidenceDir/launch-method.txt"
}

# Wait for tmux to become ready
$bashExe2 = 'C:\msys64\usr\bin\bash.exe'
for ($i = 1; $i -le 20; $i++) {
    Start-Sleep 2
    try {
        $sessions = & $bashExe2 -lc 'tmux list-sessions 2>&1' 2>&1 | Out-String
        if ($sessions -match 'upterm-wrapper' -and $sessions -match 'upterm') {
            Write-Host "tmux ready after $($i*2)s: $sessions"
            break
        }
    } catch {}
    if ($i -eq 20) {
        Write-Host "ERROR: tmux not ready after 40s"
        & $bashExe2 -lc 'tmux list-sessions 2>&1' 2>&1 | Write-Host
    }
}
