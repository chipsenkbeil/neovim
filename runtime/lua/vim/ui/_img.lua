---Experimental image API for Neovim.
---
---This provides a functional API for loading and displaying images in Neovim.
---Currently supports PNG images via the Kitty graphics protocol.
---@module 'vim.ui._img'

---@class vim.ui._img
---@field private __images table<integer, vim.ui._img.ImgOpts>
---@field private __placements table<integer, {img_id:integer}|vim.ui._img.PlacementOpts>
local M = {
  __images = {},
  __placements = {},
}

---Retrieves a copy of the image or placement opts based on the id.
---@param id integer
---@return vim.ui._img.ImgOpts|vim.ui._img.PlacementOpts|nil opts, 'img'|'placement' kind
function M.get(id)
  if type(M.__images[id]) == 'table' then
    return vim.deepcopy(M.__images[id]), 'img'
  end

  if type(M.__placements[id]) == 'table' then
    return vim.deepcopy(M.__placements[id]), 'placement'
  end

  return nil, 'img'
end

---Returns an iterator over the loaded images, mapped by id.
function M.images()
  return vim.iter(pairs(M.__images))
end

---Returns an iterator over the active placements, mapped by id.
function M.placements()
  return vim.iter(pairs(M.__placements))
end

---@class vim.ui._img.ImgOpts
---@field data? string
---@field filename? string

---Load an image from filename or data.
---@param opts string|vim.ui._img.ImgOpts
---@return integer id
function M.load(opts)
  vim.validate('img', opts, { 'string', 'table' })

  -- If passed a string, we assume it is the filename
  if type(opts) == 'string' then
    opts = { filename = opts }
  end

  ---@type vim.ui._img._kitty
  local provider = require('vim.ui._img._kitty')
  local id = provider.load(opts)
  M.__images[id] = opts

  return id
end

---@class vim.ui._img.PlacementOpts
---@field row? integer starting row where image will appear
---@field col? integer starting column where image will appear
---@field width? integer width (in cells) to resize the image
---@field height? integer height (in cells) to resize the image
---@field z? integer z-index of the placement relative to other placements with a higher number being placed over lower-indexed placements

---Places a loaded image within neovim, visually displaying it.
---@param id integer id of image to place, or id of placement to overwrite
---@param opts? vim.ui._img.PlacementOpts
---@return integer placement_id id of the created/updated placement
function M.place(id, opts)
  opts = opts or {}

  vim.validate('id', id, 'number')
  vim.validate('opts', opts, 'table')

  -- Ensure that the id belongs to an image or placement
  local _opts, kind = M.get(id)
  assert(_opts, 'invalid id: ' .. tostring(id))

  ---@type vim.ui._img._kitty
  local provider = require('vim.ui._img._kitty')
  local placement_id = provider.place(id, opts)
  local img_id = id

  -- If id supplied was for an existing placement, we need
  -- to instead look up the associated image's id
  if kind == 'placement' then
    ---Casting opts to placement with internally-only img_id mapping
    ---@cast _opts {img_id:integer}
    img_id = _opts.img_id
  end

  -- Update the cached placement information
  M.__placements[placement_id] = vim.tbl_extend('keep', { img_id = img_id }, opts)
  return placement_id
end

---Hide an image (or placement) within neovim.
---@param id integer id of image or placement
---@return boolean true if an image or placement was hidden
function M.hide(id)
  vim.validate('id', id, 'number')

  -- If this is an image's id
  if M.__images[id] then
    M.__images[id] = nil

    for placement_id, placement in pairs(M.__placements) do
      if placement.img_id == id then
        M.__placements[placement_id] = nil
      end
    end

    ---@type vim.ui._img._kitty
    local provider = require('vim.ui._img._kitty')
    provider.hide(id)

    return true

  -- If this is a placement's id
  elseif M.__placements[id] then
    local placement = M.__placements[id]
    M.__placements[id] = nil

    ---@type vim.ui._img._kitty
    local provider = require('vim.ui._img._kitty')
    provider.hide(placement.img_id, id)

    return true

  -- Otherwise, nothing to do here
  else
    return false
  end
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = function()
    -- Delete all images and associated placements on exit
    -- to ensure that they are unloaded from the terminal
    for id, _ in pairs(M.__images) do
      M.hide(id)
    end
  end,
})

return M
