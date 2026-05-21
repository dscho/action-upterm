#!/bin/bash
# experiments/tmux-survival/setup.sh
#
# Installs upterm and tmux on a Windows runner, replicating exactly what
# the action's installDependencies() does for win32.  Also starts the
# tmux/upterm session, since MSYS2 bash has the right environment for
# tmux to create its PTY server.
#
# Must be sourced (not executed) so that PATH changes take effect in the
# calling step's environment.

set -ex

# Install tmux via MSYS2 pacman (same as the action)
if ! command -v tmux &>/dev/null; then
  pacman -S --noconfirm tmux
fi

# Download upterm binary (latest release, amd64).
# Use the /releases/latest/download redirect so we don't need to parse
# the GitHub API JSON (which has varying whitespace around colons).
UPTERM_URL="https://github.com/owenthereal/upterm/releases/latest/download/upterm_windows_amd64.tar.gz"
echo "Installing upterm from $UPTERM_URL"
mkdir -p /tmp/upterm-bin
curl -fsSL "$UPTERM_URL" | tar xz -C /tmp/upterm-bin
ls -la /tmp/upterm-bin/

# Add to PATH for subsequent steps (bash-style for this step,
# GITHUB_PATH for future steps)
export PATH="/tmp/upterm-bin:$PATH"
echo "$(cygpath -aw /tmp/upterm-bin)" >> "$GITHUB_PATH"

# Create the upterm data directories (same as getUptermDirs())
UPTERM_DATA="$(cygpath -u "$LOCALAPPDATA/Temp/upterm-data")"
mkdir -p "$UPTERM_DATA/runtime" "$UPTERM_DATA/state" "$UPTERM_DATA/config"
echo "UPTERM_DATA=$(cygpath -aw "$UPTERM_DATA")" >> "$GITHUB_ENV"

# Generate SSH keys where upterm.exe (a native Windows binary) will find them.
# upterm.exe resolves $HOME via %USERPROFILE% (C:\Users\runneradmin), not
# MSYS2's $HOME (/home/runneradmin = C:\msys64\home\runneradmin).
# Generate keys in both locations so both tmux (MSYS2) and upterm (native) work.
WIN_SSH_DIR="$(cygpath -u "$USERPROFILE")/.ssh"
MSYS_SSH_DIR="$HOME/.ssh"
for ssh_dir in "$WIN_SSH_DIR" "$MSYS_SSH_DIR"; do
  if [ ! -f "$ssh_dir/id_rsa" ]; then
    mkdir -p "$ssh_dir"
    ssh-keygen -q -t rsa -N "" -f "$ssh_dir/id_rsa"
    ssh-keygen -q -t ed25519 -N "" -f "$ssh_dir/id_ed25519"
  fi

  # Write permissive SSH config (same as configureSSHClient())
  cat >> "$ssh_dir/config" <<'SSHEOF'
Host *
  StrictHostKeyChecking no
  CheckHostIP no
  TCPKeepAlive yes
  ServerAliveInterval 30
  ServerAliveCountMax 180
  VerifyHostKeyDNS yes
  UpdateHostKeys yes
  AddressFamily inet
SSHEOF
done

echo "--- Setup complete ---"
tmux -V
upterm version

# --- Start the tmux/upterm session ---
# Build XDG paths in MSYS2/POSIX form (same as toMsys2Path)
XDG_RUNTIME="$UPTERM_DATA/runtime"
XDG_STATE="$UPTERM_DATA/state"
XDG_CONFIG="$UPTERM_DATA/config"

# Write tmux.conf (same as createUptermSession)
TMUX_CONF="$UPTERM_DATA/tmux.conf"
cat > "$TMUX_CONF" <<TMUXEOF
set-environment -g XDG_RUNTIME_DIR "$XDG_RUNTIME"
set-environment -g XDG_STATE_HOME "$XDG_STATE"
set-environment -g XDG_CONFIG_HOME "$XDG_CONFIG"
set-option -ga update-environment " UPTERM_ADMIN_SOCKET"
setw -g aggressive-resize on
TMUXEOF

TMUX_CONF_SHELL="$(cygpath -m "$TMUX_CONF")"
UPTERM_LOG="$UPTERM_DATA/state/upterm-command.log"
TMUX_ERR_LOG="$UPTERM_DATA/state/tmux-error.log"

echo "Starting tmux/upterm session..."
tmux -f "$TMUX_CONF_SHELL" new -d -s upterm-wrapper -x 132 -y 43 \
  "upterm host --skip-host-key-check --accept --server ssh://uptermd.upterm.dev:22 \
   --force-command 'tmux attach -t upterm' \
   -- tmux -f '$TMUX_CONF_SHELL' new -s upterm -x 132 -y 43 \
   2>&1 | tee '$UPTERM_LOG'" \
  2>"$TMUX_ERR_LOG"

echo "tmux new -d returned, waiting for sessions..."

# Poll for tmux readiness
for i in $(seq 1 15); do
  sleep 2
  sessions="$(tmux list-sessions 2>&1)" || true
  echo "  Poll $i: $sessions"
  if echo "$sessions" | grep -q 'upterm-wrapper' &&
     echo "$sessions" | grep -q 'upterm'; then
    echo "tmux sessions ready after $((i*2)) seconds"
    break
  fi
  if [ "$i" = "15" ]; then
    echo "ERROR: tmux sessions not ready after 30 seconds"
    cat "$TMUX_ERR_LOG" 2>/dev/null || true
    cat "$UPTERM_LOG" 2>/dev/null || true
    exit 1
  fi
done

# Poll for upterm socket
for i in $(seq 1 10); do
  if ls "$UPTERM_DATA/runtime/upterm/"*.sock 2>/dev/null; then
    echo "Upterm socket ready"
    break
  fi
  sleep 1
  if [ "$i" = "10" ]; then
    echo "WARNING: Upterm socket not found after 10 seconds"
  fi
done

# Record process info as birth certificate
echo "=== Process birth certificate ==="
EVIDENCE_DIR="$(pwd)/evidence"
mkdir -p "$EVIDENCE_DIR"

# Record PIDs (for Windows-side tools to track)
for proc_name in tmux upterm; do
  pids=$(ps -W 2>/dev/null | grep -i "${proc_name}" | awk '{print $1}' || true)
  echo "${proc_name} PIDs: $pids"
done | tee "$EVIDENCE_DIR/birth-certificate.txt"

# Also export the launcher PID for the node-kill test.
# In the real action, Node.js is the ancestor.  Here, this bash process
# is the closest equivalent.  We'll sleep in the background to keep it
# alive for the node-kill treatment.
(sleep 1800) &
LAUNCHER_BG_PID=$!
echo $LAUNCHER_BG_PID > "$(cygpath -u "$LOCALAPPDATA/Temp/upterm-data")/launcher-pid.txt"
echo "Background sleep PID (for node-kill test): $LAUNCHER_BG_PID"
echo "This bash PID: $$"
echo $$ > "$(cygpath -u "$LOCALAPPDATA/Temp/upterm-data")/bash-pid.txt"
