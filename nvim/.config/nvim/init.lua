-- Setup core options and keymaps
require("david.core")

-- Restore cursor position on file open
vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = "*",
    callback = function()
      local mark = vim.api.nvim_buf_get_mark(0, "\"")
      local line_count = vim.api.nvim_buf_line_count(0)
      if mark[1] > 0 and mark[1] <= line_count then
        vim.api.nvim_win_set_cursor(0, mark)
      end
    end,
})