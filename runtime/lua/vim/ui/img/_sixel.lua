---Implementation of neovim's image provider using the Sixel graphics protocol.
---@class vim.ui.img._sixel: vim.ui.img.Provider
local M = {}

local band = require('bit').band
local bor = require('bit').bor
local lshift = require('bit').lshift
local ffi = require('ffi')
local buffer = require('string.buffer')

---@type table<integer, {data:string, filename:string?, rgba:string, width:integer, height:integer}>
local images = {}
---@type table<integer, {img_id:integer, opts:vim.ui.img.PlacementOpts, sixel_data:string?}>
local placements = {}

---@type boolean
local pending_rerender = false

local SYNC_START = '\027[?2026h'
local SYNC_END = '\027[?2026l'

-- Register callback to invalidate cached sixel data when cell size changes
require('vim.ui.img._util')._on_cell_size_change = function(_, _)
  for _, p in pairs(placements) do
    p.sixel_data = nil
  end
end

---Load an image and decode it to RGBA pixels.
---@param opts vim.ui.img.ImgOpts
---@return integer id
function M.load(opts)
  local util = require('vim.ui.img._util') ---@type vim.ui.img._util
  local png = require('vim.ui.img._png') ---@type vim.ui.img._png
  local id = util.generate_id()

  local data
  if util.is_remote() then
    vim.validate('opts.data', opts.data, 'string', false, 'image data required when remote')
    data = opts.data
  else
    vim.validate('opts.filename', opts.filename, 'string', false, 'image filename required')
    data = util.load_image_data(opts.filename)
  end

  assert(util.is_png_data(data), 'sixel: only PNG images are supported')

  local decoded = png.decode(data)

  images[id] = {
    data = data,
    filename = opts.filename,
    rgba = decoded.pixels,
    width = decoded.width,
    height = decoded.height,
  }

  return id
end

---Place an image somewhere in neovim.
---@param id integer image id
---@param opts? vim.ui.img.PlacementOpts
---@return integer placement_id
function M.place(id, opts)
  local util = require('vim.ui.img._util') ---@type vim.ui.img._util
  local placement_id = util.generate_id()
  opts = opts or {}

  local img_id = id
  local is_update = false

  -- If id is an existing placement, resolve the real img_id
  if placements[id] then
    img_id = placements[id].img_id
    placements[id] = nil
    is_update = true
  end

  placements[placement_id] = { img_id = img_id, opts = opts }

  if is_update then
    -- Atomic: clears old position + draws all images (including new) in one SYNC batch
    M._rerender()
  else
    M._send_placement(img_id, placement_id)
  end

  return placement_id
end

---Send the sixel escape sequence to display an image.
---@param img_id integer
---@param placement_id integer
function M._send_placement(img_id, placement_id)
  local util = require('vim.ui.img._util') ---@type vim.ui.img._util

  local img = images[img_id]
  if not img then
    return
  end

  local p = placements[placement_id]
  if not p then
    return
  end

  local opts = p.opts

  -- Generate sixel data (cached per placement)
  if not p.sixel_data then
    local rgba = img.rgba
    local w = img.width
    local h = img.height

    -- Resize if width/height specified (in cells)
    if opts.width or opts.height then
      local cell_w, cell_h = util.cell_pixel_size()
      local target_w = (opts.width or math.ceil(w / cell_w)) * cell_w
      local target_h = (opts.height or math.ceil(h / cell_h)) * cell_h
      rgba, w, h = M._resize(rgba, w, h, target_w, target_h)
    end

    p.sixel_data = M._encode_sixel(rgba, w, h)
  end

  -- Cursor management
  local cursor_save = '\0277'
  local cursor_hide = '\027[?25l'
  local cursor_move = string.format('\027[%d;%dH', opts.row or 1, opts.col or 1)
  local cursor_restore = '\0278'
  local cursor_show = '\027[?25h'

  util.term_send(
    SYNC_START
      .. cursor_save
      .. cursor_hide
      .. cursor_move
      .. p.sixel_data
      .. cursor_restore
      .. cursor_show
      .. SYNC_END
  )
end

