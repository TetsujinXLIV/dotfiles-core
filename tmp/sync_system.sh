#!/bin/bash

# Exit on error
set -e

# 1. GET SCRIPT LOCATION (Crucial for Stow)
# This ensures the script works even if you call it from a different folder
DOTFILES_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Non-interactive Sudo Pre-Authentication & Helper (for Ansible/automation)
run_sudo() {
  if [ -n "${SUDO_PASSWORD-}" ]; then
    echo "$SUDO_PASSWORD" | sudo -S -p "" "$@"
  else
    sudo "$@"
  fi
}

if [ -n "${SUDO_PASSWORD-}" ]; then
  echo "$SUDO_PASSWORD" | sudo -S -v 2>/dev/null || true
fi

# --- Detect OS ---
detect_os() {
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "macos"
  elif grep -qi "bazzite" /etc/os-release 2>/dev/null; then
    echo "bazzite"
  elif [ -f /etc/cachyos-release ] || [ -f /etc/arch-release ] || grep -qi "arch" /etc/os-release 2>/dev/null; then
    echo "arch"
  elif [ -f /etc/fedora-release ] || grep -qi "fedora" /etc/os-release 2>/dev/null; then
    echo "fedora"
  elif [ -f /etc/rocky-release ] || grep -qi "rocky" /etc/os-release 2>/dev/null; then
    echo "rocky"
  elif [ -f /etc/debian_version ] || grep -qi "debian\|ubuntu\|raspbian" /etc/os-release 2>/dev/null; then
    echo "debian"
  else
    echo "unsupported"
  fi
}

# --- Check SSH Session ---
is_ssh_session() {
  if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    return 0
  else
    return 1
  fi
}

OS=$(detect_os)

if [ "$OS" == "unsupported" ]; then
  echo "Unsupported operating system."
  exit 1
fi
echo "Detected operating system: $OS"

