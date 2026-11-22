-- Headless tests: nvim -l tests/run.lua
-- Each case starts the real Neovim binary the way AstroApp launches it
-- (NVIM_APPNAME=astro-editor, runtime prepended to 'runtimepath') under a
-- throwaway XDG home, then checks the state tests/probe.lua records.
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local tmp = vim.fn.tempname()
local failures = 0

local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  vim.fn.writefile(lines, path)
end

-- Synthetic XDG home. config/nvim stands in for the person's own (e.g.
-- LazyVim) config, which AstroEditor must not load; config/astro-editor is
-- the AstroEditor profile's own config, with one ordinary start package.
local xdg = tmp .. '/xdg'
write(xdg .. '/config/nvim/init.lua', { 'vim.g.test_person_nvim_config = true' })
write(xdg .. '/config/astro-editor/init.lua', { 'vim.g.test_user_init = true' })
write(xdg .. '/config/astro-editor/pack/user/start/demo/plugin/demo.lua', { 'vim.g.test_user_plugin = true' })

-- Workspace fixtures; names carry characters Ex would otherwise expand.
local root = tmp .. '/work space %#$x'
local notes = root .. '/notes %1.txt'
local work = root .. '/main #2.txt'
local base = tmp .. '/base/main #2.txt'
local work_lines, base_lines = {}, {}
for i = 1, 200 do
  work_lines[i] = 'line ' .. i
  base_lines[i] = (i >= 120 and i <= 122) and ('old ' .. i) or ('line ' .. i)
end
write(notes, vim.split(('n\n'):rep(50), '\n', { trimempty = true }))
write(work, work_lines)
write(base, base_lines)

-- A synthetic change list: modified (work vs base), added and renamed files.
local added = root .. '/new %3.txt'
local renamed = root .. '/sub dir/renamed,4.txt'
local renamed_base = tmp .. '/base/old name.txt'
local renamed_lines, renamed_base_lines = {}, {}
for i = 1, 60 do
  renamed_lines[i] = 'r ' .. i
  renamed_base_lines[i] = i == 40 and 'was 40' or ('r ' .. i)
end
write(added, vim.split(('a\n'):rep(30), '\n', { trimempty = true }))
write(renamed, renamed_lines)
write(renamed_base, renamed_base_lines)
local changes = {
  { status = 'modified', name = 'main #2.txt', path = work, base = base },
  { status = 'added', name = 'new %3.txt', path = added },
  { status = 'renamed', name = 'sub dir/renamed,4.txt', path = renamed, base = renamed_base },
}

local function launch(manifest, keys)
  local out = tmp .. '/probe.json'
  vim.fn.delete(out)
  local env = {
    NVIM_APPNAME = 'astro-editor',
    XDG_CONFIG_HOME = xdg .. '/config',
    XDG_DATA_HOME = xdg .. '/data',
    XDG_STATE_HOME = xdg .. '/state',
    XDG_CACHE_HOME = xdg .. '/cache',
    PROBE_OUT = out,
    PROBE_KEYS = vim.json.encode(keys or {}),
  }
  if manifest then
    env.ASTRO_EDITOR_MANIFEST = tmp .. '/manifest.json'
    vim.fn.writefile({ vim.json.encode(manifest) }, env.ASTRO_EDITOR_MANIFEST)
  end
  local res = vim.system({
    vim.v.progpath, '--headless',
    '--cmd', 'set rtp^=' .. repo:gsub('[ ,\\]', '\\%0'),
    '-c', 'luafile ' .. vim.fn.fnameescape(repo .. '/tests/probe.lua'),
  }, { env = env, cwd = tmp, text = true }):wait(20000)
  assert(vim.fn.filereadable(out) == 1, 'no probe output; stderr: ' .. (res.stderr or ''))
  return vim.json.decode(table.concat(vim.fn.readfile(out), '\n'))
end

