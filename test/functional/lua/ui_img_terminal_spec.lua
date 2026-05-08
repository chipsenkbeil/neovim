local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local clear = n.clear
local exec_lua = n.exec_lua
local eq = t.eq
local matches = t.matches

describe('vim.ui.img._terminal', function()
  before_each(clear)

  it('starts with empty per-buffer state and clears it on cleanup', function()
    local result = exec_lua([[
      local M = require('vim.ui.img._terminal')
      local fake_buf = 42
      -- Touch state so cleanup has something to clear
      M._state[fake_buf] = { ids = {}, placements = {}, chunks = {} }
      M.cleanup(fake_buf)
      return M._state[fake_buf]
    ]])
    eq(vim.NIL, result)
  end)

  it('cleanup is a no-op for unknown buffers', function()
    local ok = exec_lua([[
      require('vim.ui.img._terminal').cleanup(99999)
      return true
    ]])
    eq(true, ok)
  end)

  it('cleanup deletes every tracked image', function()
    local deleted = exec_lua([[
      local M = require('vim.ui.img._terminal')
      local deleted = {}
      vim.ui.img.del = function(id) deleted[#deleted+1] = id; return true end
      M._state[42] = { ids = { ['1'] = 100, ['2'] = 200 }, placements = {}, chunks = {}, data = {} }
      M.cleanup(42)
      table.sort(deleted)
      return deleted
    ]])
    eq({ 100, 200 }, deleted)
  end)

  it('cleanup clears half-received chunked transmissions', function()
    local cleared = exec_lua([[
      local M = require('vim.ui.img._terminal')
      M._reassemble(42, { i = '5', m = '1' }, 'AAAA')
      -- chunk in flight
      local before = M._state[42] and M._state[42].chunks[5]
      M.cleanup(42)
      return { had_chunk = before ~= nil, state_cleared = M._state[42] == nil }
    ]])
    eq(true, cleared.had_chunk)
    eq(true, cleared.state_cleared)
  end)

  describe('parse_apc', function()
    it('parses key=value pairs and base64 payload', function()
      local result = exec_lua([[
        local M = require('vim.ui.img._terminal')
        return M._parse_apc('a=T,f=100,i=1,m=1;SGVsbG8=')
      ]])
      eq({ a = 'T', f = '100', i = '1', m = '1' }, result.keys)
      eq('SGVsbG8=', result.payload)
    end)

    it('parses keys with no payload', function()
      local result = exec_lua([[
        return require('vim.ui.img._terminal')._parse_apc('a=q,i=1,s=1,v=1')
      ]])
      eq({ a = 'q', i = '1', s = '1', v = '1' }, result.keys)
      eq('', result.payload)
    end)

    it('parses payload-only sequences', function()
      local result = exec_lua([[
        return require('vim.ui.img._terminal')._parse_apc(';SGVsbG8=')
      ]])
      eq({}, result.keys)
      eq('SGVsbG8=', result.payload)
    end)

    it('returns nil for malformed input', function()
      local result = exec_lua([[
        return require('vim.ui.img._terminal')._parse_apc('this is not a kitty seq')
      ]])
      eq(vim.NIL, result)
    end)

    it('rejects multi-char key names', function()
      eq(vim.NIL, exec_lua([[ return require('vim.ui.img._terminal')._parse_apc('aa=T') ]]))
    end)

    it('rejects key with no value', function()
      eq(vim.NIL, exec_lua([[ return require('vim.ui.img._terminal')._parse_apc('a=,i=1') ]]))
    end)
  end)

  describe('reassemble', function()
    it('returns the payload immediately when m is absent', function()
      local data = exec_lua([[
        local M = require('vim.ui.img._terminal')
        return M._reassemble(1, { i = '1', f = '100' }, 'AAAA')
      ]])
      -- vim.base64 decodes "AAAA" to four NUL bytes.
      eq(string.rep('\0', 3), data)
    end)

    it('accumulates m=1 chunks and finalizes on m=0', function()
      local data = exec_lua([[
        local M = require('vim.ui.img._terminal')
        local r1 = M._reassemble(1, { i = '7', m = '1' }, 'AAAA')
        local r2 = M._reassemble(1, { i = '7', m = '1' }, 'AAAA')
        local r3 = M._reassemble(1, { i = '7', m = '0' }, 'AAAA')
        return { r1, r2, r3 }
      ]])
      eq(vim.NIL, data[1])
      eq(vim.NIL, data[2])
      eq(string.rep('\0', 9), data[3])
    end)

    it('keeps separate chunk buffers per image id', function()
      local data = exec_lua([[
        local M = require('vim.ui.img._terminal')
        M._reassemble(1, { i = '1', m = '1' }, 'AAAA')
        M._reassemble(1, { i = '2', m = '1' }, 'AAAA')
        local r = M._reassemble(1, { i = '1', m = '0' }, 'AAAA')
        return r
      ]])
      eq(string.rep('\0', 6), data)
    end)
  end)

  describe('cursor unpacking', function()
    it('unpacks cursor[1]/[2] and converts col 0-indexed → 1-indexed', function()
      local result = exec_lua([[
        local M = require('vim.ui.img._terminal')
        return { M._cursor_pos({ 42, 7 }) }
      ]])
      eq(42, result[1])
      eq(8, result[2]) -- col 7 (0-indexed) → 8 (1-indexed)
    end)

    it('clamps row <= 0 (cursor scrolled out of buffer) to row 1', function()
      local line = exec_lua([[
        return (require('vim.ui.img._terminal')._cursor_pos({ 0, 0 }))
      ]])
      eq(1, line)
    end)

    it('clamps row < 0 to row 1', function()
      local line = exec_lua([[
        return (require('vim.ui.img._terminal')._cursor_pos({ -5, 0 }))
      ]])
      eq(1, line)
    end)
  end)

  describe('dispatch routing', function()
    it('routes a=T to the place handler with reassembled data', function()
      local actions = exec_lua([[
        local M = require('vim.ui.img._terminal')
        local seen = {}
        M._handlers = {
          t = function(buf, keys, data) seen[#seen+1] = { 't', buf, keys.i, #data } end,
          T = function(buf, keys, data, cursor) seen[#seen+1] = { 'T', buf, keys.i, #data, cursor[1] } end,
          p = function(buf, keys, cursor) seen[#seen+1] = { 'p', buf, keys.i, cursor[1] } end,
          d = function(buf, keys) seen[#seen+1] = { 'd', buf, keys.i, keys.d } end,
          q = function(buf, keys) seen[#seen+1] = { 'q', buf, keys.i } end,
        }
        local buf = vim.api.nvim_create_buf(false, true)
        M.dispatch(buf, '\27_Ga=T,f=100,i=42;AAAA', { 1, 0 })
        return seen
      ]])
      eq(1, #actions)
      eq('T', actions[1][1])
      eq('42', actions[1][3])
      eq(3, actions[1][4]) -- "AAAA" decodes to 3 bytes
    end)

    it('ignores sequences that are not kitty graphics', function()
      local seen = exec_lua([[
        local M = require('vim.ui.img._terminal')
        local count = 0
        M._handlers = setmetatable({}, { __index = function() return function() count = count + 1 end end })
        local buf = vim.api.nvim_create_buf(false, true)
        M.dispatch(buf, '\27]7;file:///tmp\27\\', { 1, 0 })
        return count
      ]])
      eq(0, seen)
    end)

    it('does not call any handler while m=1 chunks are still pending', function()
      local count = exec_lua([[
        local M = require('vim.ui.img._terminal')
        local n = 0
        M._handlers = setmetatable({}, { __index = function() return function() n = n + 1 end end })
        local buf = vim.api.nvim_create_buf(false, true)
        M.dispatch(buf, '\27_Ga=T,f=100,i=1,m=1;AAAA', { 1, 0 })
        return n
      ]])
      eq(0, count)
    end)
  end)

  describe('a=t transmission', function()
    it('stores reassembled image data under the kitty id', function()
      local stored = exec_lua([[
        local M = require('vim.ui.img._terminal')
        local buf = vim.api.nvim_create_buf(false, true)
        M.dispatch(buf, '\27_Ga=t,f=100,i=99;AAAA', { 1, 0 })
        return M._state[buf].data['99']
      ]])
      -- "AAAA" base64 → 3 NUL bytes
      eq(string.rep('\0', 3), stored)
    end)
  end)

  describe('a=T and a=p placement', function()
    -- We mock vim.ui.img.set to record what was passed and return a fake id.
    local function with_img_mock(body)
      return exec_lua([[
        local M = require('vim.ui.img._terminal')
        local calls = {}
        local fake_id = 1000
        local orig_set = vim.ui.img.set
        vim.ui.img.set = function(data, opts)
          calls[#calls+1] = { data = data, opts = opts }
          fake_id = fake_id + 1
          return fake_id
        end
        local buf = vim.api.nvim_create_buf(false, true)
        for i = 1, 24 do vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '' }) end
        local win = vim.api.nvim_open_win(buf, false, { relative='editor', row=0, col=0, width=40, height=24 })
        ]] .. body .. [[
        vim.ui.img.set = orig_set
        vim.api.nvim_win_close(win, true)
        return { calls = calls, state = M._state[buf] }
      ]])
    end

    it('a=T calls vim.ui.img.set with relative=buffer and tracks the id', function()
      local r = with_img_mock([[
        M.dispatch(buf, '\27_Ga=T,f=100,i=5,c=10,r=4,z=50;AAAA', { 4, 7 })
      ]])
      eq(1, #r.calls)
      local opts = r.calls[1].opts
      eq('buffer', opts.relative)
      eq(3, #r.calls[1].data) -- 3 NULs from "AAAA"
      eq(10, opts.width)
      eq(4, opts.height)
      eq(50, opts.zindex)
      -- The kitty id "5" maps to a vim.ui.img id, tracked in s.ids.
      eq(1001, r.state.ids['5'])
    end)

    it('a=p reuses a previously transmitted image without retransmission', function()
      local r = with_img_mock([[
        M.dispatch(buf, '\27_Ga=t,f=100,i=5;AAAA', { 1, 0 })
        M.dispatch(buf, '\27_Ga=p,i=5,c=10,r=4', { 4, 7 })
      ]])
      -- Only one set() call: the placement re-uses stored data.
      eq(1, #r.calls)
      eq(3, #r.calls[1].data)
    end)

    it('a=p is a no-op when the image was never transmitted', function()
      local r = with_img_mock([[
        M.dispatch(buf, '\27_Ga=p,i=999,c=10,r=4', { 4, 7 })
      ]])
      eq(0, #r.calls)
    end)
  end)

  describe('a=d deletion', function()
    local function with_img_mock(body)
      return exec_lua([[
        local M = require('vim.ui.img._terminal')
        local placed, deleted = {}, {}
        local id_counter = 1000
        local orig_set, orig_del = vim.ui.img.set, vim.ui.img.del
        vim.ui.img.set = function(data, opts)
          id_counter = id_counter + 1
          placed[#placed+1] = id_counter
          return id_counter
        end
        vim.ui.img.del = function(id) deleted[#deleted+1] = id; return true end
        local buf = vim.api.nvim_create_buf(false, true)
        local win = vim.api.nvim_open_win(buf, false, { relative='editor', row=0, col=0, width=40, height=24 })
        for i = 1, 24 do vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '' }) end
        ]] .. body .. [[
        vim.ui.img.set, vim.ui.img.del = orig_set, orig_del
        vim.api.nvim_win_close(win, true)
        return { placed = placed, deleted = deleted, state = M._state[buf] }
      ]])
    end

    it('d=i deletes by image id', function()
      local r = with_img_mock([[
        M.dispatch(buf, '\27_Ga=T,f=100,i=5,c=1,r=1;AAAA', { 1, 0 })
        M.dispatch(buf, '\27_Ga=T,f=100,i=6,c=1,r=1;AAAA', { 1, 0 })
        M.dispatch(buf, '\27_Ga=d,d=i,i=5', { 1, 0 })
      ]])
      eq({ 1001 }, r.deleted)
      eq(nil, r.state.ids['5'])
      eq(1002, r.state.ids['6'])
    end)

    it('d=p deletes by placement id', function()
      local r = with_img_mock([[
        M.dispatch(buf, '\27_Ga=T,f=100,i=5,p=77,c=1,r=1;AAAA', { 1, 0 })
        M.dispatch(buf, '\27_Ga=d,d=p,p=77', { 1, 0 })
      ]])
      eq({ 1001 }, r.deleted)
      eq(nil, r.state.placements['77'])
    end)

    it('d=A deletes every placement we issued for this buffer', function()
      local r = with_img_mock([[
        M.dispatch(buf, '\27_Ga=T,f=100,i=5,c=1,r=1;AAAA', { 1, 0 })
        M.dispatch(buf, '\27_Ga=T,f=100,i=6,c=1,r=1;AAAA', { 1, 0 })
        M.dispatch(buf, '\27_Ga=d,d=A', { 1, 0 })
      ]])
      eq(2, #r.deleted)
      eq(nil, next(r.state.ids))
      eq(nil, next(r.state.placements))
    end)

    it('d=i for an unknown id is silent', function()
      local r = with_img_mock([[
        M.dispatch(buf, '\27_Ga=d,d=i,i=999', { 1, 0 })
      ]])
      eq({}, r.deleted)
    end)
  end)

  describe('chafa-style chunked transmission', function()
    -- chafa emits a header chunk with metadata only (no payload, no ';'),
    -- followed by m=1 continuation chunks with only base64, then m=0 finalizer.
    it('routes a=T to the place handler after all continuation chunks arrive', function()
      local placed = exec_lua([[
        local M = require('vim.ui.img._terminal')
        local calls = {}
        vim.ui.img.set = function(data, opts)
          table.insert(calls, { data = data, opts = opts })
          return 9999
        end
        local buf = vim.api.nvim_create_buf(false, true)
        for i = 1, 24 do vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '' }) end
        local win = vim.api.nvim_open_win(buf, false, { relative='editor', row=0, col=0, width=40, height=24 })

        -- Header: action + dimensions, m=1, no payload
        M.dispatch(buf, '\27_Ga=T,f=32,s=4,v=1,c=2,r=1,m=1,q=2', { 1, 0 })
        -- Continuation: m=1 with payload (base64 "AAAA" = 3 NUL bytes per chunk)
        M.dispatch(buf, '\27_Gm=1;AAAA', { 1, 0 })
        M.dispatch(buf, '\27_Gm=1;AAAA', { 1, 0 })
        -- Finalizer: m=0 with last payload
        M.dispatch(buf, '\27_Gm=0;AAAA', { 1, 0 })

        vim.api.nvim_win_close(win, true)
        return calls
      ]])
      eq(1, #placed)
      -- vim.ui.img.set only accepts PNG; raw RGBA from kitty f=32 is
      -- converted to PNG by our handler before being passed.
      eq('\137PNG\r\n\26\n', placed[1].data:sub(1, 8))
      -- format / pixel dims are absorbed by the conversion; not on opts.
      eq(nil, placed[1].opts.format)
      eq(nil, placed[1].opts.pixel_width)
      eq(nil, placed[1].opts.pixel_height)
      eq(2, placed[1].opts.width)   -- c=2 cells
      eq(1, placed[1].opts.height)  -- r=1 cells
    end)

    it('continuations without i= associate with the first chunk that had i=', function()
      -- Programs commonly put `i=` on the first chunk and omit it on
      -- continuations. Continuations should still feed the in-flight
      -- transmission rather than being treated as orphans.
      local placed = exec_lua([[
        local M = require('vim.ui.img._terminal')
        local calls = {}
        vim.ui.img.set = function(data, opts)
          table.insert(calls, { data = data, opts = opts })
          return 7777
        end
        local buf = vim.api.nvim_create_buf(false, true)
        for i = 1, 24 do vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '' }) end
        local win = vim.api.nvim_open_win(buf, false, { relative='editor', row=0, col=0, width=40, height=24 })

        -- First chunk: a=T with i=42 and a tiny payload, m=1
        M.dispatch(buf, '\27_Ga=T,f=100,t=d,i=42,c=2,r=1,m=1;AAAA', { 1, 0 })
        -- Continuations omit i= (the standard pattern).
        M.dispatch(buf, '\27_Gm=1;AAAA', { 1, 0 })
        M.dispatch(buf, '\27_Gm=0;AAAA', { 1, 0 })

        vim.api.nvim_win_close(win, true)
        return { calls = calls, ids = M._state[buf].ids }
      ]])
      eq(1, #placed.calls)
      -- 3 chunks of "AAAA" (the first chunk's payload + 2 continuations) = 9 bytes
      eq(9, #placed.calls[1].data)
      eq(7777, placed.ids['42'])
    end)

    it('discards continuation chunks for which no first-chunk metadata was seen', function()
      local placed = exec_lua([[
        local M = require('vim.ui.img._terminal')
        local calls = {}
        vim.ui.img.set = function(data, opts) table.insert(calls, { data = data, opts = opts }); return 1 end
        local buf = vim.api.nvim_create_buf(false, true)
        -- No header chunk; just orphaned continuations
        M.dispatch(buf, '\27_Gm=1;AAAA', { 1, 0 })
        M.dispatch(buf, '\27_Gm=0;AAAA', { 1, 0 })
        return calls
      ]])
      eq({}, placed)
    end)
  end)

  describe('a=q query reply forging', function()
    local function with_chan_mock(body)
      return exec_lua([[
        local M = require('vim.ui.img._terminal')
        local sent = {}
        local orig = vim.api.nvim_chan_send
        vim.api.nvim_chan_send = function(chan, bytes) sent[#sent+1] = { chan, bytes }; return true end
        local orig_supported = vim.ui.img._supported
        vim.ui.img._supported = function() return true end
        M._reset_supported_cache()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.b[buf].terminal_job_id = 7
        ]] .. body .. [[
        vim.api.nvim_chan_send = orig
        vim.ui.img._supported = orig_supported
        return sent
      ]])
    end

    it('responds to a=q with OK when image display is supported', function()
      local sent = with_chan_mock([[
        M.dispatch(buf, '\27_Ga=q,i=42,s=1,v=1', { 1, 0 })
      ]])
      eq(1, #sent)
      eq(7, sent[1][1])
      matches('\27_Gi=42;OK\27\\', sent[1][2], true)
    end)

    it('q=2 on a=t suppresses the OK reply', function()
      local sent = with_chan_mock([[
        M.dispatch(buf, '\27_Ga=t,f=100,i=8,q=2;AAAA', { 1, 0 })
      ]])
      eq({}, sent)
    end)

    it('q=1 suppresses OK replies but errors would still go through', function()
      local sent = with_chan_mock([[
        M.dispatch(buf, '\27_Ga=t,f=100,i=8,q=1;AAAA', { 1, 0 })
      ]])
      eq({}, sent)
    end)

    it('forges ENOTSUPP when the host has no image support', function()
      local sent = exec_lua([[
        local M = require('vim.ui.img._terminal')
        local sent = {}
        vim.api.nvim_chan_send = function(_, bytes) sent[#sent+1] = bytes; return true end
        vim.ui.img._supported = function() return false end
        M._reset_supported_cache()
        -- Force ext_images off too.
        local buf = vim.api.nvim_create_buf(false, true)
        vim.b[buf].terminal_job_id = 7
        M.dispatch(buf, '\27_Ga=q,i=1,s=1,v=1', { 1, 0 })
        return sent
      ]])
      eq(1, #sent)
      matches('ENOTSUPP', sent[1], true)
    end)
  end)
end)
