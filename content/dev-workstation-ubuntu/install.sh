#!/usr/bin/env bash
# Ubuntu Dev Workstation Setup
# Tested on Ubuntu 22.04 / 24.04
# Usage: curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/setup.sh | bash

set -euo pipefail

# ---------- helpers ----------
log()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m ✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m ! \033[0m %s\n" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

export DEBIAN_FRONTEND=noninteractive
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

# sudo wrapper: works whether or not script is already run as root
if [[ $EUID -ne 0 ]]; then SUDO="sudo"; else SUDO=""; fi

# ---------- sanity ----------
if ! grep -qi ubuntu /etc/os-release; then
  warn "This script targets Ubuntu. Proceeding anyway."
fi

# ---------- 1. base system ----------
log "Updating apt and installing base packages"
$SUDO apt-get update -y
$SUDO apt-get upgrade -y
$SUDO apt-get install -y \
  build-essential pkg-config ca-certificates curl wget gnupg lsb-release \
  software-properties-common apt-transport-https \
  git git-lfs tmux zsh vim neovim \
  htop tree jq unzip zip xz-utils \
  ripgrep fd-find fzf bat \
  net-tools dnsutils iputils-ping traceroute \
  python3 python3-pip python3-venv pipx \
  openssh-client gnupg2 \
  make cmake

# symlink awkward Debian binary names
[[ -f /usr/bin/batcat ]] && $SUDO ln -sf /usr/bin/batcat /usr/local/bin/bat || true
[[ -f /usr/bin/fdfind ]] && $SUDO ln -sf /usr/bin/fdfind /usr/local/bin/fd  || true
ok "Base packages installed"

# ---------- 2. Docker (official repo) ----------
if ! have docker; then
  log "Installing Docker Engine"
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io \
                           docker-buildx-plugin docker-compose-plugin
  $SUDO usermod -aG docker "$REAL_USER" || true
  ok "Docker installed (log out/in for group to take effect)"
else
  ok "Docker already installed"
fi

# ---------- 3. Node via nvm ----------
export NVM_DIR="$REAL_HOME/.nvm"
if [[ ! -d "$NVM_DIR" ]]; then
  log "Installing nvm + Node LTS"
  sudo -u "$REAL_USER" bash -c '
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    . "$NVM_DIR/nvm.sh"
    nvm install --lts
    nvm alias default lts/*
    npm install -g pnpm yarn typescript ts-node
  '
  ok "Node LTS installed via nvm"
else
  ok "nvm already present"
fi

# ---------- 4. Rust ----------
if [[ ! -d "$REAL_HOME/.cargo" ]]; then
  log "Installing Rust (rustup)"
  sudo -u "$REAL_USER" bash -c 'curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable'
  ok "Rust installed"
else
  ok "Rust already installed"
fi

# ---------- 5. Go ----------
GO_VERSION="1.23.4"
if ! have go || [[ "$(go version 2>/dev/null)" != *"go${GO_VERSION}"* ]]; then
  log "Installing Go ${GO_VERSION}"
  ARCH="$(dpkg --print-architecture)"
  TMP="$(mktemp -d)"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o "$TMP/go.tgz"
  $SUDO rm -rf /usr/local/go
  $SUDO tar -C /usr/local -xzf "$TMP/go.tgz"
  rm -rf "$TMP"
  ok "Go ${GO_VERSION} installed to /usr/local/go"
else
  ok "Go already at required version"
fi

# ---------- 6. GitHub CLI ----------
if ! have gh; then
  log "Installing GitHub CLI"
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    $SUDO dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  $SUDO chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" | \
    $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y gh
  ok "gh installed"
else
  ok "gh already installed"
fi

# ---------- 7. VS Code ----------
if ! have code; then
  log "Installing VS Code"
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | $SUDO dd of=/usr/share/keyrings/microsoft.gpg
  echo "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft.gpg] \
https://packages.microsoft.com/repos/code stable main" | \
    $SUDO tee /etc/apt/sources.list.d/vscode.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y code || warn "VS Code install failed (headless system?)"
else
  ok "VS Code already installed"
fi

# ---------- 8. pipx CLI tools ----------
log "Installing Python CLI tools via pipx"
sudo -u "$REAL_USER" bash -c '
  pipx ensurepath >/dev/null 2>&1 || true
  for pkg in poetry httpie ruff uv; do
    pipx install "$pkg" 2>/dev/null || pipx upgrade "$pkg" 2>/dev/null || true
  done
'
ok "pipx tools ready"

# ---------- 9. Shell niceties ----------
RC="$REAL_HOME/.bashrc"
MARKER="# >>> dev-workstation setup >>>"
if ! grep -q "$MARKER" "$RC" 2>/dev/null; then
  log "Appending PATH + aliases to ~/.bashrc"
  cat <<'EOF' >> "$RC"

# >>> dev-workstation setup >>>
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/go/bin:$HOME/go/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

alias ll='ls -alhF'
alias la='ls -A'
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate -20'
alias dps='docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"'
# <<< dev-workstation setup <<<
EOF
  chown "$REAL_USER:$REAL_USER" "$RC"
  ok "Shell config updated"
else
  ok "Shell config already has setup block"
fi

# ---------- done ----------
echo
ok "All done."
echo "Installed: git, docker, node(lts), rust, go ${GO_VERSION}, gh, vscode, python+pipx tools,"
echo "           ripgrep, fd, fzf, bat, tmux, neovim, and more."
echo
echo "Next:"
echo "  1. Close and reopen your terminal (or: source ~/.bashrc)"
echo "  2. Log out and back in for the 'docker' group to apply"
echo "  3. Configure git:  git config --global user.name '...'  &&  git config --global user.email '...'"
