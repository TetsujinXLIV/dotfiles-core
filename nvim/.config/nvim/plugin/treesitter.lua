vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    if ev.data.spec.name == 'nvim-treesitter' and ev.data.kind == 'update' then
      if not ev.data.active then vim.cmd.packadd('nvim-treesitter') end
      vim.cmd('TSUpdate')
    end
  end
})

vim.pack.add({ 'https://github.com/nvim-treesitter/nvim-treesitter' })

-- SAFEGUARD: Prevent crashes if the plugin is still downloading
local status_ok, treesitter = pcall(require, "nvim-treesitter.configs")
if not status_ok then
  return
end

treesitter.setup({
  ensure_installed = { "bash", "json", "yaml", "toml", "lua", "markdown" },
  highlight = { enable = true },
})