local function case(name, manifest, check, keys)
  local ok, err = pcall(function()
    local s = launch(manifest, keys)
    assert(s.user_init and s.user_plugin, 'AstroEditor config or user plugin not loaded')
    assert(not s.person_nvim_config, "the person's own nvim config was loaded")
    assert(s.manifest_env == vim.NIL, 'ASTRO_EDITOR_MANIFEST left in the environment')
    check(s)
  end)
  io.write((ok and 'ok   ' or 'FAIL ') .. name .. (ok and '' or ('\n     ' .. tostring(err))) .. '\n')
  if not ok then
    failures = failures + 1
  end
end

local function eq(want, got, what)
  assert(want == got, ('%s: want %s, got %s'):format(what, vim.inspect(want), vim.inspect(got)))
end

case('no manifest: plain Neovim', nil, function(s)
  eq('', s.buf, 'buffer')
  eq('', s.errmsg, 'errmsg')
end)

case('files: opens the folder', { version = 1, kind = 'files', root = root }, function(s)
  eq(vim.uv.fs_realpath(root), vim.uv.fs_realpath(s.cwd), 'cwd')
  eq('netrw', s.filetype, 'filetype')
end)

case('file: opens at the requested line', { version = 1, kind = 'file', path = notes, line = 37 }, function(s)
  eq(notes, s.buf, 'buffer')
  eq(37, s.line, 'line')
  eq('text', s.filetype, 'filetype detected')
end)

case('file: line past the end lands on the last line', { version = 1, kind = 'file', path = notes, line = 999 }, function(s)
  eq(50, s.line, 'line')
end)

