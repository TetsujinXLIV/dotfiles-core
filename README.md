# Dotfiles Core

A clean, modular, and dependency-lightweight dotfiles configuration for
workstations, laptops, and remote servers. Managed using GNU Stow.

This repository contains core configurations for:

- **Ghostty**: Terminal emulator with native tabs, clipboard integration, and
  `xterm-256color` compatibility.
- **Neovim**: Modern Neovim configuration using native 0.12 `vim.pack`.
- **Tmux**: Terminal multiplexer with Vim copy mode and OSC 52 clipboard.
- **VS Code**: Editor settings, keybindings, and extension manifests.

---

## 🚀 Quick Start

Run the declarative sync script on macOS or Debian/Ubuntu:

```bash
# 1. Clone the repository
git clone https://github.com/<your-username>/dotfiles-core.git ~/dotfiles-core
cd ~/dotfiles-core

# 2. Run the declarative sync script
./sync_core.sh
```

### Script Options

```bash
# Upgrade system packages, Neovim release binary, and plugins
./sync_core.sh -u

# Run on headless/server machines (skips Ghostty & VS Code desktop apps)
./sync_core.sh --headless

# Install ble.sh (Bash Line Editor) for enhanced history search
./sync_core.sh --with-blesh

# Reconcile VS Code extensions and prune unlisted ones
./sync_core.sh --prune-extensions

# Stow only specific packages
./sync_core.sh nvim tmux
```

### 1. macOS (Work Laptop)

- **Homebrew**: Automatically ensures Homebrew and base packages (`git`, `stow`,
  `tmux`, `ripgrep`, `fzf`).
- **VS Code**: Installs Visual Studio Code and links `settings.json`,
  `keybindings.json`, and snippets to
  `~/Library/Application Support/Code/User/`.
- **Ghostty**: Installs Ghostty and configures native tab navigation and
  clipboard integration.

---

### 2. Debian & Ubuntu (Workstation & Remote SSH)

- **Neovim 0.12**: Automatically checks and downloads the modern pre-built
  release binary (bypassing ancient Debian apt packages) with native `vim.pack`
  package management.
- **Tmux Plugins**: TPM and Catppuccin plugins are automatically cloned and
  installed.
- **OSC 52 Clipboard**: Pressing `y` inside Tmux copy mode pipes text directly
  to your client clipboard across SSH sessions.
- **Headless Detection**: Automatically detects SSH sessions and skips desktop
  GUI installations (Ghostty/VS Code).

---

### 3. Windows 11 (Workstation & PC Builds)

Run the declarative PowerShell sync script in PowerShell 7 or Windows Terminal:

```powershell
# Default: PC build & maintenance mode (apps, runtimes, benchmarks, and gaming tools only)
.\sync_windows.ps1

# Routine upgrade of all installed Winget applications on a PC build
.\sync_windows.ps1 -Upgrade

# Workstation developer setup (installs Git, Neovim, VS Code, OpenSSH, and links dotfiles)
.\sync_windows.ps1 -Dev

# Full workstation upgrade (pulls repo, upgrades Winget apps, and updates Neovim plugins)
.\sync_windows.ps1 -Dev -Upgrade
```

---

## 📦 Modular Package Management (GNU Stow)

You can selectively link or unlink individual packages at any time:

```bash
# Link specific packages
stow ghostty
stow vscode
stow nvim
stow tmux

# Unlink a package
stow -D ghostty

# Re-link / Refresh a package
stow -R nvim
```

---

## ⌨️ Key Features & Shortcuts

### Ghostty Terminal

- **New Tab**: `Ctrl + Shift + T`
- **Close Tab**: `Ctrl + Shift + W`
- **Switch Tabs**: `Ctrl + Tab` / `Ctrl + Shift + Tab` or `Alt + 1..5`
- **Auto Copy**: Selecting text with the mouse automatically copies to the
  system clipboard.

### Tmux Multiplexer

- **Prefix Key**: `Ctrl + S`
- **Split Horizontally**: `Ctrl + S |`
- **Split Vertically**: `Ctrl + S -`
- **Copy Mode**: `Ctrl + S [` $\rightarrow$ start selection with `v`
  $\rightarrow$ copy to system clipboard with `y`.

### Neovim 0.12

- Uses native `vim.pack` package management.
- Leader key: `Space`
- File tree, fuzzy finder, LSP integrations, and true-color themes.

---

## 🛠️ Repository Synchronization

This repository is mirrored from the primary dotfiles workspace via:

```bash
# From the primary dotfiles repository
sync-core
```