---Hide (aka delete) an image and all placements,
---or if the placement id is included then just that placement.
---@param id integer
---@param placement_id? integer
function M.hide(id, placement_id)
  if placement_id then
    placements[placement_id] = nil
  else
    for pid, p in pairs(placements) do
      if p.img_id == id then
        placements[pid] = nil
      end
    end
    images[id] = nil
  end

  M._rerender()
end

---Re-render all surviving placements after a hide.
---Uses Mode 2026 synchronized output so the clear + redraw appears atomic.
function M._rerender()
  if pending_rerender then
    return
  end
  pending_rerender = true

  local util = require('vim.ui.img._util') ---@type vim.ui.img._util
  local old_termsync = vim.o.termsync
  vim.o.termsync = false

  -- Start synchronized output so the screen clear is not visible
  util.term_send(SYNC_START)

  -- Force TUI refresh to clear painted pixels (hidden by sync mode)
  vim.cmd.mode()

  pending_rerender = false

  -- Sort by z-index for correct layering
  local sorted = {}
  for pid, p in pairs(placements) do
    table.insert(sorted, { pid = pid, p = p })
  end
  table.sort(sorted, function(a, b)
    return (a.p.opts.z or 0) < (b.p.opts.z or 0)
  end)

  local parts = { '\0277\027[?25l' } -- cursor save + hide (once)

  for _, entry in ipairs(sorted) do
    local img = images[entry.p.img_id]
    if img then
      local p = entry.p
      local opts = p.opts

      -- Generate sixel data (cached per placement)
      if not p.sixel_data then
        local rgba = img.rgba
        local w = img.width
        local h = img.height
        if opts.width or opts.height then
          local cell_w, cell_h = util.cell_pixel_size()
          local target_w = (opts.width or math.ceil(w / cell_w)) * cell_w
          local target_h = (opts.height or math.ceil(h / cell_h)) * cell_h
          rgba, w, h = M._resize(rgba, w, h, target_w, target_h)
        end
        p.sixel_data = M._encode_sixel(rgba, w, h)
      end

      local cursor_move = string.format('\027[%d;%dH', opts.row or 1, opts.col or 1)
      table.insert(parts, cursor_move .. p.sixel_data)
    end
  end

  -- cursor restore + show (once), end synchronized output
  table.insert(parts, '\0278\027[?25h')
  table.insert(parts, SYNC_END)
  util.term_send(table.concat(parts))
  vim.o.termsync = old_termsync
end

---Nearest-neighbor resize of RGBA pixel data using FFI.
---@param rgba string RGBA pixel data (4 bytes per pixel)
---@param src_w integer source width
---@param src_h integer source height
---@param dst_w integer destination width
---@param dst_h integer destination height
---@return string rgba, integer width, integer height
function M._resize(rgba, src_w, src_h, dst_w, dst_h)
  local src = ffi.cast('const uint8_t*', rgba)
  local dst_size = dst_w * dst_h * 4
  local dst = ffi.new('uint8_t[?]', dst_size)

  -- Pre-compute source X offsets (byte offset into source row)
  local src_x_offsets = ffi.new('int32_t[?]', dst_w)
  for x = 0, dst_w - 1 do
    src_x_offsets[x] = math.floor(x * src_w / dst_w) * 4
  end

  local dst_idx = 0
  for y = 0, dst_h - 1 do
    local src_row = src + math.floor(y * src_h / dst_h) * src_w * 4
    for x = 0, dst_w - 1 do
      local sp = src_row + src_x_offsets[x]
      dst[dst_idx] = sp[0]
      dst[dst_idx + 1] = sp[1]
      dst[dst_idx + 2] = sp[2]
      dst[dst_idx + 3] = sp[3]
      dst_idx = dst_idx + 4
    end
  end

  return ffi.string(dst, dst_size), dst_w, dst_h
end

