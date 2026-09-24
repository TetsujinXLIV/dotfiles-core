#!/usr/bin/env bash
# ==============================================================================
# dotfiles-core: Declarative Bootstrap & Sync Script
# Optimized for Work macOS Laptops and Work Debian/Ubuntu Machines.
# Designed for repeated, safe, idempotent execution.
# ==============================================================================

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IS_MACOS=false
IS_DEBIAN=false
DISTRO="unknown"
IS_UPGRADE=false
PRUNE_EXTENSIONS=false
WITH_BLESH=false
HEADLESS=false
POSITIONAL_ARGS=()

# --- Sudo Helper for Automation / Non-interactive Runs ---
run_sudo() {
  if [ -n "${SUDO_PASSWORD-}" ]; then
    echo "$SUDO_PASSWORD" | sudo -S -p "" "$@"
  else
    sudo "$@"
  fi
}

init_sudo() {
  if [ -n "${SUDO_PASSWORD-}" ]; then
    echo "$SUDO_PASSWORD" | sudo -S -v 2>/dev/null || true
  fi
}

# --- Detect OS ---
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    IS_MACOS=true
    DISTRO="macos"
  elif [[ -f /etc/debian_version ]] || grep -qi "debian\|ubuntu\|raspbian" /etc/os-release 2>/dev/null; then
    IS_DEBIAN=true
    if grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
      DISTRO="ubuntu"
    else
      DISTRO="debian"
    fi
  else
    DISTRO="$(uname -s | tr '[:upper:]' '[:lower:]')"
  fi
  echo "Detected OS: $DISTRO"
}

