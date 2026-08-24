# Neovim Workspace Guide

### ⚠️ Neovim 0.12 Migration Note

This configuration uses Neovim 0.12's native `vim.pack` package manager. If you
are migrating an existing machine from `lazy.nvim`, you **must** clear out the
old Lazy data before starting Neovim to prevent conflicts:

```bash
rm -rf ~/.local/share/nvim/lazy
rm ~/.config/nvim/lazy-lock.json
```

On first boot, `vim.pack` will prompt you to install your plugins. Press `a` to
allow all.

---

### 🗺️ The Ultimate Helper: Which-Key

If you ever forget a command, **just press `<Space>` and wait half a second**.

- **Which-Key** will automatically pop up at the bottom of your screen and show
  you a menu of every available keybinding you can press next.

---

### 📁 File Explorer (NvimTree)

NvimTree is your sidebar file explorer. It behaves like a traditional IDE file
tree.

- `<Space> + ee`: Toggle the explorer open/closed.
- `<Space> + ef`: Open the explorer and jump directly to the file you are
  currently editing.
- `<Space> + ec`: Collapse all open folders in the tree.
- `<Space> + er`: Refresh the tree (useful if you created a file outside of
  Neovim).
- _Inside the tree:_ Press `Enter` to open a file, `a` to create a new
  file/folder, and `d` to delete.

---

### 🔍 Fuzzy Finder (Telescope)

Telescope is the engine for finding files, words, and text across your entire
project instantly.

- `<Space> + ff`: **Find Files** (Search by file name in your current
  directory).
- `<Space> + fr`: **Find Recent** (Search through files you've recently opened).
- `<Space> + fs`: **Find String** (Live grep/search for specific words inside
  all files).
- `<Space> + fc`: **Find Cursor** (Search your whole project for the exact word
  your cursor is currently resting on).
- _Inside Telescope:_ Use `<Ctrl> + j` and `<Ctrl> + k` to move up and down the
  results list. Press `<Ctrl> + q` to send your search results to a quickfix
  list.

---

### 🪟 Panes & Navigation (vim-tmux-navigator)

Because you use Tmux, this plugin seamlessly bridges the gap between Neovim
splits and Tmux panes.

- Use `<Ctrl> + h/j/k/l` to move seamlessly between your Neovim splits and your
  Tmux panes as if they were the same thing.

---

### 🚀 The Dashboard (Alpha)

When you open Neovim without specifying a file, you'll see your custom
dashboard. You can use these single-key shortcuts directly from that screen:

- `e`: Create a new empty file.
- `<Space> + ee`: Open the file explorer.
- `<Space> + ff`: Jump straight to finding a file.
- `<Space> + fs`: Jump straight to finding a word.
- `<Space> + wr`: Restore your last session for this directory.
- `q`: Quit Neovim.

---

### ⌨️ Core Keymap Cheat Sheet

- **Escape Insert Mode:** `jk`
- **Clear Search Highlights:** `<Space> + nh`
- **Split Windows:** `<Space> + sv` (Vertical) | `<Space> + sh` (Horizontal)
- **Close Split:** `<Space> + sx`
- **Equalize Splits:** `<Space> + se`
- **Tab Management:** `<Space> + to` (New) | `<Space> + tx` (Close) |
  `<Space> + tn` (Next) | `<Space> + tp` (Previous)

---

### 🔄 Updating Plugins (vim.pack)

Because Neovim now handles plugins natively, there is no `:Lazy` menu. Instead,
Neovim uses a built-in "Confirmation Buffer" to handle updates.

**1. Check for Updates** Run this command in Neovim:
`:lua vim.pack.update()`_(Tip: You can map this to a keybinding if you do it
frequently!)_

**2. The Confirmation Buffer** Neovim will open a new tab showing a list of
every plugin that has a pending update, along with the Git commit messages
explaining what changed.

- Use `]]` and `[[` to jump between the different plugins in the list.
- Press `K` (Hover) over a commit to see the exact code changes in a popup.

**3. Apply or Cancel** Because this is native Vim, you interact with this list
just like a text file:

- **To approve and install the updates:** Just save the file by typing `:w` (or
  `:write`).
- **To cancel and abort:** Just close the window by typing `:q` (or `:quit`).

_(Note: There is no direct equivalent to `:Lazy reload` for hot-reloading a
plugin on the fly. If you update a plugin or change its config, the standard
practice is to just restart Neovim to let the native runtime load it fresh)._

---

### 📝 Quick Commenting (Native Neovim)

You don't need a plugin to comment out config lines anymore; Neovim handles it
natively:

- `gcc`: Comment or uncomment the exact line your cursor is on.
- `gc`: If you highlight a chunk of text in Visual Mode, press this to
  comment/uncomment the whole block at once.

### 🐙 Visual Git Status (Gitsigns)

As you edit files that are tracked in Git, look at the far left edge of your
screen (the "gutter" next to the line numbers):

- A **Green vertical line** means you added that line.
- A **Blue vertical line** means you modified an existing line.
- A **Red triangle** means you deleted a line there.

### 🪄 Auto-Formatting (Pairs & Treesitter)

These plugins run silently in the background to make editing configs much
faster:

- **Auto-Closing:** Whenever you type a `(`, `[`, `{`, `"`, or `'`, the editor
  will automatically insert the closing pair and put your cursor in the middle.
- **Smart Syntax Colors:** Because you have Treesitter installed, your config
  files (JSON, YAML, Bash, Lua, etc.) aren't just colored using basic
  word-matching. The editor actually reads the structure of the file, meaning
  your keys, values, and arrays will be perfectly color-coded to prevent typos.
