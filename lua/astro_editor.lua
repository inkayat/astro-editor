-- AstroEditor runtime: opens what one launch manifest asks for, using stock
-- Neovim commands only. The manifest's paths are data: they are checked and
-- escaped, never evaluated. This module never runs another program.
local M = {}

local function fail(msg)
  vim.notify('astro-editor: ' .. msg, vim.log.levels.ERROR)
end

-- Returns nil or an error message. `at` prefixes the field name in messages.
local function check_path(t, key, is_kind, at)
  local name = (at or '') .. key
  local p = t[key]
  if type(p) ~= 'string' or p == '' or vim.fn.isabsolutepath(p) ~= 1 then
    return name .. ' must be an absolute path'
  end
  if not is_kind(p) then
    return 'cannot open ' .. name .. ': ' .. p
  end
end

local function is_dir(p)
  return vim.fn.isdirectory(p) == 1
end

local function is_file(p)
  return vim.fn.filereadable(p) == 1
end

-- Statuses a whole-file diff can show.
local statuses = { modified = true, renamed = true, added = true, deleted = true }

-- JSON null decodes to vim.NIL; a field that is null is absent.
local function absent(v)
  return v == nil or v == vim.NIL
end

-- Returns nil or an error message for a `changes` list.
local function check_changes(list)
  if type(list) ~= 'table' or #list == 0 or not vim.islist(list) then
    return 'changes must be a non-empty list'
  end
  local seen = {}
  for i, c in ipairs(list) do
    local at = ('changes[%d].'):format(i)
    if type(c) ~= 'table' then
      return at:sub(1, -2) .. ' must be an object'
    end
    if not statuses[c.status] then
      return at .. 'status not supported: ' .. tostring(c.status)
    end
    if type(c.name) ~= 'string' or c.name == '' or c.name:find('%c') then
      return at .. 'name must be non-empty text without control characters'
    end
    local err
    if c.status == 'deleted' then
      if not absent(c.path) then
        return at .. 'path must be omitted for a deleted file'
      end
    else
      err = check_path(c, 'path', is_file, at)
    end
    if not err then
      if c.status == 'added' then
        if not absent(c.base) then
          return at .. 'base must be omitted for an added file'
        end
      else
        err = check_path(c, 'base', is_file, at)
      end
    end
    if err then
      return err
    end
    -- One buffer per file: a repeat would make two entries share a window.
    for _, key in ipairs({ 'path', 'base' }) do
      local real = type(c[key]) == 'string' and (vim.uv.fs_realpath(c[key]) or c[key])
      if real then
        if seen[real] then
          return at .. key .. ' repeats a file already in the list: ' .. c[key]
        end
        seen[real] = true
      end
    end
  end
end

-- Returns nil or an error message. Unknown fields are ignored.
function M.check(m)
  if type(m) ~= 'table' then
    return 'manifest must be a JSON object'
  end
  if m.version ~= 1 then
    return 'unsupported manifest version: ' .. tostring(m.version)
  end
  local err
  if m.kind == 'files' then
    err = check_path(m, 'root', is_dir)
  elseif m.kind == 'file' then
    err = check_path(m, 'path', is_file)
    local line = m.line
    if not err and line ~= nil and (type(line) ~= 'number' or line < 1 or line ~= math.floor(line)) then
      err = 'line must be a positive integer'
    end
  elseif m.kind == 'diff' then
    err = check_path(m, 'path', is_file) or check_path(m, 'base', is_file)
  elseif m.kind == 'changes' then
    err = check_changes(m.changes)
  else
    err = 'unknown kind: ' .. tostring(m.kind)
  end
  return err
end

local function edit(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
end

-- Opens `base` (nil: an empty buffer) read-only in diff mode left of the
-- current window, which holds the file it is compared with, and returns to
-- that window. Returns the new window.
local function diff_against(base)
  local win = vim.api.nvim_get_current_win()
  if base then
    vim.cmd('leftabove vertical diffsplit ' .. vim.fn.fnameescape(base))
  else
    vim.cmd('leftabove vnew')
    vim.bo.buftype = 'nofile'
    vim.cmd('diffthis')
    vim.api.nvim_win_call(win, function()
      vim.cmd('diffthis')
    end)
  end
  vim.bo.readonly = true
  vim.bo.modifiable = false
  local left = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win)
  return left
end

-- Windows of the change diff on screen.
local shown = {}

-- Turns the current window, which just received change `c`'s file, into
-- that change's whole-file diff, replacing the previous change's windows.
local function show_change(c)
  local win = vim.api.nvim_get_current_win()
  for _, w in ipairs(shown) do
    if w ~= win and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_hide(w)
    end
  end
  -- The previous change's file is hidden but stays diffed until :diffoff!.
  vim.cmd('diffoff!')
  local left = diff_against(type(c.base) == 'string' and c.base or nil)
  vim.bo[vim.api.nvim_win_get_buf(left)].bufhidden = 'wipe'
  shown = { left, win }
end

-- An empty read-only buffer standing for the missing file of a deleted change.
local function empty_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  return buf
end

-- Lists the changes in the quickfix list and opens the first one. A quickfix
-- jump that selects another listed entry (]q, [q, :cnext, <CR> in the list,
-- ...) shows that entry's diff. Showing a listed file any other way (:split,
-- :edit, <C-^>) leaves the windows alone.
local function open_changes(changes)
  local items = {}
  for i, c in ipairs(changes) do
    items[i] = { module = c.name, lnum = 1, text = c.status }
    if c.status == 'deleted' then
      items[i].bufnr = empty_buffer()
    else
      items[i].filename = c.path
    end
  end
  vim.fn.setqflist({}, ' ', { title = 'AstroEditor changes', items = items })
  local list = vim.fn.getqflist({ id = 0 }).id
  local by_buf = {}
  for i, item in ipairs(vim.fn.getqflist()) do
    by_buf[item.bufnr] = i
  end
  local shown_entry
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = vim.api.nvim_create_augroup('astro_editor_changes', {}),
    nested = true,
    callback = function(a)
      local i = by_buf[a.buf]
      if i and i ~= shown_entry and vim.fn.getqflist({ id = list, idx = 0 }).idx == i then
        shown_entry = i
        show_change(changes[i])
      end
    end,
  })
  vim.cmd('cfirst')
  vim.cmd('botright copen')
  vim.cmd('wincmd p')
end

-- Opens a decoded manifest. Returns true, or false after notifying the error.
function M.open(m)
  local err = M.check(m)
  if err then
    fail(err)
    return false
  end
  if m.kind == 'files' then
    vim.fn.chdir(m.root)
    edit(m.root)
  elseif m.kind == 'file' then
    edit(m.path)
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(m.line or 1, last), 0 })
  elseif m.kind == 'diff' then
    edit(m.path)
    diff_against(m.base)
  else
    open_changes(m.changes)
  end
  return true
end

-- Reads and opens the manifest file at `path`.
function M.start(path)
  local ok, m = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  end)
  if not ok then
    fail('cannot read manifest ' .. path .. ': ' .. tostring(m))
    return false
  end
  return M.open(m)
end

return M
