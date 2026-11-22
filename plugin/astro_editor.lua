if vim.g.loaded_astro_editor then
  return
end
vim.g.loaded_astro_editor = true

-- Refuses until a launch manifest declares context destinations.
vim.api.nvim_create_user_command('AstroContext', function(opts)
  require('astro_editor').send_context(opts)
end, {
  nargs = '?',
  range = true,
  desc = 'Send the selection or location to a destination AstroApp declared',
  complete = function(lead)
    return vim.tbl_filter(function(id)
      return vim.startswith(id, lead)
    end, require('astro_editor').destination_ids())
  end,
})

local manifest = vim.env.ASTRO_EDITOR_MANIFEST
if not manifest or manifest == '' then
  return
end
-- Keep a nested Neovim (e.g. in :terminal) from opening the same manifest.
vim.env.ASTRO_EDITOR_MANIFEST = nil

-- Open after startup so the person's own config and plugins are already set up.
-- Nested so opening files runs the usual autocommands (filetype, plugins, ...).
vim.api.nvim_create_autocmd('VimEnter', {
  once = true,
  nested = true,
  callback = function()
    require('astro_editor').start(manifest)
  end,
})
