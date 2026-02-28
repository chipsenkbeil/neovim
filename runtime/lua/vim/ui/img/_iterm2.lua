---Implementation of neovim's image provider using the iTerm2 graphics protocol (OSC 1337).
---@class vim.ui.img._iterm2: vim.ui.img.Provider
local M = {}

---@type table<integer, {data:string, filename:string?}>
local images = {}
---@type table<integer, {img_id:integer, opts:vim.ui.img.PlacementOpts}>
local placements = {}

---@type boolean
local pending_rerender = false

local SYNC_START = '\027[?2026h'
local SYNC_END = '\027[?2026l'

---Get or compute cached base64 encoding for an image.
---@param img {data:string, filename:string?, base64:string?}
---@return string
local function get_base64(img)
  if not img.base64 then
    img.base64 = vim.base64.encode(img.data)
  end
  return img.base64
end

---Load an image into memory without displaying it.
---@param opts vim.ui.img.ImgOpts
---@return integer id
function M.load(opts)
  local util = require('vim.ui.img._util') ---@type vim.ui.img._util
  local id = util.generate_id()

  local data
  if util.is_remote() then
    vim.validate('opts.data', opts.data, 'string', false, 'image data required when remote')
    data = opts.data
  else
    vim.validate('opts.filename', opts.filename, 'string', false, 'image filename required')
    data = util.load_image_data(opts.filename)
  end

  images[id] = { data = data, filename = opts.filename }
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
    M._send_placement(img_id, opts)
  end

  return placement_id
end

---Send the escape sequence to display an image at the given position.
---@param img_id integer
---@param opts vim.ui.img.PlacementOpts
function M._send_placement(img_id, opts)
  local util = require('vim.ui.img._util') ---@type vim.ui.img._util

  local img = images[img_id]
  if not img then
    return
  end

  -- Cursor management
  local cursor_save = '\0277'
  local cursor_hide = '\027[?25l'
  local cursor_move = string.format('\027[%d;%dH', opts.row or 1, opts.col or 1)
  local cursor_restore = '\0278'
  local cursor_show = '\027[?25h'

  -- Build OSC 1337 args
  -- Match kitty behavior: stretch to fill when both dimensions specified,
  -- preserve aspect ratio when only one or neither is specified.
  local preserve = (not opts.width or not opts.height) and 1 or 0
  local args = {
    'size=' .. #img.data,
    'inline=1',
    'preserveAspectRatio=' .. preserve,
  }

  if opts.width then
    table.insert(args, 'width=' .. opts.width)
  end
  if opts.height then
    table.insert(args, 'height=' .. opts.height)
  end

  local base64_data = get_base64(img)

  -- Check if we need multipart transfer (>64KiB base64 inside tmux)
  if vim.env.TMUX ~= nil and #base64_data > 65536 then
    M._send_multipart(args, base64_data, cursor_save, cursor_hide, cursor_move, cursor_restore, cursor_show)
  else
    local seq = '\027]1337;File=' .. table.concat(args, ';') .. ':' .. base64_data .. '\a'
    util.term_send(
      SYNC_START .. cursor_save .. cursor_hide .. cursor_move .. seq .. cursor_restore .. cursor_show .. SYNC_END
    )
  end
end

---Send image data using iTerm2 multipart transfer (for large images in tmux).
---@param args string[] OSC 1337 args
---@param base64_data string base64-encoded image data
---@param cs string cursor save
---@param ch string cursor hide
---@param cm string cursor move
---@param cr string cursor restore
---@param csh string cursor show
function M._send_multipart(args, base64_data, cs, ch, cm, cr, csh)
  local util = require('vim.ui.img._util') ---@type vim.ui.img._util
  local chunk_size = 65536

  local parts = {
    SYNC_START, cs, ch, cm,
    '\027]1337;MultipartFile=' .. table.concat(args, ';') .. '\a',
  }

  local pos = 1
  while pos <= #base64_data do
    local end_pos = math.min(pos + chunk_size - 1, #base64_data)
    local chunk = base64_data:sub(pos, end_pos)
    table.insert(parts, '\027]1337;FilePart=' .. chunk .. '\a')
    pos = end_pos + 1
  end

  table.insert(parts, '\027]1337;FileEnd\a')
  table.insert(parts, cr .. csh .. SYNC_END)

  util.term_send(table.concat(parts))
end

---Hide (aka delete) an image and all placements,
---or if the placement id is included then just that placement.
---@param id integer
---@param placement_id? integer
function M.hide(id, placement_id)
  if placement_id then
    placements[placement_id] = nil
  else
    -- Remove all placements for this image
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
---iTerm2 has no "delete image" command, so we clear the screen and re-draw.
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
  for _, p in pairs(placements) do
    table.insert(sorted, p)
  end
  table.sort(sorted, function(a, b)
    return (a.opts.z or 0) < (b.opts.z or 0)
  end)

  local parts = { '\0277\027[?25l' } -- cursor save + hide (once)

  for _, p in ipairs(sorted) do
    local img = images[p.img_id]
    if img then
      local opts = p.opts
      local cursor_move = string.format('\027[%d;%dH', opts.row or 1, opts.col or 1)

      local preserve = (not opts.width or not opts.height) and 1 or 0
      local args = {
        'size=' .. #img.data,
        'inline=1',
        'preserveAspectRatio=' .. preserve,
      }
      if opts.width then
        table.insert(args, 'width=' .. opts.width)
      end
      if opts.height then
        table.insert(args, 'height=' .. opts.height)
      end

      local base64_data = get_base64(img)
      local seq = '\027]1337;File=' .. table.concat(args, ';') .. ':' .. base64_data .. '\a'
      table.insert(parts, cursor_move .. seq)
    end
  end

  -- cursor restore + show (once), end synchronized output
  table.insert(parts, '\0278\027[?25h')
  table.insert(parts, SYNC_END)
  util.term_send(table.concat(parts))
  vim.o.termsync = old_termsync
end

return M
