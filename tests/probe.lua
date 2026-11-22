-- Loaded by tests/run.lua inside the Neovim under test (via -c). Once startup
-- has finished, records the editor state as JSON in $PROBE_OUT and quits.
-- $PROBE_KEYS, a JSON list of key sequences, is typed one entry at a time
-- after that, recording the state after each in `steps`.
local function windows()
  local list = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    table.insert(list, {
      name = vim.api.nvim_buf_get_name(b),
      type = vim.fn.win_gettype(w),
      diff = vim.wo[w].diff,
      modifiable = vim.bo[b].modifiable,
    })
  end
  return list
end

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
    windows = windows(),
    qf = vim.fn.getqflist({ title = 0, items = 0 }),
    steps = {},
  }
  if vim.wo.diff then
    vim.cmd('normal! ]c')
    out.hunk_line = vim.fn.line('.')
    vim.cmd('normal! G')
    out.end_line = vim.fn.line('.')
    out.line_count = vim.fn.line('$')
  end
  for _, keys in ipairs(vim.json.decode(vim.env.PROBE_KEYS or '[]')) do
    -- As typed: <Esc> at a prompt cancels as a person's <Esc> does.
    vim.api.nvim_feedkeys(vim.keycode(keys), 'mtx', false)
    table.insert(out.steps, {
      keys = keys,
      errmsg = vim.v.errmsg,
      message = vim.api.nvim_exec2('1messages', { output = true }).output,
      buf = vim.api.nvim_buf_get_name(0),
      line = vim.fn.line('.'),
      line_count = vim.fn.line('$'),
      qf_idx = vim.fn.getqflist({ idx = 0 }).idx,
      left_lines = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(0)[1])),
      windows = windows(),
    })
  end
  vim.fn.writefile({ vim.json.encode(out) }, vim.env.PROBE_OUT)
  vim.cmd('qa!')
end)
