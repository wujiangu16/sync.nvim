if vim.g.loaded_sync_nvim == 1 then
  return
end

vim.g.loaded_sync_nvim = 1

require("sync_nvim").setup()