# --- Ensure Homebrew on macOS ---
ensure_homebrew() {
  if [ "$IS_MACOS" = true ]; then
    echo "=================================================="
    echo "🍺 Checking Homebrew environment..."
    export HOMEBREW_NO_ANALYTICS=1

    if [ -x "/opt/homebrew/bin/brew" ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x "/usr/local/bin/brew" ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi

    if ! command -v brew &>/dev/null; then
      echo "Homebrew not found. Installing Homebrew now..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      if [ -x "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [ -x "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    fi

    if command -v brew &>/dev/null; then
      brew analytics off 2>/dev/null || true
    fi
  fi
}

# --- System Package Upgrades (-u / --upgrade) ---
update_system_packages() {
  echo "=================================================="
  echo "🔄 Upgrading system packages..."
  if [ "$IS_MACOS" = true ]; then
    brew update && brew upgrade || true
  elif [ "$IS_DEBIAN" = true ]; then
    run_sudo apt-get update
    run_sudo apt-get upgrade -y
    run_sudo apt-get autoremove -y
  fi
}

# --- Install Base CLI Packages ---
install_base_packages() {
  echo "=================================================="
  echo "📦 Checking and installing base CLI packages..."

  if [ "$IS_MACOS" = true ]; then
    brew install git curl stow tmux ripgrep fzf bash
  elif [ "$IS_DEBIAN" = true ]; then
    run_sudo apt-get update
    run_sudo apt-get install -y git curl stow tmux ripgrep fzf build-essential xclip wl-clipboard
  fi
}

# --- Neovim 0.12 Bootstrap ---
ensure_root_nvim() {
  local REAL_NVIM=""
  if [ -x "/opt/nvim/bin/nvim" ]; then
    REAL_NVIM="/opt/nvim/bin/nvim"
  elif [ -x "/opt/homebrew/bin/nvim" ]; then
    REAL_NVIM="/opt/homebrew/bin/nvim"
  elif command -v nvim &>/dev/null; then
    REAL_NVIM="$(command -v nvim)"
  fi

  if [ -n "$REAL_NVIM" ]; then
    if [ "$REAL_NVIM" != "/usr/bin/nvim" ] && [ "$REAL_NVIM" != "/usr/local/bin/nvim" ]; then
      if [ "$IS_MACOS" = true ]; then
        if [ -w "/usr/local/bin" ]; then
          ln -sf "$REAL_NVIM" /usr/local/bin/nvim
        else
          run_sudo mkdir -p /usr/local/bin 2>/dev/null || true
          run_sudo ln -sf "$REAL_NVIM" /usr/local/bin/nvim 2>/dev/null || true
        fi
      else
        run_sudo mkdir -p /usr/local/bin
        run_sudo ln -sf "$REAL_NVIM" /usr/local/bin/nvim
      fi
    fi
  fi
}

install_neovim() {
  echo "=================================================="
  echo "⚡ Checking Neovim installation..."

  if [ "$IS_MACOS" = true ]; then
    if ! command -v nvim &>/dev/null; then
      brew install neovim
    elif [ "$IS_UPGRADE" = true ]; then
      brew upgrade neovim 2>/dev/null || true
    fi
    ensure_root_nvim
    return 0
  fi

  # Debian/Ubuntu: Download modern pre-built Neovim release (apt has ancient <0.8)
  local LOCAL_VERSION=""
  local REMOTE_VERSION=""

  if command -v nvim &>/dev/null; then
    LOCAL_VERSION=$(nvim --version 2>/dev/null | head -n 1 | awk '{print $2}' | sed 's/^v//')
    if [ "$IS_UPGRADE" != true ]; then
      echo "Neovim is already installed (v$LOCAL_VERSION). Skipping download..."
      ensure_root_nvim
      return 0
    fi
    REMOTE_VERSION=$(curl -s --connect-timeout 5 "https://api.github.com/repos/neovim/neovim/releases/latest" 2>/dev/null | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4 | sed 's/^v//') || true
    if [ -n "$LOCAL_VERSION" ] && [ -n "$REMOTE_VERSION" ] && [ "$LOCAL_VERSION" == "$REMOTE_VERSION" ]; then
      echo "Neovim is up-to-date (v$LOCAL_VERSION). Skipping download..."
      ensure_root_nvim
      return 0
    fi
  fi

  echo "Downloading modern pre-built Neovim release..."
  local ARCH
  ARCH="$(uname -m)"
  local TARBALL_SUFFIX=""

  if [ "$ARCH" == "x86_64" ]; then
    TARBALL_SUFFIX="-x86_64"
  elif [ "$ARCH" == "aarch64" ]; then
    TARBALL_SUFFIX="-arm64"
  else
    echo "Architecture $ARCH not directly supported for pre-built Neovim. Falling back to apt..."
    if [ "$IS_DEBIAN" = true ]; then run_sudo apt-get install -y neovim; fi
    ensure_root_nvim
    return 0
  fi

  local TARBALL_NAME="nvim-linux${TARBALL_SUFFIX}.tar.gz"
  local LATEST_URL
  LATEST_URL=$(curl -s --connect-timeout 5 "https://api.github.com/repos/neovim/neovim/releases/latest" 2>/dev/null | grep 'browser_download_url' | cut -d '"' -f 4 | grep "${TARBALL_NAME}" | head -n 1) || true

  if [ -n "$LATEST_URL" ]; then
    curl -fsSL -o "/tmp/${TARBALL_NAME}" "$LATEST_URL"
    local TEMP_EXTRACT_DIR
    TEMP_EXTRACT_DIR="$(mktemp -d)"
    tar -xzf "/tmp/${TARBALL_NAME}" -C "$TEMP_EXTRACT_DIR"
    local EXTRACTED_DIR
    EXTRACTED_DIR="$(find "$TEMP_EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

    if [ -n "$EXTRACTED_DIR" ] && [ -d "$EXTRACTED_DIR" ]; then
      run_sudo rm -rf /opt/nvim
      run_sudo mv "$EXTRACTED_DIR" /opt/nvim
      echo "✅ Neovim installed to /opt/nvim"
    else
      echo "⚠️ Could not locate extracted Neovim directory in $TEMP_EXTRACT_DIR"
    fi
    rm -rf "$TEMP_EXTRACT_DIR" "/tmp/${TARBALL_NAME}"
  else
    echo "⚠️ Could not download Neovim pre-built binary. Falling back to apt."
    if [ "$IS_DEBIAN" = true ]; then run_sudo apt-get install -y neovim; fi
  fi

  ensure_root_nvim
}

sync_neovim_plugins() {
  if command -v nvim &>/dev/null && [ -d "$DOTFILES_DIR/nvim" ]; then
    echo "=================================================="
    if [ "$IS_UPGRADE" = true ]; then
      echo "⚡ Updating Neovim plugins to latest releases..."
      nvim --headless -c "lua vim.pack.update()" -c "qa" 2>/dev/null || true
    else
      echo "⚡ Syncing Neovim plugins with lockfile..."
      nvim --headless -c "lua vim.pack.update(nil, { target = 'lockfile' })" -c "qa" 2>/dev/null || true
    fi
  fi
}

# --- Fira Code Nerd Font ---
install_firacode_nerd_font() {
  echo "=================================================="
  echo "🔤 Checking Fira Code Nerd Font..."
  if [ "$IS_MACOS" = true ]; then
    brew install --cask font-fira-code-nerd-font 2>/dev/null || brew install font-fira-code-nerd-font 2>/dev/null || true
    return 0
  fi

  if command -v fc-list &>/dev/null && fc-list | grep -qi "FiraCode"; then
    echo "Fira Code Nerd Font is already installed. Skipping..."
    return 0
  fi

  local FONT_URL
  FONT_URL=$(curl -s --connect-timeout 5 "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest" 2>/dev/null | grep 'browser_download_url' | cut -d '"' -f 4 | grep 'FiraCode.zip' | head -n 1) || true

  if [ -n "$FONT_URL" ]; then
    echo "Downloading and installing Fira Code Nerd Font..."
    curl -fsSL -o /tmp/FiraCode.zip "$FONT_URL"
    mkdir -p /tmp/FiraCode
    unzip -qo /tmp/FiraCode.zip -d /tmp/FiraCode
    mkdir -p "$HOME/.local/share/fonts"
    cp /tmp/FiraCode/*.ttf "$HOME/.local/share/fonts/" 2>/dev/null || true
    rm -rf /tmp/FiraCode /tmp/FiraCode.zip
    if command -v fc-cache &>/dev/null; then
      fc-cache -f "$HOME/.local/share/fonts" 2>/dev/null || true
    fi
    echo "✅ Fira Code Nerd Font installed successfully."
  fi
}

# --- Ghostty Terminal ---
install_ghostty() {
  echo "=================================================="
  echo "👻 Checking Ghostty..."

  if [ "$IS_MACOS" = true ]; then
    if [ ! -d "/Applications/Ghostty.app" ] && ! command -v ghostty &>/dev/null; then
      echo "Installing Ghostty via Homebrew Cask..."
      brew install --cask ghostty || true
    else
      echo "Ghostty is already installed."
    fi

    # macOS Ghostty shell override (prefer Homebrew modern Bash if installed)
    local MAC_GHOSTTY_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty"
    mkdir -p "$MAC_GHOSTTY_DIR"
    if [ -x "/opt/homebrew/bin/bash" ] && [ ! -f "$MAC_GHOSTTY_DIR/config" ]; then
      cat << 'EOF' > "$MAC_GHOSTTY_DIR/config"
# macOS Ghostty shell override
command = /opt/homebrew/bin/bash --login
EOF
      echo "✅ Configured Ghostty macOS default shell to Homebrew Bash"
    fi
  elif [ "$IS_DEBIAN" = true ]; then
    if command -v ghostty &>/dev/null; then
      echo "Ghostty is already installed. Skipping..."
    else
      if command -v flatpak &>/dev/null; then
        flatpak install -y flathub com.mitchellh.ghostty 2>/dev/null || true
      else
        local ARCH
        ARCH="$(uname -m)"
        local GHOSTTY_DEB=""
        if [ "$ARCH" == "x86_64" ]; then
          GHOSTTY_DEB="https://github.com/ghostty-org/ghostty/releases/latest/download/ghostty_linux_amd64.deb"
        elif [ "$ARCH" == "aarch64" ]; then
          GHOSTTY_DEB="https://github.com/ghostty-org/ghostty/releases/latest/download/ghostty_linux_arm64.deb"
        fi
        if [ -n "$GHOSTTY_DEB" ]; then
          curl -fsSL -o /tmp/ghostty.deb "$GHOSTTY_DEB" 2>/dev/null && \
            run_sudo apt-get install -y /tmp/ghostty.deb 2>/dev/null && \
            rm -f /tmp/ghostty.deb || true
        fi
      fi
    fi
  fi

  install_firacode_nerd_font
}

# --- Visual Studio Code & Extensions ---
reconcile_vscode_extensions() {
  local VSCODE_CMD="code"
  if ! command -v code &>/dev/null; then
    if [ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]; then
      VSCODE_CMD="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    elif command -v flatpak &>/dev/null && flatpak list --app 2>/dev/null | grep -q "com.visualstudio.code"; then
      VSCODE_CMD="flatpak run com.visualstudio.code"
    else
      return 0
    fi
  fi

  if [ -f "$DOTFILES_DIR/vscode/extensions.list" ]; then
    echo "Reconciling VS Code extensions using: $VSCODE_CMD"

    local DESIRED_FILE
    DESIRED_FILE=$(mktemp)
    grep -v '^\s*#' "$DOTFILES_DIR/vscode/extensions.list" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | tr '[:upper:]' '[:lower:]' > "$DESIRED_FILE"

    local INSTALLED_FILE
    INSTALLED_FILE=$(mktemp)
    $VSCODE_CMD --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' > "$INSTALLED_FILE" || true

    # 1. Install missing extensions
    while IFS= read -r extension; do
      if [ -n "$extension" ] && ! grep -qxF "$extension" "$INSTALLED_FILE"; then
        echo "  ➕ Installing missing extension: $extension..."
        $VSCODE_CMD --install-extension "$extension" --force 2>/dev/null || true
      fi
    done < "$DESIRED_FILE"

    # 2. Prune unlisted extensions (opt-in only via --prune-extensions)
    if [ "$PRUNE_EXTENSIONS" = true ]; then
      echo "  🧹 Pruning unlisted extensions (--prune-extensions enabled)..."
      while IFS= read -r installed_ext; do
        if [ -n "$installed_ext" ] && [ "$installed_ext" != "ms-vscode-remote.remote-ssh-edit" ]; then
          if ! grep -qxF "$installed_ext" "$DESIRED_FILE"; then
            echo "  🗑️  Uninstalling unlisted extension: $installed_ext..."
            $VSCODE_CMD --uninstall-extension "$installed_ext" 2>/dev/null || true
          fi
        fi
      done < "$INSTALLED_FILE"
    fi

    rm -f "$DESIRED_FILE" "$INSTALLED_FILE"
  fi
}

install_vscode() {
  echo "=================================================="
  echo "💻 Checking Visual Studio Code..."

  if [ "$IS_MACOS" = true ]; then
    if [ ! -d "/Applications/Visual Studio Code.app" ] && ! command -v code &>/dev/null; then
      echo "Installing Visual Studio Code via Homebrew Cask..."
      brew install --cask visual-studio-code || true
    else
      echo "Visual Studio Code is already installed."
    fi

    # macOS VS Code symlink bridge
    local MAC_VSCODE_DIR="$HOME/Library/Application Support/Code/User"
    local STD_VSCODE_DIR="$HOME/.config/Code/User"
    mkdir -p "$MAC_VSCODE_DIR"
    if [ -f "$STD_VSCODE_DIR/settings.json" ]; then
      ln -sf "$STD_VSCODE_DIR/settings.json" "$MAC_VSCODE_DIR/settings.json"
    fi
    if [ -f "$STD_VSCODE_DIR/keybindings.json" ]; then
      ln -sf "$STD_VSCODE_DIR/keybindings.json" "$MAC_VSCODE_DIR/keybindings.json"
    fi
    if [ -d "$STD_VSCODE_DIR/snippets" ]; then
      ln -sfn "$STD_VSCODE_DIR/snippets" "$MAC_VSCODE_DIR/snippets"
    fi
    echo "✅ VS Code macOS symlink bridge active."
  elif [ "$IS_DEBIAN" = true ]; then
    if ! command -v code &>/dev/null; then
      echo "Checking existing apt repositories for code..."
      run_sudo apt-get update
      if run_sudo apt-get install -y code 2>/dev/null; then
        echo "✅ Installed Visual Studio Code from existing repository."
      else
        echo "Visual Studio Code not found in existing repositories. Configuring Microsoft apt repository..."
        run_sudo apt-get install -y wget gpg apt-transport-https
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/packages.microsoft.gpg
        run_sudo install -D -o root -g root -m 644 /tmp/packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
        run_sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
        rm -f /tmp/packages.microsoft.gpg
        run_sudo apt-get update
        run_sudo apt-get install -y code
      fi
    else
      echo "Visual Studio Code is already installed."
    fi
  fi

  reconcile_vscode_extensions
}

# --- Tmux & TPM ---
install_tmux_plugins() {
  echo "=================================================="
  echo "🔌 Checking Tmux plugins (TPM & Catppuccin)..."

  if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    echo "Cloning Tmux Plugin Manager (TPM)..."
    git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm" 2>/dev/null || true
  fi

  if [ ! -d "$HOME/.config/tmux/plugins/catppuccin/tmux" ]; then
    echo "Cloning Catppuccin Tmux theme (v2.1.3)..."
    mkdir -p "$HOME/.config/tmux/plugins/catppuccin"
    git clone -b v2.1.3 https://github.com/catppuccin/tmux.git "$HOME/.config/tmux/plugins/catppuccin/tmux" 2>/dev/null || true
  fi

  if [ -x "$HOME/.tmux/plugins/tpm/bin/install_plugins" ]; then
    echo "Installing TPM plugins..."
    TMUX_PLUGIN_MANAGER_PATH="$HOME/.tmux/plugins/" TERM=xterm-256color "$HOME/.tmux/plugins/tpm/bin/install_plugins" 2>/dev/null || true
  fi

  if [ "$IS_UPGRADE" = true ] && [ -x "$HOME/.tmux/plugins/tpm/bin/update_plugins" ]; then
    echo "Updating TPM plugins..."
    TMUX_PLUGIN_MANAGER_PATH="$HOME/.tmux/plugins/" TERM=xterm-256color "$HOME/.tmux/plugins/tpm/bin/update_plugins" all 2>/dev/null || true
  fi

  # Safely reload tmux if currently running without terminating active sessions
  if command -v tmux &>/dev/null && tmux info &>/dev/null; then
    tmux source-file "$HOME/.tmux.conf" 2>/dev/null || true
  fi
}

# --- ble.sh (Bash Line Editor) ---
install_blesh() {
  echo "=================================================="
  echo "🔍 Checking ble.sh (Bash Line Editor)..."

  local BLESH_DIR="$HOME/.local/share/blesh"
  if [ -f "$BLESH_DIR/ble.sh" ] && [ "$IS_UPGRADE" != true ]; then
    echo "ble.sh is already installed in $BLESH_DIR. Skipping..."
    return 0
  fi

  mkdir -p "$BLESH_DIR"
  local LATEST_TARBALL="https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz"
  echo "Downloading pre-built ble.sh release..."
  if curl -fsSL "$LATEST_TARBALL" | tar -xJf - -C "$BLESH_DIR" --strip-components=1 2>/dev/null; then
    echo "✅ ble.sh installed successfully in $BLESH_DIR"
  else
    echo "⚠️ Failed to download nightly release. Trying stable fallback..."
    curl -fsSL "https://github.com/akinomyoga/ble.sh/releases/download/v0.4.0-devel3/ble-0.4.0-devel3.tar.xz" | tar -xJf - -C "$BLESH_DIR" --strip-components=1 2>/dev/null || true
  fi
}

# --- GNU Stow Preparation & Execution ---
prepare_stow_dirs() {
  echo "=================================================="
  echo "📁 Preparing directory structures..."
  mkdir -p "$HOME/.config/ghostty"
  mkdir -p "$HOME/.config/nvim"
  mkdir -p "$HOME/.config/tmux"
  mkdir -p "$HOME/.config/Code/User"
  mkdir -p "$HOME/.terminfo"
  mkdir -p "$HOME/.local/bin"
  mkdir -p "$HOME/.local/share"
}

stow_packages() {
  echo "=================================================="
  echo "🔗 Linking configurations with GNU Stow..."
  cd "$DOTFILES_DIR"

  local PACKAGES=()
  if [ "$#" -gt 0 ]; then
    PACKAGES=("$@")
  else
    PACKAGES=("ghostty" "nvim" "tmux" "vscode")
    if [ -d "$DOTFILES_DIR/blesh" ]; then
      PACKAGES+=("blesh")
    fi
  fi

  for pkg in "${PACKAGES[@]}"; do
    if [ -d "$DOTFILES_DIR/$pkg" ]; then
      echo "  Stowing: $pkg"
      stow --dir="$DOTFILES_DIR" --target="$HOME" -R -v "$pkg" 2>/dev/null || \
        stow --dir="$DOTFILES_DIR" --target="$HOME" --adopt -R -v "$pkg" 2>/dev/null || true
    else
      echo "  ⚠️ Warning: Package '$pkg' not found in $DOTFILES_DIR. Skipping."
    fi
  done

  # Check if stow adopt modified any tracked files in the repo
  if [ -d "$DOTFILES_DIR/.git" ] && command -v git &>/dev/null; then
    local MODIFIED_TRACKED
    MODIFIED_TRACKED=$(git -C "$DOTFILES_DIR" status --porcelain 2>/dev/null | grep -E '^[ M]M|^ M|^M ' || true)
    if [ -n "$MODIFIED_TRACKED" ]; then
      echo "=================================================="
      echo "⚠️  WARNING: stow adopt modified tracked files in the repository with pre-existing local files:"
      git -C "$DOTFILES_DIR" status --short
      echo ""
      echo "💡 Run 'git -C \"$DOTFILES_DIR\" diff' to inspect changes."
      echo "💡 If you wish to discard local adoptions and restore repository defaults:"
      echo "   git -C \"$DOTFILES_DIR\" checkout -- ."
      echo "=================================================="
    fi
  fi
}

# --- Shell Startup Integration ---
update_shell() {
  echo "=================================================="
  echo "🐚 Ensuring shell startup configuration..."

  local BASHRC="$HOME/.bashrc"
  mkdir -p "$HOME"
  touch "$BASHRC"

  # Ensure ~/.local/bin in PATH
  local PATH_LINE='[[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"'
  if ! grep -q "HOME/.local/bin" "$BASHRC" 2>/dev/null; then
    echo -e "\n# User local bin in PATH\n$PATH_LINE" >> "$BASHRC"
    echo "Added ~/.local/bin to PATH in ~/.bashrc"
  fi

  # ble.sh loader in ~/.bashrc (only for interactive shells, if ble.sh is present)
  if [ -f "$HOME/.local/share/blesh/ble.sh" ]; then
    local BLESH_LOADER='[[ $- == *i* ]] && [ -f "$HOME/.local/share/blesh/ble.sh" ] && source "$HOME/.local/share/blesh/ble.sh"'
    # Fix legacy --noattach loader if previously added
    if grep -q "blesh/ble.sh.*--noattach" "$BASHRC" 2>/dev/null; then
      sed -i.bak 's|blesh/ble.sh" --noattach|blesh/ble.sh"|' "$BASHRC" 2>/dev/null && rm -f "$BASHRC.bak" || true
      echo "Updated ble.sh loader in ~/.bashrc (removed --noattach)"
    elif ! grep -q "blesh/ble.sh" "$BASHRC" 2>/dev/null; then
      echo -e "\n# ble.sh initialization\n$BLESH_LOADER" >> "$BASHRC"
      echo "Added ble.sh loader to ~/.bashrc"
    fi
  fi

  # macOS login shell setup
  if [ "$IS_MACOS" = true ]; then
    local NO_ANALYTICS='export HOMEBREW_NO_ANALYTICS=1'
    if ! grep -q "HOMEBREW_NO_ANALYTICS" "$BASHRC" 2>/dev/null; then
      echo -e "\n# Disable Homebrew analytics\n$NO_ANALYTICS" >> "$BASHRC"
    fi

    local BASH_PROFILE="$HOME/.bash_profile"
    local PROFILE_SOURCE='[[ -f ~/.bashrc ]] && . ~/.bashrc'
    if [ ! -f "$BASH_PROFILE" ] || ! grep -qF "$PROFILE_SOURCE" "$BASH_PROFILE" 2>/dev/null; then
      echo -e "\n# Source .bashrc for login shells\n$PROFILE_SOURCE" >> "$BASH_PROFILE"
      echo "Added .bashrc loader to ~/.bash_profile"
    fi

    # Register Homebrew modern Bash 5 in /etc/shells so chsh permits it
    local BREW_BASH="/opt/homebrew/bin/bash"
    if [ -x "$BREW_BASH" ]; then
      if ! grep -qxF "$BREW_BASH" /etc/shells 2>/dev/null; then
        echo "Adding $BREW_BASH to /etc/shells..."
        echo "$BREW_BASH" | run_sudo tee -a /etc/shells >/dev/null 2>&1 || true
      fi
    fi
  fi
}

# --- CLI Arguments & Help ---
show_help() {
  cat << EOF
dotfiles-core: Declarative Bootstrap & Sync Script

Usage: ./sync_core.sh [options] [package1 package2 ...]

Options:
  -u, --upgrade         Upgrade system packages, Neovim, and plugins
  --headless            Skip desktop GUI applications (Ghostty and VS Code) for servers
  --prune-extensions    Uninstall VS Code extensions not listed in extensions.list
  --with-blesh          Install ble.sh (Bash Line Editor) for enhanced history search
  -h, --help            Show this help message

Arguments:
  [package ...]         Optional list of specific packages to stow (e.g. nvim tmux).
                        Defaults to all packages: ghostty, nvim, tmux, vscode.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--upgrade)
        IS_UPGRADE=true
        shift
        ;;
      --headless|--no-gui|--skip-gui)
        HEADLESS=true
        shift
        ;;
      --prune-extensions)
        PRUNE_EXTENSIONS=true
        shift
        ;;
      --with-blesh)
        WITH_BLESH=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      -*)
        echo "Unknown option: $1" >&2
        show_help
        exit 1
        ;;
      *)
        POSITIONAL_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  init_sudo
  detect_os
  ensure_homebrew

  if [ "$IS_UPGRADE" = true ]; then
    update_system_packages
  fi

  install_base_packages
  install_neovim
  prepare_stow_dirs
  stow_packages "${POSITIONAL_ARGS[@]}"
  sync_neovim_plugins
  install_tmux_plugins

  if [ "$WITH_BLESH" = true ] || [ -d "$DOTFILES_DIR/blesh" ]; then
    install_blesh
  fi

  if [ "$HEADLESS" = true ]; then
    echo "=================================================="
    echo "🖥️  Headless mode active (--headless). Skipping desktop GUI applications (Ghostty & VS Code)."
  else
    echo "=================================================="
    echo "🖥️  Desktop session. Setting up applications..."
    install_ghostty
    install_vscode
  fi

  update_shell

  echo "=================================================="
  echo "🎉 dotfiles-core setup complete!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
