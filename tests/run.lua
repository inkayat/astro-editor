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

-- Context fixtures: a file to capture from and the destinations AstroApp
-- declares. No worktree agent is declared, so it stays unavailable.
local ctx_file = root .. '/ctx #5.txt'
write(ctx_file, { 'one', 'two', 'three' })
local destinations = {
  { id = 'firstmate', label = 'Firstmate' },
  { id = 'primary', label = 'Primary Assistant' },
}

-- A context object with `over` replacing its fields.
local function ctx_with(over)
  return { version = 1, kind = 'file', path = ctx_file, context = vim.tbl_extend('force', { outbox = root, destinations = destinations }, over) }
end

-- A `file` manifest for ctx_file whose context names a fresh, empty outbox.
local outboxes = 0
local function ctx_manifest()
  outboxes = outboxes + 1
  local outbox = ('%s/outbox %%#%d'):format(root, outboxes)
  vim.fn.mkdir(outbox, 'p')
  return ctx_with({ outbox = outbox }), outbox
end

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
  { why = 'relative outbox', m = ctx_with({ outbox = 'out' }), msg = 'context.outbox must be an absolute path' },
  { why = 'missing outbox', m = ctx_with({ outbox = tmp .. '/nope' }), msg = 'cannot open context.outbox' },
  { why = 'no destinations', m = ctx_with({ destinations = {} }), msg = 'context.destinations must be a list of 1 to 16' },
  { why = 'too many destinations', m = ctx_with({ destinations = vim.tbl_map(function(i)
    return { id = 'd' .. i, label = 'D' .. i }
  end, vim.fn.range(17)) }), msg = 'context.destinations must be a list of 1 to 16' },
  { why = 'destination id with a slash', m = ctx_with({ destinations = { { id = '../x', label = 'X' } } }), msg = 'context.destinations[1].id must be' },
  { why = 'repeated destination', m = ctx_with({ destinations = { destinations[1], destinations[1] } }), msg = 'context.destinations[2].id repeats firstmate' },
  { why = 'destination label with a newline', m = ctx_with({ destinations = { { id = 'a', label = 'a\nb' } } }), msg = 'context.destinations[1].label must be' },
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

-- The synthetic consumer: AstroApp's side of the outbox. Returns the messages
-- by send order; every entry must be one whole, private message for a
-- destination the launch declared.
local function consume(outbox)
  local declared = {}
  for _, d in ipairs(destinations) do
    declared[d.id] = true
  end
  local got = {}
  for _, name in ipairs(vim.fn.readdir(outbox)) do
    local seq = name:match('^context%-%d+%-%d+%-(%d+)%.json$')
    assert(seq, 'unexpected outbox entry: ' .. name)
    local file = outbox .. '/' .. name
    eq(tonumber('600', 8), bit.band(vim.uv.fs_stat(file).mode, tonumber('777', 8)), name .. ' permissions')
    local m = vim.json.decode(table.concat(vim.fn.readfile(file), '\n'))
    assert(declared[m.destination], name .. ': undeclared destination ' .. tostring(m.destination))
    got[tonumber(seq)] = m
  end
  return got
end

local ctx, ctx_outbox = ctx_manifest()
case('context: sends the unsaved selection or location after an explicit Send', ctx, function(s)
  local sent_to = { 'Primary Assistant', 'Firstmate', 'Primary Assistant' }
  eq(#sent_to, #s.steps, 'steps')
  for i, step in ipairs(s.steps) do
    eq('', step.errmsg, 'step ' .. i .. ' errmsg')
    eq('astro-editor: context sent to ' .. sent_to[i], step.message, 'step ' .. i .. ' message')
  end
  local got = consume(ctx_outbox)
  eq(#sent_to, vim.tbl_count(got), 'one message per confirmed send')
  local function want(fields)
    return vim.inspect(vim.tbl_extend('error', { version = 1, path = ctx_file, filetype = 'text', modified = true }, fields))
  end
  eq(want({ destination = 'primary', kind = 'selection', line = 1, end_line = 2, text = 'ONE\ntw', note = 'look at "this" %s' }), vim.inspect(got[1]), 'charwise selection')
  eq(want({ destination = 'firstmate', kind = 'location', line = 3, col = 2, text = 'three', note = '' }), vim.inspect(got[2]), 'location')
  eq(want({ destination = 'primary', kind = 'selection', line = 2, end_line = 3, text = 'two\nthree', note = 'N' }), vim.inspect(got[3]), 'range')
  eq(vim.inspect({ 'one', 'two', 'three' }), vim.inspect(vim.fn.readfile(ctx_file)), 'file on disk untouched')
end, {
  'ggcwONE<Esc>0vjl:AstroContext<CR>2<CR>look at "this" %s<CR>1<CR>', -- pick a destination, note, Send
  'Gl:AstroContext firstmate<CR><CR>1<CR>', -- named destination, no note, Send
  ':2,3AstroContext primary<CR>N<CR>1<CR>', -- a range that is not the visual selection
})

local quiet, quiet_outbox = ctx_manifest()
case('context: nothing sent without an explicit Send', quiet, function(s)
  local refused = {
    [7] = 'destination not available: worktree-agent',
    [8] = 'location too large to send: 70000 bytes, limit 65536',
  }
  eq(8, #s.steps, 'steps')
  for i, step in ipairs(s.steps) do
    local what = 'after ' .. step.keys
    if refused[i] then
      eq('astro-editor: ' .. refused[i], step.errmsg, what .. ': errmsg')
    else
      eq('', step.errmsg, what .. ': errmsg')
      eq('astro-editor: context not sent', step.message, what .. ': message')
    end
  end
  eq(0, #vim.fn.readdir(quiet_outbox), 'outbox entries')
end, {
  ':AstroContext<CR><Esc>', -- Escape at the destination
  ':AstroContext<CR>9<CR>', -- a choice that is not in the list
  ':AstroContext<CR>1<CR><Esc>', -- Escape at the note
  ':AstroContext<CR>1<CR>note<CR><CR>', -- Enter alone at the confirmation
  ':AstroContext<CR>1<CR>note<CR>2<CR>', -- Cancel
  ':AstroContext<CR>1<CR>note<CR><Esc>', -- Escape at the confirmation
  ':AstroContext worktree-agent<CR>', -- a destination the launch did not declare
  ':call setline(1, repeat("x", 70000))<CR>:AstroContext firstmate<CR>', -- refused before any prompt
})

local gone, gone_outbox = ctx_manifest()
case('context: refuses once the outbox is gone', gone, function(s)
  eq('astro-editor: cannot send context to Firstmate: outbox is gone: ' .. gone_outbox, s.steps[1].errmsg, 'errmsg')
  eq(0, vim.fn.isdirectory(gone_outbox), 'outbox not recreated')
end, { (':lua vim.fn.delete(%q, "d")<CR>:AstroContext firstmate<CR><CR>1<CR>'):format(gone_outbox) })

case('context: refused when the launch declared no destinations', { version = 1, kind = 'file', path = ctx_file }, function(s)
  eq('astro-editor: no context destinations: AstroApp declared none for this launch', s.steps[1].errmsg, 'errmsg')
end, { ':AstroContext<CR>' })

vim.fn.delete(tmp, 'rf')
if failures > 0 then
  io.write(failures .. ' failed\n')
  os.exit(1)
end
io.write('all passed\n')
