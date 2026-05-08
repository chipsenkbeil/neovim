---Inbound dispatcher for kitty graphics protocol APC sequences emitted by
---programs running inside |:terminal|. Wired up by
---runtime/plugin/nvim.ui.img.lua.
local M = {}

---Per-buffer state, indexed by terminal bufnr.
---Cleared by M.cleanup on TermClose / BufWipeout.
---
---`pending` tracks in-flight chunked transmissions where only the first chunk
---carries the action+metadata (kitty graphics protocol). It is keyed by image
---key (`keys.i or '0'`).
---@type table<integer, { ids: table<string,integer>, placements: table<string,integer>, chunks: table<integer,string>, data: table<string,string>, pending: table<string, { keys: table<string,string>, cursor: integer[], b64: string }> }>
M._state = {}

---Cached result of host_supports_images(). vim.ui.img._supported can block
---the event loop for ~1.1s, so we only probe once. A program inside
---:terminal that issues repeated `a=q` queries would otherwise freeze nvim.
---@type boolean?
local supported_cache = nil

---@private
---Reset the cached host-supports-images result. Exposed for tests that stub
---vim.ui.img._supported between cases.
function M._reset_supported_cache()
  supported_cache = nil
end

---@return boolean
local function host_supports_images()
  if supported_cache ~= nil then
    return supported_cache
  end
  -- ext_images: any attached UI declares the capability.
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.ext_images then
      supported_cache = true
      return true
    end
  end
  -- Otherwise probe the host terminal (this blocks).
  local ok, supported = pcall(vim.ui.img._supported)
  supported_cache = ok and supported or false
  return supported_cache
end

---Drop all state for {buf} and reap any images we placed for it.
---@param buf integer
function M.cleanup(buf)
  local s = M._state[buf]
  if not s then
    return
  end
  for _, vim_ui_img_id in pairs(s.ids) do
    pcall(vim.ui.img.del, vim_ui_img_id)
  end
  M._state[buf] = nil
end

---Parse a kitty APC body into control keys and base64 payload.
---{body} is the bytes between the literal "\27_G" framing prefix and the
---trailing "\e\\" terminator — for kitty graphics, that means
---"<keys>;<payload>" where either side may be empty.
---@param body string
---@return { keys: table<string,string>, payload: string }? parsed, or nil if malformed
function M._parse_apc(body)
  if type(body) ~= 'string' or body == '' then
    return nil
  end
  local kv_part, payload = body:match('^([^;]*);?(.*)$')
  if not kv_part then
    return nil
  end
  local keys = {}
  if kv_part ~= '' then
    -- Each comma-separated chunk must look like k=v.
    local saw_pair = false
    for pair in (kv_part .. ','):gmatch('([^,]*),') do
      if pair ~= '' then
        local k, v = pair:match('^([%w])=(.+)$')
        if not k then
          return nil
        end
        keys[k] = v
        saw_pair = true
      end
    end
    if not saw_pair then
      return nil
    end
  end
  return { keys = keys, payload = payload or '' }
end

---@param buf integer
---@return { ids: table<string,integer>, placements: table<string,integer>, chunks: table<integer,string>, data: table<string,string>, pending: table<string, { keys: table<string,string>, cursor: integer[], b64: string }>, pending_key: string? }
local function bufstate(buf)
  local s = M._state[buf]
  if not s then
    s = { ids = {}, placements = {}, chunks = {}, data = {}, pending = {}, pending_key = nil }
    M._state[buf] = s
  end
  -- Backfill pending for state tables created before this field existed
  -- (e.g. tests touching _state directly).
  if not s.pending then
    s.pending = {}
  end
  return s
end

---Reassemble a chunked kitty transmission. Decodes the base64 payload
---once the transmission is complete.
---@param buf integer
---@param keys table<string,string>
---@param payload string base64 chunk
---@return string? data raw image bytes when reassembly is complete; nil while waiting
function M._reassemble(buf, keys, payload)
  local id = tonumber(keys.i) or 0
  local s = bufstate(buf)
  if keys.m == '1' then
    s.chunks[id] = (s.chunks[id] or '') .. payload
    return nil
  end
  -- m=0 or m absent: this is the final (or only) chunk.
  local full_b64 = (s.chunks[id] or '') .. payload
  s.chunks[id] = nil
  return vim.base64.decode(full_b64)
