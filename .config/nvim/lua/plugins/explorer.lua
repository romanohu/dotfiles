return {
  {
    "folke/snacks.nvim",
    init = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "VeryLazy",
        once = true,
        callback = function()
          if #vim.api.nvim_list_uis() > 0 and #Snacks.picker.get({ source = "explorer" }) == 0 then
            Snacks.explorer({ cwd = LazyVim.root(), enter = false })
          end
        end,
      })
    end,
    opts = {
      picker = {
        sources = {
          explorer = { ignored = true },
        },
      },
    },
  },
}
