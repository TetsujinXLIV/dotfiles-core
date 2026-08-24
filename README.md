# Dotfiles Core

A clean, modular, and dependency-lightweight dotfiles configuration for
workstations, laptops, and remote servers. Managed using GNU Stow.

This repository contains core configurations for:

- **Ghostty**: Terminal emulator with native tabs and clipboard integration.
- **Neovim**: Modern Neovim configuration using native 0.12 `vim.pack`.
- **Starship**: Cross-shell prompt with semantic color palettes.
- **Tmux**: Terminal multiplexer with Vim copy mode and OSC 52 clipboard.
- **VS Code**: Editor settings, keybindings, and extension manifests.

---

## 🚀 Quick Start

### 1. macOS (Work Laptop)

On macOS, Ghostty, VS Code, and Starship are linked automatically.

```bash
# 1. Clone the repository
git clone https://github.com/<your-username>/dotfiles-core.git ~/dotfiles-core
cd ~/dotfiles-core

# 2. Run the declarative sync script
./sync_core.sh
```

- **Homebrew**: Automatically installs `stow`, `starship`, `ripgrep`, and `fzf`.
- **VS Code**: Links `settings.json` and `keybindings.json` to
  `~/Library/Application Support/Code/User/`.
- **Ghostty**: Configures native tab navigation and clipboard integration.

---

### 2. Debian & Ubuntu (Workstation & Remote SSH)

On Debian/Ubuntu machines, Neovim, Tmux, and Starship are prioritized for
terminal and remote SSH workflows.

```bash
# 1. Clone the repository
git clone https://github.com/<your-username>/dotfiles-core.git ~/dotfiles-core
cd ~/dotfiles-core

# 2. Run the declarative sync script
./sync_core.sh
```

- **Neovim Plugins**: Native `vim.pack` initializes automatically on first run.
- **Tmux Plugins**: TPM and Catppuccin plugins are automatically cloned and
  installed.
- **OSC 52 Clipboard**: Pressing `y` inside Tmux copy mode pipes text directly
  to your client clipboard across SSH sessions.

---

## 📦 Modular Package Management (GNU Stow)

You can selectively link or unlink individual packages at any time:

```bash
# Link specific packages
stow ghostty
stow vscode
stow nvim
stow tmux
stow starship

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
