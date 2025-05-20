---@class vim.ui.img.Placement
---@field image vim.ui.Image
---@field private __id integer|nil when loaded, id is populated by provider
---@field private __provider string
---@field private __next {action:(fun():vim.ui.img.utils.Promise<true>), promise:vim.ui.img.utils.Promise<true>}|nil
---@field private __opts vim.ui.img.Opts|nil last opts of image when displayed
---@field private __redrawing boolean if true, placement is actively redrawing itself
local M = {}
M.__index = M

---Creates a new image placement.
---@param img vim.ui.Image
---@param opts? {provider?:string}
---@return vim.ui.img.Placement
function M.new(img, opts)
  opts = opts or {}

  local instance = {}
  setmetatable(instance, M)

  instance.image = img
  instance.__provider = opts.provider or vim.o.imgprovider
  instance.__redrawing = false

  return instance
end

---Whether or not the placement is actively shown.
---@return boolean
function M:is_visible()
  return self.__id ~= nil
end

---Returns true if the placement is actively redrawing itself in any situation:
---showing, hiding, or updating.
---@return boolean
function M:is_redrawing()
  return self.__redrawing
end

---Returns the options associated with the placement when visible.
---@return vim.ui.img.Opts|nil
function M:opts()
  return self.__opts
end

---Retrieves the provider managing this placement.
---@return vim.ui.img.Provider|nil provider, string|nil err
function M:provider()
  local name = self.__provider
  local provider = require('vim.ui.img.providers').load(name)
  if provider then
    return provider
  else
    return nil, string.format('provider "%s" not found', name)
  end
end

---Displays the placement.
---```lua
---local placement = ...
---
-----Can be invoked synchronously
---assert(placement:show({ ... }):wait())
---
-----Can also be invoked asynchronously
---placement:show({ ... }):on_done(function(err)
---  -- Do something
---end)
---```
---@param opts? vim.ui.img.Opts
---@return vim.ui.img.utils.Promise<true>
function M:show(opts)
  -- If the placement is already visible, call update
  -- instead of show to refresh the image instead of
  -- showing it again without clearing the old one
  if self.__id then
    return self:__schedule(self.__update, self, opts)
  else
    return self:__schedule(self.__show, self, opts)
  end
end

---@private
---@param opts? vim.ui.img.Opts
---@return vim.ui.img.utils.Promise<true>
function M:__show(opts)
  local promise = require('vim.ui.img.utils.promise').new({
    context = 'placement.show',
  })

  local provider, err = self:provider()
  if err or not provider then
    err = err or 'unable to retrieve provider'
    promise:fail(err)
  else
    provider
      .show(self.image, opts)
      :on_ok(function(id)
        self.__id = id
        self.__opts = opts
        promise:ok(true)
      end)
      :on_fail(function(show_err)
        promise:fail(show_err)
      end)
  end

  return promise
end

---Hides the placement.
---```lua
---local placement = ...
---
-----Can be invoked synchronously
---assert(placement:hide():wait())
---
-----Can also be invoked asynchronously
---placement:hide():on_done(function(err)
---  -- Do something
---end)
---```
---@return vim.ui.img.utils.Promise<true>
function M:hide()
  return self:__schedule(self.__hide, self)
end

---@private
---@return vim.ui.img.utils.Promise<true>
function M:__hide()
  local promise = require('vim.ui.img.utils.promise').new({
    context = 'placement.hide',
  })

  local provider, err = self:provider()
  if err or not provider then
    err = err or 'unable to retrieve provider'
    promise:fail(err)
  else
    provider
      .hide(self.__id)
      :on_ok(function()
        self.__id = nil
        self.__opts = nil
        promise:ok(true)
      end)
      :on_fail(function(hide_err)
        promise:fail(hide_err)
      end)
  end

  return promise
end

---Updates the placement.
---```lua
---local placement = ...
---
-----Can be invoked synchronously
---assert(placement:update({ ... }):wait())
---
-----Can also be invoked asynchronously
---placement:update({ ... }):on_done(function(err)
---  -- Do something
---end)
---```
---@param opts? vim.ui.img.Opts
---@return vim.ui.img.utils.Promise<true>
function M:update(opts)
  return self:__schedule(self.__update, self, opts)
end

---@private
---@param opts? vim.ui.img.Opts
---@return vim.ui.img.utils.Promise<true>
function M:__update(opts)
  local promise = require('vim.ui.img.utils.promise').new({
    context = 'placement.update',
  })

  if not self.__id then
    return promise:fail('placement is not visible')
  end

  local provider, err = self:provider()
  if err or not provider then
    err = err or 'unable to retrieve provider'
    promise:fail(err)
  else
    provider
      .update(self.__id, opts)
      :on_ok(function(id)
        self.__id = id
        self.__opts = opts
        promise:ok(true)
      end)
      :on_fail(function(update_err)
        promise:fail(update_err)
      end)
  end

  return promise
end

---@param f fun(...:any):vim.ui.img.utils.Promise<true>
---@param ... any
---@return vim.ui.img.utils.Promise<true>
function M:__schedule(f, ...)
  -- If we are redrawing already, we need to queue this up,
  -- which involves storing the function to be invoked with its args
  -- and adding a new promise to the queue
  if self.__redrawing then
    local promise = require('vim.ui.img.utils.promise').new({
      context = 'placement.schedule',
    })

    -- If we already have something queued, we want to skip the action
    -- but still process the promise at the same time as this new item.
    --
    -- The logic is that if we did something like update(), and then
    -- before the operation took place we did hide(), the second
    -- operation would obviously overwrite the first, and we can just
    -- report that both succeeded once the second has finished.
    local next = self.__next
    if next then
      promise
        :on_ok(function(value)
          next.promise:ok(value)
        end)
        :on_fail(function(err)
          next.promise:fail(err)
        end)
    end

    -- Queue up our new scheduled action, considered the most recent
    -- to be run while waiting for redrawing to finish from the
    -- last action. All other queued up actions should be chained
    -- together at this point such that they are triggered when
    -- this queued promise completes.
    local args = { ... }
    self.__next = {
      action = function()
        return f(unpack(args))
      end,
      promise = promise,
    }

    return promise
  end

  -- Otherwise, start the operation immediately
  self.__redrawing = true
  return f(...):on_done(function()
    self.__redrawing = false

    -- If we have something queued, schedule it now
    local next = self.__next
    self.__next = nil
    if next then
      self
        :__schedule(next.action)
        :on_ok(function(value)
          next.promise:ok(value)
        end)
        :on_fail(function(err)
          next.promise:fail(err)
        end)
    end
  end)
end

return M
