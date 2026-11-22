if vim.g.loaded_astro_editor then
  return
end
vim.g.loaded_astro_editor = true

local manifest = vim.env.ASTRO_EDITOR_MANIFEST
if not manifest or manifest == '' then
  return
end
-- Keep a nested Neovim (e.g. in :terminal) from opening the same manifest.
vim.env.ASTRO_EDITOR_MANIFEST = nil

-- Open after startup so the person's own config and plugins are already set up.
vim.api.nvim_create_autocmd('VimEnter', {
  once = true,
  callback = function()
    require('astro_editor').start(manifest)
  end,
})
