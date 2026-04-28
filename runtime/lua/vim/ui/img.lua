local M = {}

---@brief
---
---EXPERIMENTAL: This API may change in the future. Its semantics are not yet finalized.
---
---This provides a functional API for displaying images in Nvim.
---Currently supports PNG images via the Kitty graphics protocol (TUI) or
---UI protocol events (GUI clients with ext_images support).
---
---To override the image backend, replace `vim.ui.img` with your own
---implementation providing set/get/del.
---
---Examples:
---
---```lua
----- Load image bytes from disk and display at row 5, column 10
---local id = vim.ui.img.set(
---  vim.fn.readblob('/path/to/img.png'),
---  { row = 5, col = 10, width = 40, height = 20, zindex = 50 }
---)
---
----- Update the image position
---vim.ui.img.set(id, { row = 8, col = 12 })
---
----- Retrieve the current image opts
---local opts = vim.ui.img.get(id)
---
----- Remove the image
---vim.ui.img.del(id)
---```

---@class vim.ui.img.Opts
---@inlinedoc
---@field row? integer starting row (1-indexed)
---@field col? integer starting column (1-indexed)
---@field width? integer width in cells
---@field height? integer height in cells
---@field zindex? integer stacking order (higher = on top)

--- Maps user-facing ID to internal tracking info.
---@type table<integer, { img_id?: integer, opts: vim.ui.img.Opts }>
local state = {}

local img_counter = 0

---@return integer
local function next_img_id()
  img_counter = img_counter + 1
  return img_counter
end

---Returns true if any attached UI declared ext_images support.
---@return boolean
local function has_ext_images_ui()
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.ext_images then
      return true
    end
  end
  return false
end

---Display an image or update an existing one.
---
---When {data_or_id} is a string, displays the image bytes at the position
---given by {opts}. Returns an integer id for later use.
---
---When {data_or_id} is an integer (a previously returned id), updates
---the image with new {opts}.
---
---@param data_or_id string|integer image bytes (string) or existing id (integer)
---@param opts? vim.ui.img.Opts
---@return integer id
function M.set(data_or_id, opts)
  opts = opts or {}
  vim.validate('data_or_id', data_or_id, { 'string', 'number' })
  vim.validate('opts', opts, 'table')

  if has_ext_images_ui() then
    -- GUI path: emit structured UI protocol events.
    if type(data_or_id) == 'string' then
      local id = next_img_id()
      vim.api.nvim_ui_img_show(id, data_or_id, opts)
      state[id] = { opts = vim.deepcopy(opts) }
      return id
    end

    local id = data_or_id
    local entry = state[id]
    assert(entry, 'invalid image id: ' .. tostring(id))
    local merged = vim.tbl_extend('force', entry.opts, opts)
    vim.api.nvim_ui_img_update(id, merged)
    entry.opts = merged
    return id
  end

  -- Terminal path: emit Kitty graphics protocol termcodes.
  local kitty = require('vim.ui.img._kitty')

  if type(data_or_id) == 'string' then
    local img_id, placement_id = kitty.set(data_or_id, opts)
    state[placement_id] = { img_id = img_id, opts = vim.deepcopy(opts) }
    return placement_id
  end

  local id = data_or_id
  local entry = state[id]
  assert(entry, 'invalid image id: ' .. tostring(id))
  local merged = vim.tbl_extend('force', entry.opts, opts)
  kitty.update(entry.img_id, id, merged)
  entry.opts = merged
  return id
end

---Get the opts for an image.
---
---@param id integer
---@return vim.ui.img.Opts? opts copy of image opts, or nil if not found
function M.get(id)
  vim.validate('id', id, 'number')

  local entry = state[id]
  if not entry then
    return nil
  end

  return vim.deepcopy(entry.opts)
end

---Delete an image, removing it from display.
---
---@param id integer
---@return boolean found true if the image existed
function M.del(id)
  vim.validate('id', id, 'number')

  local entry = state[id]
  if not entry then
    return false
  end

  if has_ext_images_ui() then
    vim.api.nvim_ui_img_delete(id)
  else
    local kitty = require('vim.ui.img._kitty')
    kitty.delete(entry.img_id)
  end

  state[id] = nil
  return true
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = function()
    ---@type integer[]
    local ids = vim.tbl_keys(state)

    for _, id in ipairs(ids) do
      M.del(id)
    end
  end,
})

return M
