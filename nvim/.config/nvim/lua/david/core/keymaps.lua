-- set leader key to space
vim.g.mapleader = " "

-- for conciseness
local keymap = vim.keymap

---------------------
-- General Keymaps -------------------

-- use jk to exit insert mode
keymap.set("i", "jk", "<ESC>", { desc = "Exit insert mode with jk" })

-- clear search highlights
keymap.set("n", "<leader>nh", ":nohl<CR>", { desc = "Clear search highlights" })

-- delete single character without copying into register
-- keymap.set("n", "x", '"_x')

-- increment/decrement numbers
-- increment
keymap.set("n", "<leader>+", "<C-a>", { desc = "Increment number" })
-- decrement
keymap.set("n", "<leader>-", "<C-x>", { desc = "Decrement number" })

-- window management
-- split window vertically
keymap.set("n", "<leader>sv", "<C-w>v", { desc = "Split window vertically" })
-- split window horizontally
keymap.set("n", "<leader>sh", "<C-w>s", { desc = "Split window horizontally" })
-- make split windows equal width & height
keymap.set("n", "<leader>se", "<C-w>=", { desc = "Make splits equal size" })
-- close current split window
keymap.set("n", "<leader>sx", "<cmd>close<CR>", { desc = "Close current split" })

-- open new tab
keymap.set("n", "<leader>to", "<cmd>tabnew<CR>", { desc = "Open new tab" })
-- close current tab
keymap.set("n", "<leader>tx", "<cmd>tabclose<CR>", { desc = "Close current tab" })
--  go to next tab
keymap.set("n", "<leader>tn", "<cmd>tabn<CR>", { desc = "Go to next tab" })
--  go to previous tab
keymap.set("n", "<leader>tp", "<cmd>tabp<CR>", { desc = "Go to previous tab" })
--  move current buffer to new tab
keymap.set("n", "<leader>tf", "<cmd>tabnew %<CR>", { desc = "Open current buffer in new tab" })