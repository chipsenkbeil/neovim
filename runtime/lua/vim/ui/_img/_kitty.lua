---Implementation of neovim's image provider using kitty.
---@module 'vim.ui._img._kitty'

---@class vim.ui._img._kitty
local M = {}

---Load an image into kitty terminal without displaying it.
---@param opts vim.ui._img.ImgOpts
---@return integer id
function M.load(opts)
  local util = require('vim.ui._img._util') ---@type vim.ui._img._util
  local id = util.generate_id()

  if util.is_remote() then
    vim.validate('opts.data', opts.data, 'string', false, 'image data required when remote')
    M.transmit_direct(id, opts.data)
  else
    vim.validate('opts.filename', opts.filename, 'string', false, 'image filename required')
    M.transmit_file(id, opts.filename)
  end

  return id
end

---Place an image somewhere in neovim.
---@param id integer image id
---@param opts? vim.ui._img.PlacementOpts
---@return integer placement_id
function M.place(id, opts)
  local util = require('vim.ui._img._util') ---@type vim.ui._img._util
  local placement_id = util.generate_id()
  opts = opts or {}

  -- Cursor management sequence
  local cursor_save = '\0277' -- Save cursor position
  local cursor_hide = '\027[?25l' -- Hide cursor
  local cursor_move = string.format('\027[%d;%dH', opts.row or 1, opts.col or 1) -- Move cursor
  local cursor_restore = '\0278' -- Restore cursor position
  local cursor_show = '\027[?25h' -- Show cursor

  -- Display image control
  ---@type table<string, string|number>
  local control = {
    a = 'p', -- Place/display
    i = id, -- Image ID
    p = placement_id, -- Placement ID
    C = '1', -- Don't move cursor after image
    q = '2', -- Suppress responses
  }

  if opts.width then
    control.c = opts.width
  end
  if opts.height then
    control.r = opts.height
  end
  if opts.z then
    control.z = opts.z
  end

  -- Send complete sequence
  util.term_send(
    cursor_save .. cursor_hide .. cursor_move .. M.seq(control) .. cursor_restore .. cursor_show
  )

  return placement_id
end

---Hide (aka delete) an image and all placements,
---or if the placement id is included then just that placement.
---@param id integer
---@param placement_id? integer
function M.hide(id, placement_id)
  local util = require('vim.ui._img._util') ---@type vim.ui._img._util

  ---@type table<string, string|number>
  local control = {
    a = 'd', -- Delete
    d = 'i', -- Delete image/placement
    i = id, -- Image ID
    q = '2', -- Suppress responses
  }

  if placement_id then
    control.p = placement_id
  end

  util.term_send(M.seq(control))
end

---@private
---Transmit image via file path (local)
---@param id integer id to associate with image in kitty
---@param filename string path to image file
function M.transmit_file(id, filename)
  local util = require('vim.ui._img._util') ---@type vim.ui._img._util

  local control = {
    f = '100', -- PNG format
    a = 't', -- Transmit without displaying
    t = 'f', -- File transmission
    i = id,
    q = '2', -- Suppress responses
  }

  local payload = vim.base64.encode(filename)
  util.term_send(M.seq(control, payload))
end

---@private
---Transmit image via direct data (remote)
---@param id integer id to associate with image in kitty
---@param data string
function M.transmit_direct(id, data)
  local util = require('vim.ui._img._util') ---@type vim.ui._img._util
  local chunk_size = 4096

  local base64_data = vim.base64.encode(data)
  local pos = 1
  local len = #base64_data

  while pos <= len do
    local end_pos = math.min(pos + chunk_size - 1, len)
    local chunk = base64_data:sub(pos, end_pos)
    local is_last = end_pos >= len

    local control = {}

    -- First chunk gets control info
    if pos == 1 then
      control.f = '100' -- PNG format
      control.a = 't' -- Transmit without displaying
      control.t = 'd' -- Direct transmission
      control.i = id
      control.q = '2' -- Suppress responses
    end

    control.m = is_last and '0' or '1' -- More data flag

    util.term_send(M.seq(control, chunk))
    pos = end_pos + 1
  end
end

---@private
---Create Kitty graphics protocol sequence.
---@param control table<string, string|number>
---@param payload? string
---@return string
function M.seq(control, payload)
  local data = { '\027_G' }

  if control then
    local tmp = {}
    for k, v in pairs(control) do
      table.insert(tmp, k .. '=' .. v)
    end
    if #tmp > 0 then
      table.insert(data, table.concat(tmp, ','))
    end
  end

  if payload and payload ~= '' then
    table.insert(data, ';')
    table.insert(data, payload)
  end

  table.insert(data, '\027\\')
  return table.concat(data)
end

return M