case('diff: whole-file diff with native motions', { version = 1, kind = 'diff', path = work, base = base }, function(s)
  eq(2, #s.windows, 'windows')
  eq(base, s.windows[1].name, 'left window')
  eq(work, s.windows[2].name, 'right window')
  assert(s.windows[1].diff and s.windows[2].diff, 'both windows in diff mode')
  eq(false, s.windows[1].modifiable, 'base modifiable')
  eq(true, s.windows[2].modifiable, 'work modifiable')
  eq(work, s.buf, 'current buffer')
  eq(120, s.hunk_line, ']c lands on the hunk')
  eq(200, s.end_line, 'G reaches the end of the file')
  eq(200, s.line_count, 'whole file loaded')
end)

-- Windows of the tab as { name, type, diff, modifiable } rows.
local function layout(windows)
  local rows = {}
  for i, w in ipairs(windows) do
    rows[i] = { w.name, w.type, w.diff, w.modifiable }
  end
  return vim.inspect(rows)
end

local function diff_layout(left, right)
  return layout({
    { name = left, type = '', diff = true, modifiable = false },
    { name = right, type = '', diff = true, modifiable = true },
    { name = '', type = 'quickfix', diff = false, modifiable = false },
  })
end

case('changes: quickfix list of changed files, each a whole-file diff', { version = 1, kind = 'changes', changes = changes }, function(s)
  eq('AstroEditor changes', s.qf.title, 'quickfix title')
  eq(3, #s.qf.items, 'quickfix entries')
  for i, c in ipairs(changes) do
    eq(c.name, s.qf.items[i].module, 'entry ' .. i .. ' name')
    eq(c.status, s.qf.items[i].text, 'entry ' .. i .. ' status')
  end
  eq('', s.errmsg, 'errmsg')
  eq(work, s.buf, 'first change open')
  eq(diff_layout(base, work), layout(s.windows), 'first change layout')
  eq(120, s.hunk_line, ']c lands on the hunk')
  eq(200, s.end_line, 'G reaches the end of the file')
  local want = {
    { buf = added, idx = 2, base = '', count = 30 },
    { buf = renamed, idx = 3, base = renamed_base, count = 60 },
    { buf = renamed, idx = 3, base = renamed_base, line = 40 },
    { buf = renamed, idx = 3, base = renamed_base, line = 60 },
    { buf = added, idx = 2, base = '', line = 1 },
    { buf = work, idx = 1, base = base, line = 1 },
    { buf = work, idx = 1, base = base, line = 120 },
    { buf = work, idx = 1, base = base, line = 200, count = 200 },
  }
  eq(#want, #s.steps, 'steps')
  for i, w in ipairs(want) do
    local got = s.steps[i]
    local what = 'after ' .. got.keys
    eq('', got.errmsg, what .. ': errmsg')
    eq(w.buf, got.buf, what .. ': buffer')
    eq(w.idx, got.qf_idx, what .. ': quickfix entry')
    eq(diff_layout(w.base, w.buf), layout(got.windows), what .. ': layout')
    eq(w.line or 1, got.line, what .. ': line')
    if w.count then
      eq(w.count, got.line_count, what .. ': whole file loaded')
    end
  end
end, {
  ']q', -- next change: added file against an empty buffer
  ']q', -- next change: renamed file against its base
  ']c', -- the renamed file's hunk
  'G', -- its end
  '<C-w>h[q', -- previous change, jumping from the base window
  '<C-w>bgg<CR>', -- first entry picked in the quickfix window
  ']c',
  'G',
})

for _, bad in ipairs({
  { why = 'relative path', m = { version = 1, kind = 'file', path = 'notes.txt' }, msg = 'path must be an absolute path' },
  { why = 'missing file', m = { version = 1, kind = 'diff', path = work, base = tmp .. '/nope' }, msg = 'cannot open base' },
  { why = 'unknown kind', m = { version = 1, kind = 'pr' }, msg = 'unknown kind' },
  { why = 'wrong version', m = { version = 2, kind = 'files', root = root }, msg = 'unsupported manifest version' },
  { why = 'bad line', m = { version = 1, kind = 'file', path = notes, line = 0 }, msg = 'line must be a positive integer' },
  { why = 'empty change list', m = { version = 1, kind = 'changes', changes = {} }, msg = 'changes must be a non-empty list' },
  { why = 'unknown status', m = { version = 1, kind = 'changes', changes = { { status = 'copied', name = 'x', path = work, base = base } } }, msg = 'changes[1].status not supported: copied' },
  { why = 'deleted with a path', m = { version = 1, kind = 'changes', changes = { { status = 'deleted', name = 'gone.txt', path = work, base = base } } }, msg = 'changes[1].path must be omitted' },
  { why = 'deleted without base', m = { version = 1, kind = 'changes', changes = { { status = 'deleted', name = 'gone.txt' } } }, msg = 'changes[1].base must be an absolute path' },
  { why = 'name with a newline', m = { version = 1, kind = 'changes', changes = { { status = 'added', name = 'a\nb', path = added } } }, msg = 'changes[1].name must be non-empty text' },
  { why = 'missing changed file', m = { version = 1, kind = 'changes', changes = { changes[1], { status = 'added', name = 'nope', path = tmp .. '/nope' } } }, msg = 'cannot open changes[2].path' },
  { why = 'modified without base', m = { version = 1, kind = 'changes', changes = { { status = 'modified', name = 'x', path = added } } }, msg = 'changes[1].base must be an absolute path' },
  { why = 'added with base', m = { version = 1, kind = 'changes', changes = { { status = 'added', name = 'x', path = added, base = base } } }, msg = 'changes[1].base must be omitted' },
  { why = 'repeated file', m = { version = 1, kind = 'changes', changes = { changes[1], changes[1] } }, msg = 'changes[2].path repeats a file' },
}) do
  case('refuses ' .. bad.why, bad.m, function(s)
    assert(s.errmsg:find('astro-editor: ' .. bad.msg, 1, true), 'errmsg: ' .. s.errmsg)
    eq('', s.buf, 'buffer')
    eq(1, #s.windows, 'windows')
  end)
end

-- A mixed list: a deleted file is compared with an empty read-only side that
-- is no file, and an explicit null base on an added file means no base.
local gone = { status = 'deleted', name = 'gone.txt', base = renamed_base }
local mixed = {
  { status = 'added', name = 'new %3.txt', path = added, base = vim.NIL },
  gone,
  changes[1],
}

local function deleted_layout(left)
  return layout({
    { name = left, type = '', diff = true, modifiable = false },
    { name = '', type = 'quickfix', diff = false, modifiable = false },
  })
end

case('changes: deleted file against an empty read-only side', { version = 1, kind = 'changes', changes = mixed }, function(s)
  eq('', s.errmsg, 'errmsg')
  eq(3, #s.qf.items, 'quickfix entries')
  eq('deleted', s.qf.items[2].text, 'entry 2 status')
  eq(added, s.buf, 'first change open')
  eq(diff_layout('', added), layout(s.windows), 'added file against an empty buffer')
  local want = {
    { buf = '', idx = 2, left = renamed_base, lines = 60 },
    { buf = work, idx = 3, left = base, lines = 200 },
    { buf = '', idx = 2, left = renamed_base, lines = 60 },
  }
  eq(#want, #s.steps, 'steps')
  for i, w in ipairs(want) do
    local got = s.steps[i]
    local what = 'after ' .. got.keys
    eq('', got.errmsg, what .. ': errmsg')
    eq(w.idx, got.qf_idx, what .. ': quickfix entry')
    eq(w.buf, got.buf, what .. ': buffer')
    local right = { name = w.buf, type = '', diff = true, modifiable = w.buf ~= '' }
    eq(layout({
      { name = w.left, type = '', diff = true, modifiable = false },
      right,
      { name = '', type = 'quickfix', diff = false, modifiable = false },
    }), layout(got.windows), what .. ': layout')
    eq(w.lines, got.left_lines, what .. ': whole base file shown')
  end
  eq(vim.inspect(renamed_base_lines), vim.inspect(vim.fn.readfile(renamed_base)), 'base file untouched')
end, { ']q', ']q', '[q' })

-- Showing a listed file by any means but a quickfix jump keeps the windows
-- the person asked for.
local function names(windows)
  local list = {}
  for i, w in ipairs(windows) do
    list[i] = w.name .. (w.type ~= '' and ('<' .. w.type .. '>') or '')
  end
  return table.concat(list, '|')
end

case('changes: split, edit and alternate buffer are not quickfix jumps', { version = 1, kind = 'changes', changes = changes }, function(s)
  eq(5, #s.steps, 'steps')
  local function wins(i)
    return names(s.steps[i].windows)
  end
  eq(base .. '|' .. work .. '|' .. '<quickfix>', names(s.windows), 'initial layout')
  eq(base .. '|' .. work .. '|' .. work .. '|<quickfix>', wins(1), ':vsplit keeps the new window')
  eq(work, s.steps[1].buf, ':vsplit current buffer')
  eq(4, #s.steps[1].windows, ':vsplit window count')
  eq(base .. '|' .. work .. '|' .. '<quickfix>', wins(2), 'after closing the split')
  eq(added, s.steps[3].buf, ':edit another listed file')
  eq(1, s.steps[3].qf_idx, ':edit does not move the quickfix list')
  eq(3, #s.steps[3].windows, ':edit keeps the layout')
  eq(base, s.steps[3].windows[1].name, ':edit leaves the diff base')
  eq(work, s.steps[4].buf, '<C-^> returns to the first file')
  eq(3, #s.steps[4].windows, '<C-^> keeps the layout')
  eq(2, s.steps[5].qf_idx, ':cc 2 is a quickfix jump')
  eq(added, s.steps[5].buf, ':cc 2 opens the entry')
  eq(diff_layout('', added), layout(s.steps[5].windows), ':cc 2 shows its diff')
end, {
  ':vsplit<CR>',
  ':close<CR>',
  ':edit ' .. vim.fn.fnameescape(added) .. '<CR>',
  '<C-^>',
  ':cc 2<CR>',
})

vim.fn.delete(tmp, 'rf')
if failures > 0 then
  io.write(failures .. ' failed\n')
  os.exit(1)
end
io.write('all passed\n')
