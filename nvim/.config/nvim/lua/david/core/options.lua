-- Sets File Explorer to Tree
vim.cmd("let g:netrw_liststyle = 3")

-- set global opt
local opt = vim.opt

-- line numbers
-- show relative line numbers
opt.relativenumber = false 
-- shows absolute line number on cursor line (when relative number is on)
opt.number = true

-- shows absolute line number on cursor line (when relative number is on)-- tabs & indentation
-- 2 spaces for tabs (prettier default)
opt.tabstop = 2
-- 2 spaces for indent width
opt.shiftwidth = 2
-- expand tab to spaces
opt.expandtab = true
-- copy indent from current line when starting new one
opt.autoindent = true

-- line wrapping
-- disable line wrapping
opt.wrap = false

-- search settings
-- ignore case when searching
opt.ignorecase = true
-- if you include mixed case in your search, assumes you want case-sensitive
opt.smartcase = true

-- cursor line
-- highlight the current cursor line
opt.cursorline = true

-- appearance

-- turn on termguicolors for nightfly colorscheme to work
-- (have to use iterm2 or any other true color terminal)
opt.termguicolors = true
-- colorschemes that can be light or dark will be made dark
opt.background = "dark"
-- show sign column so that text doesn't shift
opt.signcolumn = "yes"

-- backspace
-- allow backspace on indent, end of line or insert mode start position
opt.backspace = "indent,eol,start"

-- clipboard
-- use system clipboard as default register
-- opt.clipboard:append("unnamedplus")
-- the above doesn't work at least on Mac to copy to system clipboard
-- but this does
opt.clipboard = "unnamedplus"

-- split windows
-- split vertical window to the right
opt.splitright = true
-- split horizontal window to the bottom
opt.splitbelow = true

-- turn off swapfile
opt.swapfile = false