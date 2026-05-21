# experiments/tmux-survival/start-via-breakaway.ps1
#
# Attempts to start bash.exe with CREATE_BREAKAWAY_FROM_JOB flag
# via CreateProcess directly.  This will fail with ACCESS_DENIED
# if the Job Object doesn't have JOB_OBJECT_LIMIT_BREAKAWAY_OK,
# which is valuable diagnostic information.

$ErrorActionPreference = 'Stop'

$uptermData = $env:UPTERM_DATA
$evidenceDir = Join-Path $PWD 'evidence'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

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

Write-Host "Attempting CreateProcess with CREATE_BREAKAWAY_FROM_JOB..."

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class ProcessCreator {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
        public int dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcess(
        string lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        bool bInheritHandles, uint dwCreationFlags,
        IntPtr lpEnvironment, string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    // CREATE_BREAKAWAY_FROM_JOB = 0x01000000
    // CREATE_NEW_PROCESS_GROUP  = 0x00000200
    // DETACHED_PROCESS          = 0x00000008
    public const uint BREAKAWAY = 0x01000000;
    public const uint NEW_GROUP = 0x00000200;
    public const uint DETACHED  = 0x00000008;

    public static int Launch(string cmdLine, uint flags) {
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(si);
        PROCESS_INFORMATION pi;
        bool ok = CreateProcess(null, cmdLine, IntPtr.Zero, IntPtr.Zero,
            false, flags, IntPtr.Zero, null, ref si, out pi);
        if (!ok) return -Marshal.GetLastWin32Error();
        return pi.dwProcessId;
    }
}
"@

$bashExe = 'C:\msys64\usr\bin\bash.exe'
$cmdLine = "$bashExe -l $startScript"

# Try with BREAKAWAY + DETACHED + NEW_GROUP
$flags = [ProcessCreator]::BREAKAWAY -bor [ProcessCreator]::DETACHED -bor [ProcessCreator]::NEW_GROUP
$pid = [ProcessCreator]::Launch($cmdLine, $flags)

if ($pid -gt 0) {
    Write-Host "SUCCESS: CreateProcess with BREAKAWAY succeeded, PID=$pid"
    "breakaway-SUCCESS" | Out-File "$evidenceDir/launch-method.txt"
    $pid | Out-File "$evidenceDir/breakaway-pid.txt"
} else {
    $err = -$pid
    Write-Host "FAILED: CreateProcess with BREAKAWAY failed, error=$err"
    if ($err -eq 5) { Write-Host "  ERROR_ACCESS_DENIED: Job Object does not allow breakaway" }

    # Fallback: try without BREAKAWAY (just DETACHED + NEW_GROUP)
    $flags2 = [ProcessCreator]::DETACHED -bor [ProcessCreator]::NEW_GROUP
    $pid2 = [ProcessCreator]::Launch($cmdLine, $flags2)
    if ($pid2 -gt 0) {
        Write-Host "Fallback (DETACHED only) succeeded, PID=$pid2"
        "detached-only" | Out-File "$evidenceDir/launch-method.txt"
    } else {
        Write-Host "Fallback also failed, error=$(-$pid2)"
        "all-FAILED" | Out-File "$evidenceDir/launch-method.txt"
    }
}

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