# --- Ensure Homebrew (macOS / Apple Silicon / Linuxbrew) ---
ensure_homebrew() {
  if [ "$OS" == "macos" ]; then
    if [ -x "/opt/homebrew/bin/brew" ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x "/usr/local/bin/brew" ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi

    if ! command -v brew &> /dev/null; then
      echo "=================================================="
      echo "Homebrew is required on macOS but was not found in PATH."
      echo "Installing Homebrew now..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      if [ -x "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [ -x "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    fi
  fi
}

IS_UPGRADE=false

# --- System Package Upgrade (when --upgrade flag is passed) ---
update_system_packages() {
  echo "=================================================="
  echo "Upgrading system packages..."
  if [ "$OS" == "macos" ]; then
    echo "Upgrading Homebrew packages and casks..."
    brew update && brew upgrade || true
  elif [ "$OS" == "bazzite" ]; then
    echo "Upgrading Bazzite / Homebrew / Flatpaks..."
    if command -v rpm-ostree &>/dev/null; then rpm-ostree upgrade || true; fi
    if command -v brew &>/dev/null; then brew update && brew upgrade || true; fi
    if command -v flatpak &>/dev/null; then flatpak update -y || true; fi
  elif [ "$OS" == "arch" ]; then
    if command -v paru &>/dev/null; then paru -Syu --noconfirm; else run_sudo pacman -Syu --noconfirm; fi
  elif [ "$OS" == "fedora" ] || [ "$OS" == "rocky" ]; then
    run_sudo dnf upgrade -y
  elif [ "$OS" == "debian" ]; then
    run_sudo apt-get update && run_sudo apt-get upgrade -y
    run_sudo apt-get autoremove -y
  fi
}

# --- Install Packages ---
install_packages() {
  echo "=================================================="
  echo "Installing base packages..."

  if [ "$OS" == "macos" ]; then
    echo "macOS detected. Installing base packages via Homebrew..."
    brew install curl ripgrep stow tmux gcc zip 7zip tree nano gettext fzf xz bash uv
    brew install 1password-cli 2>/dev/null || brew install --cask 1password-cli 2>/dev/null || true
  elif [ "$OS" == "bazzite" ]; then
    echo "Bazzite detected. Using Homebrew..."
    if ! command -v brew &> /dev/null; then
      echo "Homebrew not found! Run 'sudo systemctl start brew-setup' first."
      exit 1
    fi
    brew install curl ripgrep stow tmux gcc zip unar 7zip tree nano gettext fzf xz
  elif [ "$OS" == "arch" ]; then
    run_sudo pacman -S --needed --noconfirm base-devel git curl ripgrep stow tmux xsel xclip wl-clipboard rsync zip unrar 7zip tree nano gettext fzf xz
  elif [ "$OS" == "fedora" ] || [ "$OS" == "rocky" ]; then
    run_sudo dnf install -y curl ripgrep stow tmux xsel xclip wl-clipboard make gcc rsync zip unrar 7zip tree nano gettext fzf xz
  elif [ "$OS" == "debian" ]; then
    echo "Enabling repository for proprietary unrar..."
    set +e
    if grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
      if command -v add-apt-repository &> /dev/null; then
        run_sudo add-apt-repository multiverse -y 2>/dev/null || true
      elif [ -f /etc/apt/sources.list ]; then
        run_sudo sed -i '/^deb / s/main\|universe/& multiverse/' /etc/apt/sources.list 2>/dev/null || true
      fi
    else
      if [ -f /etc/apt/sources.list ] && ! grep -q "non-free" /etc/apt/sources.list; then
        source /etc/os-release 2>/dev/null || true
        DEB_CODENAME=${VERSION_CODENAME:-trixie}
        run_sudo tee /etc/apt/sources.list.d/debian-non-free.list > /dev/null <<EOF
deb http://deb.debian.org/debian/ $DEB_CODENAME non-free
deb http://security.debian.org/debian-security $DEB_CODENAME-security non-free
deb http://deb.debian.org/debian/ $DEB_CODENAME-updates non-free
EOF
      fi
    fi
    set -e

    run_sudo apt-get update
    run_sudo apt-get install -y curl ripgrep stow tmux xsel xclip wl-clipboard build-essential rsync zip 7zip pkg-config libicu-dev tree nano gettext-base fzf xz-utils
    run_sudo apt-get install -y unrar 2>/dev/null || run_sudo apt-get install -y unrar-free 2>/dev/null || true
  fi
}

install_blesh() {
  echo "=================================================="
  echo "Installing / Updating ble.sh (Bash Line Editor)..."
  local BLESH_DIR="$HOME/.local/share/blesh"
  if [ -f "$BLESH_DIR/ble.sh" ] && [ "$IS_UPGRADE" != true ]; then
    echo "ble.sh is already installed. Skipping..."
    return 0
  fi

  mkdir -p "$BLESH_DIR"
  local LATEST_TARBALL="https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz"
  echo "Downloading pre-built ble.sh release..."
  if curl -fsSL "$LATEST_TARBALL" | tar -xJf - -C "$BLESH_DIR" --strip-components=1; then
    echo "✅ ble.sh installed successfully in $BLESH_DIR"
  else
    echo "⚠️ Failed to download/extract ble.sh from nightly. Trying stable release fallback..."
    curl -fsSL "https://github.com/akinomyoga/ble.sh/releases/download/v0.4.0-devel3/ble-0.4.0-devel3.tar.xz" | tar -xJf - -C "$BLESH_DIR" --strip-components=1 || true
  fi
}

install_starship() {
  echo "=================================================="
  echo "Installing Starship..."
  if command -v starship &> /dev/null; then
    echo "Starship is already installed. Skipping..."
    return 0
  fi
  if [ "$OS" == "bazzite" ] || [ "$OS" == "macos" ]; then
    brew install starship
  elif [ "$OS" == "arch" ]; then
    run_sudo pacman -S --needed --noconfirm starship
  else
    if [ -n "${SUDO_PASSWORD-}" ]; then
      echo "$SUDO_PASSWORD" | sudo -S -p "" sh -c 'curl -sS https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin'
    else
      curl -sS https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin 2>/dev/null || curl -sS https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"
    fi
  fi
}

install_fastfetch() {
  echo "=================================================="
  echo "Installing Fastfetch..."
  if [ "$OS" == "bazzite" ] || [ "$OS" == "macos" ]; then
    brew install fastfetch
    return 0
  elif [ "$OS" == "arch" ]; then
    sudo pacman -S --needed --noconfirm fastfetch
    return 0
  fi

  local LOCAL_VERSION=""
  local REMOTE_VERSION=""

  if command -v fastfetch &> /dev/null; then
    LOCAL_VERSION=$(fastfetch --version 2>/dev/null | awk '{print $2}' | sed 's/^v//')
    REMOTE_VERSION=$(curl -s --connect-timeout 5 "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4 | sed 's/^v//')
    if [ -n "$LOCAL_VERSION" ] && [ -n "$REMOTE_VERSION" ] && [ "$LOCAL_VERSION" == "$REMOTE_VERSION" ]; then
      echo "Fastfetch is already up-to-date ($LOCAL_VERSION). Skipping..."
      return 0
    fi
    if [ -n "$REMOTE_VERSION" ]; then
      echo "Updating Fastfetch from $LOCAL_VERSION to $REMOTE_VERSION..."
    fi
  fi

  ARCH=$(uname -m)
  local ARCH_NAME=""
  if [ "$ARCH" == "x86_64" ]; then
    ARCH_NAME="amd64"
  elif [ "$ARCH" == "aarch64" ]; then
    ARCH_NAME="aarch64"
  elif [ "$ARCH" == "armv7l" ]; then
    ARCH_NAME="armhf"
  else
    echo "Fastfetch unsupported architecture: $ARCH"
    return 0
  fi

  local LATEST_URL=""
  set +e
  if [ "$OS" == "fedora" ] || [ "$OS" == "rocky" ]; then
    LATEST_URL=$(curl -s --connect-timeout 5 "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" | grep 'browser_download_url' | cut -d '"' -f 4 | grep "linux-${ARCH_NAME}.rpm" | head -n 1)
    if [ -n "$LATEST_URL" ]; then
      curl -L -o fastfetch.rpm "$LATEST_URL" && run_sudo dnf install -y fastfetch.rpm && rm -f fastfetch.rpm
    fi
  elif [ "$OS" == "debian" ]; then
    LATEST_URL=$(curl -s --connect-timeout 5 "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" | grep 'browser_download_url' | cut -d '"' -f 4 | grep "linux-${ARCH_NAME}.deb" | head -n 1)
    if [ -n "$LATEST_URL" ]; then
      curl -L -o fastfetch.deb "$LATEST_URL" && run_sudo apt install -y ./fastfetch.deb && rm -f fastfetch.deb
    fi
  fi
  set -e
}

ensure_root_nvim() {
  echo "=================================================="
  echo "Ensuring nvim is accessible via sudo..."

  # 1. Detect the actual binary location
  local REAL_NVIM=""
  if [ -x "/opt/nvim/bin/nvim" ]; then
    REAL_NVIM="/opt/nvim/bin/nvim"
  elif [ -x "/opt/homebrew/bin/nvim" ]; then
    REAL_NVIM="/opt/homebrew/bin/nvim"
  elif [ -x "/home/linuxbrew/.linuxbrew/bin/nvim" ]; then
    REAL_NVIM="/home/linuxbrew/.linuxbrew/bin/nvim"
  elif [ -x "$HOME/.linuxbrew/bin/nvim" ]; then
    REAL_NVIM="$HOME/.linuxbrew/bin/nvim"
  elif command -v nvim &>/dev/null; then
    REAL_NVIM=$(command -v nvim)
  fi

  # 2. Symlink to /usr/local/bin/nvim (in sudo's secure_path)
  if [ -n "$REAL_NVIM" ]; then
    if [ "$REAL_NVIM" != "/usr/bin/nvim" ] && [ "$REAL_NVIM" != "/usr/local/bin/nvim" ]; then
      if [ "$OS" == "macos" ]; then
        if [ -w "/usr/local/bin" ]; then
          ln -sf "$REAL_NVIM" /usr/local/bin/nvim
          echo "✅ Symlinked $REAL_NVIM -> /usr/local/bin/nvim"
        else
          run_sudo mkdir -p /usr/local/bin 2>/dev/null || true
          run_sudo ln -sf "$REAL_NVIM" /usr/local/bin/nvim 2>/dev/null || true
          echo "✅ Ensured $REAL_NVIM -> /usr/local/bin/nvim"
        fi
      else
        run_sudo mkdir -p /usr/local/bin
        run_sudo ln -sf "$REAL_NVIM" /usr/local/bin/nvim
        echo "✅ Symlinked $REAL_NVIM -> /usr/local/bin/nvim"
      fi
    else
      echo "✅ Neovim is already in system PATH ($REAL_NVIM)."
    fi
  else
    echo "⚠️ Neovim binary not found. Skipping symlink."
  fi
}

install_neovim() {
  echo "=================================================="
  echo "Installing Neovim..."
  if [ "$OS" == "bazzite" ] || [ "$OS" == "macos" ]; then
    brew install neovim
    ensure_root_nvim
    return 0
  elif [ "$OS" == "arch" ]; then
    run_sudo pacman -S --needed --noconfirm neovim
    ensure_root_nvim
    return 0
  fi

  local LOCAL_VERSION=""
  local REMOTE_VERSION=""

  if command -v nvim &> /dev/null; then
    LOCAL_VERSION=$(nvim --version | head -n 1 | awk '{print $2}' | sed 's/^v//')
    REMOTE_VERSION=$(curl -s --connect-timeout 5 "https://api.github.com/repos/neovim/neovim/releases/latest" | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4 | sed 's/^v//')
    if [ -n "$LOCAL_VERSION" ] && [ -n "$REMOTE_VERSION" ] && [ "$LOCAL_VERSION" == "$REMOTE_VERSION" ]; then
      echo "Neovim is already up-to-date ($LOCAL_VERSION). Skipping download..."
      ensure_root_nvim
      return 0
    fi
    if [ -n "$REMOTE_VERSION" ]; then
      echo "Updating Neovim from $LOCAL_VERSION to $REMOTE_VERSION..."
    fi
  fi

  ARCH=$(uname -m)
  local TARBALL_SUFFIX=""
  local EXTRACTED_DIR=""
  if [ "$ARCH" == "x86_64" ]; then
    TARBALL_SUFFIX="-x86_64"
    EXTRACTED_DIR="nvim-linux-x86_64"
  elif [ "$ARCH" == "aarch64" ]; then
    TARBALL_SUFFIX="-arm64"
    EXTRACTED_DIR="nvim-linux-arm64"
  elif [ "$ARCH" == "armv7l" ]; then
    echo "Neovim pre-built binary not available for 32-bit ARM (armv7l). Falling back to package manager..."
    if [ "$OS" == "debian" ]; then run_sudo apt-get install -y neovim; fi
    ensure_root_nvim
    return 0
  else
    echo "Neovim does not have a pre-built binary for your architecture ($ARCH)."
    ensure_root_nvim
    return 0
  fi

  local tarball_name="nvim-linux${TARBALL_SUFFIX}.tar.gz"
  local LATEST_URL=""

  set +e
  LATEST_URL=$(curl -s --connect-timeout 5 "https://api.github.com/repos/neovim/neovim/releases/latest" | grep 'browser_download_url' | cut -d '"' -f 4 | grep "${tarball_name}" | head -n 1)
  set -e

  if [ -z "$LATEST_URL" ]; then
    echo "Could not find a Neovim release binary for your architecture."
    ensure_root_nvim
    return 0
  fi

  curl -L -o "${tarball_name}" "$LATEST_URL"
  tar xzvf "${tarball_name}"
  run_sudo rm -rf /opt/nvim
  run_sudo mv "${EXTRACTED_DIR}" /opt/nvim
  rm -f "${tarball_name}"

  ensure_root_nvim
}

sync_neovim_plugins() {
  echo "=================================================="
  if [ "$IS_UPGRADE" = true ]; then
    echo "Updating Neovim plugins to latest releases..."
    nvim --headless -c "lua vim.pack.update()" -c "qa" || true
  else
    echo "Syncing Neovim plugins with lockfile..."
    nvim --headless -c "lua vim.pack.update(nil, { target = 'lockfile' })" -c "qa" || true
  fi
}

install_firacode_nerd_font() {
  echo "=================================================="
  echo "Installing Fira Code Nerd Font..."
  if [ "$OS" == "bazzite" ] || [ "$OS" == "macos" ]; then
    brew install font-fira-code-nerd-font 2>/dev/null || brew install --cask font-fira-code-nerd-font 2>/dev/null || true
  elif [ "$OS" == "arch" ]; then
    run_sudo pacman -S --needed --noconfirm ttf-firacode-nerd
  else
    if fc-list 2>/dev/null | grep -qi "FiraCode"; then
      echo "Fira Code Nerd Font is already installed. Skipping..."
      return 0
    fi
    LATEST_URL=$(curl -s --connect-timeout 5 "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest" | grep 'browser_download_url' | cut -d '"' -f 4 | grep 'FiraCode.zip' | head -n 1)
    if [ -n "$LATEST_URL" ]; then
      curl -L -o FiraCode.zip "$LATEST_URL"
      unzip -o FiraCode.zip -d FiraCode
      mkdir -p ~/.local/share/fonts
      mv FiraCode/*.ttf ~/.local/share/fonts/
      rm -rf FiraCode FiraCode.zip
      fc-cache -f -v
    fi
  fi
}

install_wezterm() {
  echo "=================================================="
  echo "Installing Wezterm..."
  if [ "$OS" == "bazzite" ]; then
    flatpak install -y flathub org.wezfurlong.wezterm
  elif [ "$OS" == "arch" ]; then
    run_sudo pacman -S --needed --noconfirm wezterm
  elif [ "$OS" == "fedora" ] || [ "$OS" == "rocky" ]; then
    run_sudo dnf copr enable wezfurlong/wezterm-nightly -y
    run_sudo dnf install -y wezterm
  elif [ "$OS" == "debian" ]; then
    curl -fsSL https://apt.fury.io/wez/gpg.key | run_sudo gpg --yes --dearmor -o /usr/share/keyrings/wezterm-fury.gpg
    echo 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' | run_sudo tee /etc/apt/sources.list.d/wezterm.list
    run_sudo apt-get update && run_sudo apt-get install -y wezterm
  fi
  install_firacode_nerd_font
}

install_ghostty() {
  echo "=================================================="
  echo "Installing Ghostty..."
  if [ "$OS" == "macos" ]; then
    if [ -d "/Applications/Ghostty.app" ] || command -v ghostty &>/dev/null; then
      echo "Ghostty is already installed."
    else
      echo "Installing Ghostty via Homebrew Cask..."
      brew install --cask ghostty || true
    fi

    # macOS Ghostty shell override (forces modern Homebrew Bash 5)
    local MAC_GHOSTTY_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty"
    mkdir -p "$MAC_GHOSTTY_DIR"
    if [ ! -f "$MAC_GHOSTTY_DIR/config" ]; then
      cat << 'EOF' > "$MAC_GHOSTTY_DIR/config"
# macOS Ghostty configuration overrides
command = /opt/homebrew/bin/bash --login
EOF
      echo "✅ Configured Ghostty macOS default shell to Homebrew Bash 5"
    fi
  elif [ "$OS" == "bazzite" ]; then
    flatpak install -y flathub com.mitchellh.ghostty 2>/dev/null || brew install --cask ghostty 2>/dev/null || true
  elif [ "$OS" == "arch" ]; then
    if command -v paru &>/dev/null; then
      paru -S --needed --noconfirm ghostty
    else
      run_sudo pacman -S --needed --noconfirm ghostty 2>/dev/null || (command -v yay &>/dev/null && yay -S --needed --noconfirm ghostty) || true
    fi
  elif [ "$OS" == "fedora" ] || [ "$OS" == "rocky" ]; then
    run_sudo dnf copr enable -y pgdev/ghostty 2>/dev/null || true
    run_sudo dnf install -y ghostty 2>/dev/null || flatpak install -y flathub com.mitchellh.ghostty 2>/dev/null || true
  elif [ "$OS" == "debian" ]; then
    if command -v ghostty &>/dev/null; then
      echo "Ghostty is already installed. Skipping..."
    else
      echo "Checking available installation methods for Ghostty on Debian/Raspbian..."
      if command -v flatpak &>/dev/null; then
        flatpak install -y flathub com.mitchellh.ghostty 2>/dev/null || true
      else
        local ARCH=$(uname -m)
        echo "Attempting pre-built release package for $ARCH..."
        local GHOSTTY_DEB=""
        if [ "$ARCH" == "x86_64" ]; then
          GHOSTTY_DEB="https://github.com/ghostty-org/ghostty/releases/latest/download/ghostty_linux_amd64.deb"
        elif [ "$ARCH" == "aarch64" ]; then
          GHOSTTY_DEB="https://github.com/ghostty-org/ghostty/releases/latest/download/ghostty_linux_arm64.deb"
        fi
        if [ -n "$GHOSTTY_DEB" ]; then
          curl -fsSL -o /tmp/ghostty.deb "$GHOSTTY_DEB" 2>/dev/null && run_sudo apt-get install -y /tmp/ghostty.deb 2>/dev/null && rm -f /tmp/ghostty.deb || true
        fi
      fi
    fi
  fi
  install_firacode_nerd_font
}

install_vscode() {
  echo "=================================================="
  echo "Installing Visual Studio Code..."
  if [ "$OS" == "macos" ]; then
    if [ -d "/Applications/Visual Studio Code.app" ] || command -v code &>/dev/null; then
      echo "Visual Studio Code is already installed."
    else
      echo "Installing Visual Studio Code via Homebrew Cask..."
      brew install --cask visual-studio-code
    fi

    # macOS CONFIG BRIDGE (macOS stores settings in ~/Library/Application Support/Code/User)
    echo "Configuring macOS VS Code Config Bridge..."
    local MAC_CONFIG_DIR="$HOME/Library/Application Support/Code/User"
    local STANDARD_CONFIG_DIR="$HOME/.config/Code/User"
    mkdir -p "$MAC_CONFIG_DIR"
    if [ -f "$STANDARD_CONFIG_DIR/settings.json" ]; then
      ln -sf "$STANDARD_CONFIG_DIR/settings.json" "$MAC_CONFIG_DIR/settings.json"
    fi
    if [ -f "$STANDARD_CONFIG_DIR/keybindings.json" ]; then
      ln -sf "$STANDARD_CONFIG_DIR/keybindings.json" "$MAC_CONFIG_DIR/keybindings.json"
    fi
    if [ -d "$STANDARD_CONFIG_DIR/snippets" ]; then
      ln -sfn "$STANDARD_CONFIG_DIR/snippets" "$MAC_CONFIG_DIR/snippets"
    fi
  elif [ "$OS" == "bazzite" ]; then
      if ! flatpak list --app | grep -q "com.visualstudio.code"; then
          flatpak install -y flathub com.visualstudio.code
      fi
  elif [ "$OS" == "arch" ]; then
      if command -v paru &> /dev/null; then paru -S --needed --noconfirm visual-studio-code-bin; fi
  elif [ "$OS" == "fedora" ] || [ "$OS" == "rocky" ]; then
    run_sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    run_sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
    run_sudo dnf install -y code
  elif [ "$OS" == "debian" ]; then
    run_sudo apt-get install -y wget gpg
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
    run_sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
    run_sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
    rm -f packages.microsoft.gpg
    run_sudo apt-get install -y apt-transport-https
    run_sudo apt-get update
    run_sudo apt-get install -y code
  fi

  # FLATPAK CONFIG BRIDGE (Crucial for Bazzite)
  if [ "$OS" == "bazzite" ] || flatpak list --app 2>/dev/null | grep -q "com.visualstudio.code"; then
      echo "Configuring Flatpak Sandbox Bridge..."
      FLATPAK_CONFIG_DIR="$HOME/.var/app/com.visualstudio.code/config/Code/User"
      STANDARD_CONFIG_DIR="$HOME/.config/Code/User"
      mkdir -p "$FLATPAK_CONFIG_DIR"
      if [ -f "$STANDARD_CONFIG_DIR/settings.json" ]; then
          ln -sf "$STANDARD_CONFIG_DIR/settings.json" "$FLATPAK_CONFIG_DIR/settings.json"
      fi
      if [ -f "$STANDARD_CONFIG_DIR/keybindings.json" ]; then
          ln -sf "$STANDARD_CONFIG_DIR/keybindings.json" "$FLATPAK_CONFIG_DIR/keybindings.json"
      fi
  fi

  # EXTENSIONS
  VSCODE_CMD="code"
  if ! command -v code &> /dev/null; then
    if [ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]; then
      VSCODE_CMD="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    elif command -v flatpak &> /dev/null && flatpak list --app 2>/dev/null | grep -q "com.visualstudio.code"; then
      VSCODE_CMD="flatpak run com.visualstudio.code"
    fi
  fi

  if [ -f "$DOTFILES_DIR/vscode/extensions.list" ]; then
    echo "Reconciling VS Code extensions using: $VSCODE_CMD"

    local DESIRED_FILE
    DESIRED_FILE=$(mktemp)
    grep -v '^\s*#' "$DOTFILES_DIR/vscode/extensions.list" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | tr '[:upper:]' '[:lower:]' > "$DESIRED_FILE"

    local INSTALLED_FILE
    INSTALLED_FILE=$(mktemp)
    $VSCODE_CMD --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' > "$INSTALLED_FILE"

    # 1. Install missing extensions
    while IFS= read -r extension; do
      if [ -n "$extension" ] && ! grep -qxF "$extension" "$INSTALLED_FILE"; then
        echo "  ➕ Installing $extension..."
        $VSCODE_CMD --install-extension "$extension" --force || true
      fi
    done < "$DESIRED_FILE"

    # 2. Uninstall unlisted extensions (maintains exact sync across machines)
    # Re-check in up to 2 passes to resolve dependency ordering (e.g. extension A depending on B)
    for _ in 1 2; do
      local UNLISTED_FOUND=false
      $VSCODE_CMD --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' > "$INSTALLED_FILE"
      while IFS= read -r installed_ext; do
        if [ -n "$installed_ext" ] && [ "$installed_ext" != "ms-vscode-remote.remote-ssh-edit" ]; then
          if ! grep -qxF "$installed_ext" "$DESIRED_FILE"; then
            echo "  🗑️  Uninstalling unlisted extension: $installed_ext..."
            $VSCODE_CMD --uninstall-extension "$installed_ext" 2>/dev/null || true
            UNLISTED_FOUND=true
          fi
        fi
      done < "$INSTALLED_FILE"
      [ "$UNLISTED_FOUND" = false ] && break
    done

    rm -f "$DESIRED_FILE" "$INSTALLED_FILE"
  fi
}

install_tmux_plugins() {
    echo "=================================================="
    echo "Installing & Updating Tmux plugins..."
    if [ ! -d ~/.tmux/plugins/tpm ]; then
        git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
    fi
    if [ ! -d ~/.config/tmux/plugins/catppuccin/tmux ]; then
        mkdir -p ~/.config/tmux/plugins/catppuccin
        git clone -b v2.1.3 https://github.com/catppuccin/tmux.git ~/.config/tmux/plugins/catppuccin/tmux
    fi
    # Force TERM=xterm-256color and TMUX_PLUGIN_MANAGER_PATH fallback
    # to avoid 'missing terminal: xterm-ghostty' on remote headless servers
    TMUX_PLUGIN_MANAGER_PATH="$HOME/.tmux/plugins/" TERM=xterm-256color ~/.tmux/plugins/tpm/bin/install_plugins || true
    if [ "$IS_UPGRADE" = true ]; then
        TMUX_PLUGIN_MANAGER_PATH="$HOME/.tmux/plugins/" TERM=xterm-256color ~/.tmux/plugins/tpm/bin/update_plugins all || true
    fi
}

install_python_uv() {
  echo "=================================================="
  echo "Installing / Updating uv (Python Manager)..."

  if ! command -v uv &> /dev/null; then
    if [ "$OS" == "macos" ] && command -v brew &> /dev/null; then
      brew install uv
    else
      curl -LsSf https://astral.sh/uv/install.sh | sh
      export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    fi
  else
    echo "uv is already installed. Updating..."
    if [ "$OS" == "macos" ] && command -v brew &>/dev/null && brew list --formula uv &>/dev/null; then
      brew upgrade uv 2>/dev/null || true
    else
      uv self update || true
    fi
  fi

  if [ -f "$DOTFILES_DIR/.python-version" ]; then
      PYTHON_VERSION=$(cat "$DOTFILES_DIR/.python-version")
      echo "Installing Python $PYTHON_VERSION via uv..."
      uv python install "$PYTHON_VERSION"
  fi

  echo "Setting up Dotfiles Virtual Environment..."
  cd "$DOTFILES_DIR"
  if [ -d "$DOTFILES_DIR/.venv" ]; then
      run_sudo chown -R "$(id -u):$(id -g)" "$DOTFILES_DIR/.venv" 2>/dev/null || true
  fi
  if [ "$IS_UPGRADE" = true ]; then
      echo "Upgrading lockfile dependencies..."
      uv lock --upgrade || true
  fi
  uv sync
}

generate_configs() {
  echo "=================================================="
  echo "Generating dynamic configs from templates..."

  local REQUIRED_SECRETS=(
    "VLLM_API_KEY"
  )

  if [ -f "$HOME/.bash_secrets" ]; then
    set +e
    source "$HOME/.bash_secrets"
    set -e
  fi

  if [ -t 0 ]; then
    for secret_var in "${REQUIRED_SECRETS[@]}"; do
      if [ -z "${!secret_var}" ]; then
        echo "$secret_var is not set."
        read -sp "Enter value for $secret_var (or press Enter to skip): " INPUT_VAL
        echo
        if [ -n "$INPUT_VAL" ]; then
          export "$secret_var"="$INPUT_VAL"
          if ! grep -q "^export ${secret_var}=" "$HOME/.bash_secrets" 2>/dev/null; then
            echo "export $secret_var=\"$INPUT_VAL\"" >> "$HOME/.bash_secrets"
            chmod 600 "$HOME/.bash_secrets"
            echo "Saved $secret_var to $HOME/.bash_secrets"
          fi
        fi
      fi
    done
  fi

  ZOO_TEMPLATE="$DOTFILES_DIR/zoo-code/.config/zoo-code/settings.json.template"
  ZOO_OUT="$DOTFILES_DIR/zoo-code/.config/zoo-code/settings.json"

  if [ -f "$ZOO_TEMPLATE" ]; then
    if command -v envsubst &> /dev/null; then
      echo "Processing Zoo Code settings.json..."
      envsubst < "$ZOO_TEMPLATE" > "$ZOO_OUT"
    else
      echo "Warning: envsubst not installed. Skipping Zoo Code template."
    fi
  fi
}

link_dotfiles() {
  echo "=================================================="
  echo "Linking Dotfiles using GNU Stow..."
  cd "$DOTFILES_DIR"
  echo "Linking .bash_aliases..."
  ln -sf "$DOTFILES_DIR/.bash_aliases" "$HOME/.bash_aliases"

  if [ ! -d "$HOME/.ssh" ]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  fi

  # 1Password Agent bridge on macOS
  if [ "$OS" == "macos" ]; then
    local OP_MAC_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    mkdir -p "$HOME/.1password"
    if [ -S "$OP_MAC_SOCK" ] || [ -d "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password" ]; then
      ln -sf "$OP_MAC_SOCK" "$HOME/.1password/agent.sock"
      echo "✅ Bridged 1Password macOS agent socket to ~/.1password/agent.sock"
    fi
  fi

  # Prevent Stow tree-folding by ensuring target parent directories exist
  mkdir -p "$HOME/.config/Code/User"
  mkdir -p "$HOME/.config/wezterm"
  mkdir -p "$HOME/.config/ghostty"
  mkdir -p "$HOME/.config/fastfetch"
  mkdir -p "$HOME/.config/zoo-code"
  mkdir -p "$HOME/.config/tmux"
  mkdir -p "$HOME/.local/share/color-schemes"
  mkdir -p "$HOME/.terminfo"
  mkdir -p "$HOME/.gemini/config"

  # Ensure target config files aren't pre-existing regular files that block stow
  if [ -f "$HOME/.gemini/config/config.json" ] && [ ! -L "$HOME/.gemini/config/config.json" ]; then
    rm -f "$HOME/.gemini/config/config.json"
  fi
  if [ -f "$HOME/.gemini/config/mcp_config.json" ] && [ ! -L "$HOME/.gemini/config/mcp_config.json" ]; then
    rm -f "$HOME/.gemini/config/mcp_config.json"
  fi

  local STOW_FOLDERS="fastfetch nvim ssh starship tmux wezterm ghostty vscode continue zoo-code blesh gemini"
  if [ "$OS" != "macos" ]; then
    STOW_FOLDERS="$STOW_FOLDERS kde"
  fi

  for folder in $STOW_FOLDERS; do
    if [ -d "$folder" ]; then
      echo "Stowing $folder..."
      stow --dir="$DOTFILES_DIR" --target="$HOME" -R -v "$folder" 2>/dev/null || \
        stow --dir="$DOTFILES_DIR" --target="$HOME" --adopt -R -v "$folder"
    fi
  done

  # Clear stale ble.sh keymap cache so it regenerates cleanly with updated terminfo
  rm -rf "$HOME/.cache/blesh" 2>/dev/null || true
}

update_bashrc() {
    echo "=================================================="
    echo "Updating shell startup files (.bashrc / .bash_profile)..."
    BASHRC_FILE="$HOME/.bashrc"
    SOURCE_LINE='[ -f ~/.bash_aliases ] && source ~/.bash_aliases'

    if grep -qF "$SOURCE_LINE" "$BASHRC_FILE" 2>/dev/null; then
        echo "Setup line already present in .bashrc."
    elif grep -q "^if \[ -f ~/.bash_aliases \]; then" "$BASHRC_FILE" 2>/dev/null; then
        echo "Standard Debian alias block is already active. Skipping."
    else
        echo -e "\n# Added by setup script\n$SOURCE_LINE" >> "$BASHRC_FILE"
        echo "Added alias source line to the end of .bashrc"
    fi

    # On macOS, login shells execute ~/.bash_profile instead of ~/.bashrc
    if [ "$OS" == "macos" ]; then
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
            if [ "${SHELL-}" != "$BREW_BASH" ]; then
                echo "💡 Tip: Run 'chsh -s $BREW_BASH' to set modern Bash 5 as your default macOS shell."
            fi
        fi
    fi
}

configure_git() {
  echo "=================================================="
  echo "Configuring global Git defaults..."
  git config --global core.editor "nvim"
  git config --global user.name "David Moreno"
  git config --global user.email "davidrmoreno24@gmail.com"
  git config --global init.defaultBranch "main"
  git config --global pull.rebase true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--upgrade)
        IS_UPGRADE=true
        shift
        ;;
      -h|--help)
        echo "Usage: ./sync_system.sh [options]"
        echo "Options:"
        echo "  -u, --upgrade    Upgrade system packages, lockfiles, and tools"
        echo "  -h, --help       Show this help message"
        exit 0
        ;;
      *)
        shift
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  ensure_homebrew

  if [ "$IS_UPGRADE" = true ]; then
    update_system_packages
  fi

  install_packages
  install_starship
  install_blesh
  install_fastfetch
  install_neovim
  ensure_root_nvim

  install_python_uv
  generate_configs

  echo "=================================================="
  link_dotfiles
  configure_git
  sync_neovim_plugins

  if is_ssh_session; then
    echo "SSH session detected. Skipping GUI apps."
  else
    echo "Local session detected."
    # install_wezterm
    install_ghostty
    install_vscode
  fi

  TERM=xterm-256color tmux kill-server 2>/dev/null || true
  install_tmux_plugins
  update_bashrc

  echo "=================================================="
  echo "Sync complete!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