---Encode RGBA pixel data as a sixel string.
---@param rgba string RGBA pixel data
---@param w integer width in pixels
---@param h integer height in pixels
---@return string sixel DCS sequence
function M._encode_sixel(rgba, w, h)
  local src = ffi.cast('const uint8_t*', rgba)
  local n_pixels = w * h

  -- Extract pixel colors as packed integers: r*65536 + g*256 + b, or -1 for transparent
  local pixel_colors = ffi.new('int32_t[?]', n_pixels)
  for i = 0, n_pixels - 1 do
    local off = i * 4
    if src[off + 3] >= 128 then
      pixel_colors[i] = src[off] * 65536 + src[off + 1] * 256 + src[off + 2]
    else
      pixel_colors[i] = -1
    end
  end

  -- Quantize to palette
  local palette, indexed = M._quantize(pixel_colors, n_pixels)

  -- Build sixel output using string.buffer
  local out = buffer.new()

  -- DCS introducer with raster attributes
  out:put(string.format('\027Pq"1;1;%d;%d', w, h))

  -- Color definitions
  for i, color in ipairs(palette) do
    local r_pct = math.floor(color[1] * 100 / 255 + 0.5)
    local g_pct = math.floor(color[2] * 100 / 255 + 0.5)
    local b_pct = math.floor(color[3] * 100 / 255 + 0.5)
    out:put(string.format('#%d;2;%d;%d;%d', i - 1, r_pct, g_pct, b_pct))
  end

  -- Encode sixel bands (6 rows each) - single pass per band
  local n_bands = math.ceil(h / 6)
  -- Reusable per-band structures
  local bitmasks_by_color = {} -- color_idx -> array of bitmasks per x
  local active_colors = {}
  local active_set = {}

  for band_y = 0, n_bands - 1 do
    local y_start = band_y * 6

    -- Clear active tracking
    for i = 1, #active_colors do
      local ci = active_colors[i]
      active_set[ci] = nil
      bitmasks_by_color[ci] = nil
    end
    active_colors[0] = 0 -- use [0] as length counter
    for i = 1, #active_colors do
      active_colors[i] = nil
    end

    -- Single pass: scan all pixels in this band, build bitmasks per color per x
    for bit_row = 0, 5 do
      local y = y_start + bit_row
      if y >= h then
        break
      end
      local row_base = y * w
      local bit_val = lshift(1, bit_row)
      for x = 0, w - 1 do
        local ci = indexed[row_base + x]
        if ci ~= 0 then
          local masks = bitmasks_by_color[ci]
          if not masks then
            -- First time seeing this color in this band
            masks = ffi.new('uint8_t[?]', w)
            bitmasks_by_color[ci] = masks
            if not active_set[ci] then
              active_set[ci] = true
              local len = active_colors[0] + 1
              active_colors[0] = len
              active_colors[len] = ci
            end
          end
          masks[x] = bor(masks[x], bit_val)
        end
      end
    end

    local n_active = active_colors[0]

    -- Sort active colors for deterministic output
    if n_active > 1 then
      table.sort(active_colors, function(a, b)
        if a == nil then
          return false
        end
        if b == nil then
          return true
        end
        return a < b
      end)
    end

    -- Emit RLE for each active color
    for ai = 1, n_active do
      local color_idx = active_colors[ai]
      local masks = bitmasks_by_color[color_idx]

      -- Color select
      out:put('#', tostring(color_idx - 1))

      -- Run-length encode directly to output buffer
      local prev_ch = masks[0] + 63
      local count = 1
      for x = 1, w - 1 do
        local ch = masks[x] + 63
        if ch == prev_ch then
          count = count + 1
        else
          if count >= 4 then
            out:put(string.format('!%d%s', count, string.char(prev_ch)))
          else
            local c = string.char(prev_ch)
            for _ = 1, count do
              out:put(c)
            end
          end
          prev_ch = ch
          count = 1
        end
      end
      -- Flush last run
      if count >= 4 then
        out:put(string.format('!%d%s', count, string.char(prev_ch)))
      else
        local c = string.char(prev_ch)
        for _ = 1, count do
          out:put(c)
        end
      end

      out:put('$') -- Carriage return (same band)
    end

    out:put('-') -- New line (next band)
  end

  -- DCS terminator
  out:put('\027\\')

  return out:get()
end