end

---Unpack TermRequest cursor and convert to vim.ui.img conventions.
---{cursor} is a 2-element array {row, col} as exposed by TermRequest:
---  • cursor[1]: 1-indexed buffer-relative line (already adjusted for
---    scrollback by the C side; may be <= 0 if scrolled out of buffer)
---  • cursor[2]: 0-indexed column
---vim.ui.img.set wants {row, col} both 1-indexed.
---@param cursor integer[]
---@return integer row 1-indexed buffer line (>= 1)
---@return integer col 1-indexed column
function M._cursor_pos(cursor)
  local row = cursor[1]
  if row < 1 then
    row = 1
  end
  local col = cursor[2] + 1
  return row, col
end

---Cached cell pixel size, queried from the host on first use. Programs running
---inside :terminal (e.g. yazi, mdcat, kitten icat) issue CSI 14t / 16t to
---learn cell dimensions before deciding whether to use kitty graphics; they
---fall back to ASCII when no reply arrives. We reflect the host's value.
---@type [integer, integer]?
local cell_px_cache = nil

---@private
---Reset cached cell pixel size (used by tests).
function M._reset_cell_px_cache()
  cell_px_cache = nil
end

---@return integer width_px
---@return integer height_px
local function host_cell_px()
  if cell_px_cache then
    return cell_px_cache[1], cell_px_cache[2]
  end
  -- Default fallback if the host doesn't respond. 8x16 is a common cell size
  -- and works as a sensible scaling baseline if probing fails.
  local w, h = 8, 16
  local done = false
  pcall(function()
    require('vim.tty').request('\27[16t', { timeout = 200 }, function(resp)
      local rh, rw = resp:match('^\27%[6;(%d+);(%d+)t')
      if rh and rw then
        h, w = tonumber(rh), tonumber(rw)
        done = true
        return true
      end
    end)
    vim.wait(200, function()
      return done
    end)
  end)
  cell_px_cache = { w, h }
  return w, h
end

---@param buf integer
---@param win_height_cells integer
---@param win_width_cells integer
---@return integer height_cells
---@return integer width_cells
local function buffer_window_cells(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win)
    end
  end
  return vim.o.lines, vim.o.columns
end

---Reply to CSI window-manipulation queries with the host's pixel
---dimensions, scaled for the embedded terminal's window.
---@param buf integer
---@param seq string  the full CSI sequence, e.g. "\27[14t"
function M._reply_csi_window(buf, seq)
  -- seq looks like "\27[<args>t". Strip framing.
  local body = seq:sub(3, -2)
  -- Args before the leading "<param>" are space-separated; we only care
  -- about the first numeric param.
  local first = body:match('^(%d+)')
  if not first then
    return
  end
  local chan = vim.b[buf].terminal_job_id
  if not chan then
    return
  end
  local cells_h, cells_w = buffer_window_cells(buf)
  local cell_w, cell_h = host_cell_px()
  local reply_seq
  if first == '14' then
    -- Reply: CSI 4 ; HEIGHT_PX ; WIDTH_PX t
    reply_seq = string.format('\27[4;%d;%dt', cells_h * cell_h, cells_w * cell_w)
  elseif first == '16' then
    -- Reply: CSI 6 ; HEIGHT_PX ; WIDTH_PX t
    reply_seq = string.format('\27[6;%d;%dt', cell_h, cell_w)
  elseif first == '18' then
    -- Reply: CSI 8 ; ROWS ; COLS t
    reply_seq = string.format('\27[8;%d;%dt', cells_h, cells_w)
  else
    return
  end
  pcall(vim.api.nvim_chan_send, chan, reply_seq)
end

---@param buf integer
---@param keys table<string,string>
---@param status string  e.g. "OK" or "ENOTSUPP:..."
local function reply(buf, keys, status)
  local q = keys.q
  local is_error = status ~= 'OK'
  if q == '2' then
    return
  end
  if q == '1' and not is_error then
    return
  end
  local chan = vim.b[buf].terminal_job_id
  if not chan then
    return
  end
  local id = keys.i or ''
  local bytes = '\27_Gi=' .. id .. ';' .. status .. '\27\\'
  vim.api.nvim_chan_send(chan, bytes)
