#!/usr/bin/env bash
# ==============================================================================
# dotfiles-core: Declarative Bootstrap & Sync Script
# Works on macOS, Debian, and Ubuntu.
# ==============================================================================

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IS_MACOS=false
IS_LINUX=false
DISTRO=""

# --- Detect OS & Distribution ---
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    IS_MACOS=true
    DISTRO="macos"
  elif [[ -f /etc/os-release ]]; then
    IS_LINUX=true
    if grep -qi "ubuntu" /etc/os-release; then
      DISTRO="ubuntu"
    elif grep -qi "debian" /etc/os-release; then
      DISTRO="debian"
    else
      DISTRO="linux"
    fi
  else
    DISTRO="unknown"
  fi
  echo "Detected OS: $DISTRO"
}

# --- Install Dependencies ---
install_dependencies() {
  echo "=================================================="
  echo "📦 Checking and installing dependencies..."

  if [ "$IS_MACOS" = true ]; then
    if ! command -v brew &>/dev/null; then
      echo "Homebrew not found. Please install Homebrew from https://brew.sh first."
      exit 1
    fi
    brew install stow starship ripgrep fzf || true
  elif [ "$IS_LINUX" = true ]; then
    if command -v apt-get &>/dev/null; then
      sudo apt-get update -y
      sudo apt-get install -y stow tmux curl git ripgrep fzf build-essential || true
    fi
    # Install Starship if not present
    if ! command -v starship &>/dev/null; then
      echo "Installing Starship..."
      curl -sS https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin" || true
      export PATH="$HOME/.local/bin:$PATH"
    fi
  fi
}

# --- Pre-create directories to prevent GNU Stow tree-folding ---
prepare_stow_dirs() {
  echo "=================================================="
  echo "📁 Preparing directory structures..."
  mkdir -p "$HOME/.config/ghostty"
  mkdir -p "$HOME/.config/nvim"
  mkdir -p "$HOME/.config/tmux"
  mkdir -p "$HOME/.config/Code/User"
  mkdir -p "$HOME/.local/bin"
}

# --- Stow Configurations ---
stow_packages() {
  echo "=================================================="
  echo "🔗 Linking configuration packages with GNU Stow..."

  cd "$DOTFILES_DIR"

  local TARGET_PACKAGES=()
  if [ "$#" -gt 0 ]; then
    TARGET_PACKAGES=("$@")
  elif [ "$IS_MACOS" = true ]; then
    # Default for macOS Work Laptop
    TARGET_PACKAGES=("ghostty" "vscode" "starship")
  else
    # Default for Linux Remote Workstation
    TARGET_PACKAGES=("nvim" "tmux" "starship")
  fi

  for pkg in "${TARGET_PACKAGES[@]}"; do
    if [ -d "$DOTFILES_DIR/$pkg" ]; then
      echo "  Linking: $pkg"
      stow -R "$pkg" -t "$HOME"
    else
      echo "  ⚠️ Warning: Package '$pkg' not found in $DOTFILES_DIR. Skipping."
    fi
  done

  # macOS VS Code symlink bridge
  if [ "$IS_MACOS" = true ]; then
    local MAC_VSCODE_DIR="$HOME/Library/Application Support/Code/User"
    mkdir -p "$MAC_VSCODE_DIR"
    if [ -f "$HOME/.config/Code/User/settings.json" ]; then
      ln -sf "$HOME/.config/Code/User/settings.json" "$MAC_VSCODE_DIR/settings.json"
    fi
    if [ -f "$HOME/.config/Code/User/keybindings.json" ]; then
      ln -sf "$HOME/.config/Code/User/keybindings.json" "$MAC_VSCODE_DIR/keybindings.json"
    fi
  fi
}

# --- Initialize Neovim & Tmux Plugins ---
setup_plugins() {
  # Initialize Neovim 0.12 native vim.pack plugins
  if command -v nvim &>/dev/null && [ -d "$DOTFILES_DIR/nvim" ]; then
    echo "=================================================="
    echo "⚡ Initializing Neovim plugins via vim.pack..."
    nvim --headless -c "lua vim.pack.update()" -c "qa" 2>/dev/null || true
  fi

  # Initialize Tmux TPM plugins
  if command -v tmux &>/dev/null && [ -d "$DOTFILES_DIR/tmux" ]; then
    echo "=================================================="
    echo "⚡ Initializing Tmux TPM plugins..."
    if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
      git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm" 2>/dev/null || true
    fi
    if [ ! -d "$HOME/.config/tmux/plugins/catppuccin/tmux" ]; then
      mkdir -p "$HOME/.config/tmux/plugins/catppuccin"
      git clone -b v2.1.3 https://github.com/catppuccin/tmux.git "$HOME/.config/tmux/plugins/catppuccin/tmux" 2>/dev/null || true
    fi
    TMUX_PLUGIN_MANAGER_PATH="$HOME/.tmux/plugins/" TERM=xterm-256color "$HOME/.tmux/plugins/tpm/bin/install_plugins" 2>/dev/null || true
  fi

  # Install VS Code extensions
  if command -v code &>/dev/null && [ -f "$DOTFILES_DIR/vscode/extensions.list" ]; then
    echo "=================================================="
    echo "💻 Installing VS Code extensions..."
    grep -v '^\s*#' "$DOTFILES_DIR/vscode/extensions.list" | while read -r ext; do
      if [ -n "$ext" ]; then
        code --install-extension "$ext" --force 2>/dev/null || true
      fi
    done
  fi
}

main() {
  detect_os
  install_dependencies
  prepare_stow_dirs
  stow_packages "$@"
  setup_plugins

  echo "=================================================="
  echo "🎉 dotfiles-core setup complete!"
}

main "$@"

