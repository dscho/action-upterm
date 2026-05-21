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

echo "--- Deps-only setup complete (no session started) ---"
tmux -V
upterm version

