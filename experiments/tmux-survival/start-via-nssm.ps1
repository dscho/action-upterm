# experiments/tmux-survival/start-via-nssm.ps1
#
# Starts the tmux/upterm session as a Windows service using NSSM
# (Non-Sucking Service Manager).  Services run under the Service
# Control Manager, completely outside any user Job Object.

$ErrorActionPreference = 'Stop'

$uptermData = $env:UPTERM_DATA
$evidenceDir = Join-Path $PWD 'evidence'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

# Install NSSM via Chocolatey (pre-installed on GitHub runners)
Write-Host "Installing NSSM..."
choco install nssm -y --no-progress 2>&1 | Select-Object -Last 5 | Write-Host
$nssmPath = (Get-Command nssm -ErrorAction SilentlyContinue).Source
if (-not $nssmPath) {
    # Try common location
    $nssmPath = 'C:\ProgramData\chocolatey\bin\nssm.exe'
}
Write-Host "NSSM at: $nssmPath"

# Reuse or create the startup script
$startScript = Join-Path $uptermData 'start-tmux.sh'
if (-not (Test-Path $startScript)) {
    $xdgBase = ($uptermData -replace '\\','/')
    if ($xdgBase -match '^([A-Za-z]):') { $xdgBase = '/' + $matches[1].ToLower() + $xdgBase.Substring(2) }

    $tmuxConf = @"
set-environment -g XDG_RUNTIME_DIR "$xdgBase/runtime"
set-environment -g XDG_STATE_HOME "$xdgBase/state"
set-environment -g XDG_CONFIG_HOME "$xdgBase/config"
set-option -ga update-environment " UPTERM_ADMIN_SOCKET"
setw -g aggressive-resize on
"@
    Set-Content -Path (Join-Path $uptermData 'tmux.conf') -Value $tmuxConf -NoNewline
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

$bashExe = 'C:\msys64\usr\bin\bash.exe'
$svcName = 'UptermdTmux'

Write-Host "Creating service $svcName..."
& $nssmPath install $svcName $bashExe "-l $startScript" 2>&1 | Write-Host
& $nssmPath set $svcName AppDirectory $uptermData 2>&1 | Write-Host
& $nssmPath set $svcName AppStdout (Join-Path $evidenceDir 'nssm-stdout.log') 2>&1 | Write-Host
& $nssmPath set $svcName AppStderr (Join-Path $evidenceDir 'nssm-stderr.log') 2>&1 | Write-Host

Write-Host "Starting service..."
& $nssmPath start $svcName 2>&1 | Write-Host
"nssm-service" | Out-File "$evidenceDir/launch-method.txt"

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
        & $nssmPath status $svcName 2>&1 | Write-Host
        if (Test-Path (Join-Path $evidenceDir 'nssm-stderr.log')) {
            Get-Content (Join-Path $evidenceDir 'nssm-stderr.log') | Write-Host
        }
    }
}