end

---@param buf integer
---@param keys table<string,string>
---@param data string image bytes
---@param cursor integer[]
local function place(buf, keys, data, cursor)
  local s = bufstate(buf)
  local row, col = M._cursor_pos(cursor)
  local opts = {
    relative = 'buffer',
    buf = buf,
    row = row,
    col = col,
  }
  if keys.c then
    opts.width = tonumber(keys.c)
  end
  if keys.r then
    opts.height = tonumber(keys.r)
  end
  if keys.z then
    opts.zindex = tonumber(keys.z)
  end
  -- vim.ui.img.set requires PNG. Convert raw RGB / RGBA transmissions
  -- (kitty f=24 / f=32) into uncompressed PNG before handing off.
  local png_data = data
  if keys.f == '32' or keys.f == '24' then
    local bpp = (keys.f == '32') and 4 or 3
    local pw = tonumber(keys.s) or 0
    local ph = tonumber(keys.v) or 0
    if pw > 0 and ph > 0 then
      local expected = pw * ph * bpp
      -- Pad short transmissions (e.g. from chunk loss) so dimensions match.
      if #data < expected then
        data = data .. string.rep('\0', expected - #data)
      elseif #data > expected then
        data = data:sub(1, expected)
      end
      png_data = require('vim.ui.img._png').encode(data, pw, ph, bpp)
    end
  end
  local img_id = vim.ui.img.set(png_data, opts)
  if keys.i then
    local prev = s.ids[keys.i]
    if prev and prev ~= img_id then
      pcall(vim.ui.img.del, prev)
    end
    s.ids[keys.i] = img_id
  end
  local placement_key = keys.p or keys.i
  if placement_key then
    local prev = s.placements[placement_key]
    if prev and prev ~= img_id then
      pcall(vim.ui.img.del, prev)
    end
    s.placements[placement_key] = img_id
  end
end

---Default action handlers. Tests can replace this table to spy on routing.
M._handlers = {
  t = function(buf, keys, data)
    bufstate(buf).data[keys.i or '0'] = data
    reply(buf, keys, 'OK')
  end,

  T = function(buf, keys, data, cursor)
    bufstate(buf).data[keys.i or '0'] = data
    place(buf, keys, data, cursor)
    reply(buf, keys, 'OK')
  end,

  p = function(buf, keys, cursor)
    local s = bufstate(buf)
    local data = s.data[keys.i or '0']
    if not data then
      return
    end
    place(buf, keys, data, cursor)
  end,

  d = function(buf, keys)
    local s = bufstate(buf)
    local what = keys.d or 'i'

    if what == 'A' then
      for _, vim_ui_img_id in pairs(s.ids) do
        pcall(vim.ui.img.del, vim_ui_img_id)
      end
      s.ids = {}
      s.placements = {}
      s.data = {}
      return
    end

    if what == 'p' then
      local key = keys.p
      if not key then
        return
      end
      local id = s.placements[key]
      if id then
        pcall(vim.ui.img.del, id)
        s.placements[key] = nil
      end
      return
    end

    -- d=i (default): delete by image id.
    local key = keys.i
    if not key then
      return
    end
    local id = s.ids[key]
    if id then
      pcall(vim.ui.img.del, id)
      s.ids[key] = nil
      s.data[key] = nil
      -- Drop any placement that pointed at this image id.
      for pkey, pid in pairs(s.placements) do
        if pid == id then
          s.placements[pkey] = nil
        end
      end
    end
  end,

  q = function(buf, keys)
    if host_supports_images() then
      reply(buf, keys, 'OK')
    else
      reply(buf, keys, 'ENOTSUPP:host has no image support')
    end
  end,

  a = function(_, _) end, -- animation, out of scope
}

---Invoke the registered handler for {action} with the appropriate signature.
---@param buf integer
---@param action string
---@param keys table<string,string>
---@param data string?  reassembled image bytes (for t / T)
---@param cursor integer[]
local function invoke_handler(buf, action, keys, data, cursor)
  local h = M._handlers[action]
  if not h then
    return
  end
  if action == 'T' then
    h(buf, keys, data, cursor)
  elseif action == 't' then
    h(buf, keys, data)
  elseif action == 'p' then
    h(buf, keys, cursor)
  else
    h(buf, keys)
  end
end

---Dispatch a TermRequest sequence for {buf}.
---{seq} is the full APC body as exposed on TermRequest, including the
---leading "\27_" framing (e.g. "\27_Ga=T,...;<base64>"). Non-kitty
---sequences return early.
---{cursor} is the 2-element {row, col} array exposed on TermRequest.
---
---Per the kitty graphics protocol, only the *first* chunk of a chunked
---transmission carries the action and metadata; continuation chunks have only
---`m=` and base64. We therefore track pending transmissions per
---buffer+image-key in {bufstate.pending}, completing them on the finalizer
---chunk (`m=0` or `m` absent).
---@param buf integer
---@param seq string
---@param cursor integer[]
function M.dispatch(buf, seq, cursor)
  -- CSI window-manipulation queries that programs use to decide whether to
  -- render images:
  --   CSI 14 t — text area size in pixels  → reply CSI 4 ; H ; W t
  --   CSI 16 t — cell size in pixels       → reply CSI 6 ; H ; W t
  --   CSI 18 t — text area size in cells   → reply CSI 8 ; rows ; cols t
  if seq:sub(1, 2) == '\27[' and seq:sub(-1) == 't' then
    M._reply_csi_window(buf, seq)
    return
  end

  -- Kitty graphics: APC framing "\27_G..."
  if seq:sub(1, 3) ~= '\27_G' then
    return
  end
  local parsed = M._parse_apc(seq:sub(4))
  if not parsed then
    return
  end
  local keys = parsed.keys
  local payload = parsed.payload
  local action = keys.a

  -- Continuation / finalizer chunk: action absent, `m=` present.
  -- Collect into the pending entry (if any), and dispatch on the finalizer.
  --
  -- Per the kitty graphics protocol, continuation chunks may carry only `m=`
  -- (no `i=`). The first chunk's image-key identifies the transmission;
  -- continuations are associated with the most recently started in-flight
  -- transmission. We track that key on the bufstate so continuations don't
  -- need to repeat it.
  if not action then
    if not keys.m then
      return -- nothing actionable
    end
    local s = bufstate(buf)
    local pkey = keys.i or s.pending_key
    local pending = pkey and s.pending[pkey] or nil
    if not pending then
      -- Orphaned continuation (we never saw the header chunk). Discard.
      return
    end
    pending.b64 = pending.b64 .. payload
    if keys.m == '1' then
      return -- still waiting for more chunks
    end
    -- m=0: finalize.
    s.pending[pkey] = nil
    if s.pending_key == pkey then
      s.pending_key = nil
    end
    local saved_keys = pending.keys
    local saved_cursor = pending.cursor
    local saved_action = saved_keys.a
    if not saved_action then
      return
    end
    local data
    if saved_action == 't' or saved_action == 'T' then
      data = vim.base64.decode(pending.b64)
    end
    invoke_handler(buf, saved_action, saved_keys, data, saved_cursor)
    return
  end

  -- First (or only) chunk with an action.
  -- If chunked (m=1), stash metadata + payload and wait for continuations.
  if keys.m == '1' then
    local s = bufstate(buf)
    local pkey = keys.i or '0'
    s.pending[pkey] = {
      keys = keys,
      cursor = cursor,
      b64 = payload,
    }
    -- Remember this as the in-flight transmission so continuations that omit
    -- `i=` (the common case) can find it.
    s.pending_key = pkey
    return
  end

  -- Single-chunk transmission (or non-transmission action).
  -- Reassemble in case the protocol contract is satisfied via existing
  -- _reassemble bookkeeping (i.e. an out-of-band chunk buffer for this id).
  local data
  if action == 't' or action == 'T' then
    data = M._reassemble(buf, keys, payload)
    if data == nil then
      return -- still waiting for more chunks
    end
  end
  invoke_handler(buf, action, keys, data, cursor)
end

return M