---Quantize pixel colors to a palette of at most 256 colors using median cut.
---@param pixel_colors ffi.cdata* int32_t array of packed r*65536+g*256+b values (-1 = transparent)
---@param n_pixels integer total number of pixels
---@return number[][] palette (list of {r,g,b})
---@return table<integer, integer> indexed (position -> 1-based palette index, 0 = transparent)
function M._quantize(pixel_colors, n_pixels)
  -- Collect unique colors using integer keys
  local unique = {}
  local unique_count = 0
  local int_key_map = {} -- packed int -> index in unique

  for i = 0, n_pixels - 1 do
    local key = pixel_colors[i]
    if key >= 0 and not int_key_map[key] then
      unique_count = unique_count + 1
      local r = math.floor(key / 65536)
      local g = math.floor(key / 256) % 256
      local b = key % 256
      int_key_map[key] = unique_count
      unique[unique_count] = { r, g, b, key = key }
    end
  end

  local palette
  local key_to_palette = {} -- packed int -> 1-based palette index

  if unique_count <= 256 then
    -- Use all unique colors directly
    palette = {}
    for i, c in ipairs(unique) do
      palette[i] = { c[1], c[2], c[3] }
      key_to_palette[c.key] = i
    end
  else
    -- Median cut quantization
    palette, key_to_palette = M._median_cut(unique, 256)
  end

  -- Build indexed pixel map
  local indexed = {}
  for i = 0, n_pixels - 1 do
    local key = pixel_colors[i]
    if key >= 0 then
      indexed[i] = key_to_palette[key] or 0
    else
      indexed[i] = 0
    end
  end

  return palette, indexed
end

---Median cut color quantization.
---@param colors table list of {r,g,b,key=integer}
---@param max_colors integer
---@return number[][] palette
---@return table<integer, integer> key_to_palette (packed int -> palette index)
function M._median_cut(colors, max_colors)
  ---@class vim.ui.img._sixel.ColorBox
  ---@field colors table
  local boxes = { { colors = colors } }

  -- Split boxes until we have enough
  while #boxes < max_colors do
    -- Find box with largest range to split, caching split channel
    local best_idx = 1
    local best_range = -1
    local best_ch = 1

    for i, box in ipairs(boxes) do
      if #box.colors > 1 then
        local r_min, g_min, b_min = 255, 255, 255
        local r_max, g_max, b_max = 0, 0, 0
        for _, c in ipairs(box.colors) do
          if c[1] < r_min then r_min = c[1] end
          if c[1] > r_max then r_max = c[1] end
          if c[2] < g_min then g_min = c[2] end
          if c[2] > g_max then g_max = c[2] end
          if c[3] < b_min then b_min = c[3] end
          if c[3] > b_max then b_max = c[3] end
        end
        local r_range = r_max - r_min
        local g_range = g_max - g_min
        local b_range = b_max - b_min
        local max_range, ch
        if r_range >= g_range and r_range >= b_range then
          max_range, ch = r_range, 1
        elseif g_range >= b_range then
          max_range, ch = g_range, 2
        else
          max_range, ch = b_range, 3
        end
        if max_range > best_range then
          best_range = max_range
          best_idx = i
          best_ch = ch
        end
      end
    end

    if best_range <= 0 then
      break
    end

    local box = boxes[best_idx]

    -- Sort by the cached channel and split at median
    local split_ch = best_ch
    table.sort(box.colors, function(a, b)
      return a[split_ch] < b[split_ch]
    end)

    local mid = math.floor(#box.colors / 2)
    local box1 = {}
    local box2 = {}
    for i = 1, mid do
      box1[i] = box.colors[i]
    end
    for i = mid + 1, #box.colors do
      box2[i - mid] = box.colors[i]
    end

    boxes[best_idx] = { colors = box1 }
    boxes[#boxes + 1] = { colors = box2 }
  end

  -- Compute palette as average of each box
  local palette = {}
  local key_to_palette = {}
  for i, box in ipairs(boxes) do
    local r_sum, g_sum, b_sum = 0, 0, 0
    for _, c in ipairs(box.colors) do
      r_sum = r_sum + c[1]
      g_sum = g_sum + c[2]
      b_sum = b_sum + c[3]
    end
    local n = #box.colors
    palette[i] = {
      math.floor(r_sum / n + 0.5),
      math.floor(g_sum / n + 0.5),
      math.floor(b_sum / n + 0.5),
    }
    -- Map each color in the box to this palette index
    for _, c in ipairs(box.colors) do
      key_to_palette[c.key] = i
    end
  end

  return palette, key_to_palette
end

return M
