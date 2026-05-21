# experiments/tmux-survival/start-watchdog.ps1
#
# Launches a watchdog process via WMI (Win32_Process::Create), which
# starts the process under svchost.exe, outside the runner step's Job
# Object.  This ensures the watchdog survives even if the step's entire
# process tree is killed (e.g., by timeout-minutes).
#
# The watchdog polls every 2 seconds and logs:
#   - Whether tmux.exe and upterm.exe are alive (with PIDs)
#   - The tmux socket file existence
#   - A high-resolution timestamp
#
# Output goes to evidence\watchdog.log.

$ErrorActionPreference = 'Stop'

$evidenceDir = (Join-Path $PWD 'evidence') -replace '\\','/'
$evidenceDir = (Resolve-Path $evidenceDir).Path
$uptermData  = $env:UPTERM_DATA

# The watchdog script body.  We write it to a .ps1 file, then launch it
# via WMI so it escapes the Job Object.
$watchdogScript = @"
`$logFile = '$evidenceDir\watchdog.log'
`$uptermData = '$uptermData'
`$socketDir = Join-Path `$uptermData 'runtime\upterm'

while (`$true) {
    `$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'

    # Check tmux processes
    `$tmuxProcs = Get-CimInstance Win32_Process -Filter "Name='tmux.exe'" -ErrorAction SilentlyContinue
    `$tmuxInfo = if (`$tmuxProcs) {
        (`$tmuxProcs | ForEach-Object { "PID=`$(`$_.ProcessId) PPID=`$(`$_.ParentProcessId)" }) -join '; '
    } else { 'DEAD' }

    # Check upterm processes
    `$uptermProcs = Get-CimInstance Win32_Process -Filter "Name='upterm.exe'" -ErrorAction SilentlyContinue
    `$uptermInfo = if (`$uptermProcs) {
        (`$uptermProcs | ForEach-Object { "PID=`$(`$_.ProcessId) PPID=`$(`$_.ParentProcessId)" }) -join '; '
    } else { 'DEAD' }

    # Check socket file
    `$socketExists = if (Test-Path `$socketDir) {
        `$socks = Get-ChildItem `$socketDir -Filter '*.sock' -ErrorAction SilentlyContinue
        if (`$socks) { "YES (`$(`$socks.Name -join ', '))" } else { 'NO (dir exists, no .sock)' }
    } else { 'NO (dir missing)' }

    # Check bash processes related to upterm
    `$bashProcs = Get-CimInstance Win32_Process -Filter "Name='bash.exe'" -ErrorAction SilentlyContinue
    `$bashCount = if (`$bashProcs) { `$bashProcs.Count } else { 0 }

    `$line = "`$ts | tmux=[`$tmuxInfo] upterm=[`$uptermInfo] socket=[`$socketExists] bash_count=`$bashCount"
    Add-Content -Path `$logFile -Value `$line

    Start-Sleep 2
}
"@

$watchdogPath = Join-Path $evidenceDir 'watchdog-script.ps1'
Set-Content -Path $watchdogPath -Value $watchdogScript

Write-Host "Watchdog script written to $watchdogPath"

# Launch via WMI to escape the Job Object
$cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$watchdogPath`""
Write-Host "Launching watchdog via WMI: $cmdLine"

$result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = $cmdLine
    CurrentDirectory = $evidenceDir
}

if ($result.ReturnValue -eq 0) {
    $watchdogPid = $result.ProcessId
    Write-Host "Watchdog started via WMI, PID: $watchdogPid"
    $watchdogPid | Out-File "$evidenceDir\watchdog-pid.txt"
    "wmi" | Out-File "$evidenceDir\watchdog-method.txt"

    # Verify the watchdog is parented by WmiPrvSE (proves Job Object escape)
    Start-Sleep 1
    try {
        $wdProc = Get-CimInstance Win32_Process -Filter "ProcessId=$watchdogPid"
        $parentProc = Get-CimInstance Win32_Process -Filter "ProcessId=$($wdProc.ParentProcessId)"
        $parentInfo = "Watchdog PID=$watchdogPid Parent=$($parentProc.Name) (PID=$($parentProc.ProcessId))"
        Write-Host $parentInfo
        $parentInfo | Out-File "$evidenceDir\watchdog-parent.txt"
    } catch {
        Write-Host "Could not verify watchdog parent: $_"
    }
} else {
    Write-Host "ERROR: WMI launch failed with return value $($result.ReturnValue)"
    Write-Host "The watchdog will NOT be able to survive a step timeout."
    Write-Host "Falling back to Start-Process, but marking evidence as UNRELIABLE."
    "start-process-UNRELIABLE" | Out-File "$evidenceDir\watchdog-method.txt"
    $fallback = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$watchdogPath `
        -NoNewWindow -PassThru
    $fallback.Id | Out-File "$evidenceDir\watchdog-pid.txt"
    Write-Host "Fallback watchdog PID: $($fallback.Id)"
}

# Let the watchdog start and write its first entry
Start-Sleep 3
if (Test-Path "$evidenceDir\watchdog.log") {
    Write-Host "Watchdog log started:"
    Get-Content "$evidenceDir\watchdog.log" | Select-Object -Last 3
} else {
    Write-Host "WARNING: watchdog.log not yet created"
}
