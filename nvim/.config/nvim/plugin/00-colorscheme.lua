-- Theme Packages (Managed by theme-switch)
vim.pack.add({ 'https://github.com/catppuccin/nvim' })
vim.pack.add({ 'https://github.com/folke/tokyonight.nvim' })
vim.pack.add({ 'https://github.com/scottmckendry/cyberdream.nvim' })
vim.pack.add({ 'https://github.com/olivercederborg/poimandres.nvim' })

require("tokyonight").setup({
  style = "night",
  transparent = false,
})
vim.cmd("colorscheme tokyonight-night")
