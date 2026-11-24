return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        pyright = {},
        clangd = { mason = false },
        rust_analyzer = { mason = false },
      },
    },
  },
}
