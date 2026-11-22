-- Loaded by tests/run.lua inside the Neovim under test (via -c). Once startup
-- has finished, records the editor state as JSON in $PROBE_OUT and quits.
vim.schedule(function()
  local out = {
    cwd = vim.fn.getcwd(),
    errmsg = vim.v.errmsg,
    buf = vim.api.nvim_buf_get_name(0),
    filetype = vim.bo.filetype,
    line = vim.fn.line('.'),
    manifest_env = vim.env.ASTRO_EDITOR_MANIFEST or vim.NIL,
    user_init = vim.g.test_user_init == true,
    user_plugin = vim.g.test_user_plugin == true,
    person_nvim_config = vim.g.test_person_nvim_config == true,
    windows = {},
  }
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    table.insert(out.windows, {
      name = vim.api.nvim_buf_get_name(b),
      diff = vim.wo[w].diff,
      modifiable = vim.bo[b].modifiable,
    })
  end
  if vim.wo.diff then
    vim.cmd('normal! ]c')
    out.hunk_line = vim.fn.line('.')
    vim.cmd('normal! G')
    out.end_line = vim.fn.line('.')
    out.line_count = vim.fn.line('$')
  end
  vim.fn.writefile({ vim.json.encode(out) }, vim.env.PROBE_OUT)
  vim.cmd('qa!')
end)
