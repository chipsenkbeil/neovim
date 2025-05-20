local M = {}

---@alias vim.ui.img.utils.Unit 'cell'|'pixel'

---@class vim.ui.img.utils.Codes
M.codes = {
  ---Hides the cursor from being shown in terminal.
  CURSOR_HIDE = '\027[?25l',
  ---Restore cursor position based on last save.
  CURSOR_RESTORE = '\0278',
  ---Save cursor position to be restored later.
  CURSOR_SAVE = '\0277',
  ---Shows the cursor if it was hidden in terminal.
  CURSOR_SHOW = '\027[?25h',
  ---Queries the terminal for its background color.
  QUERY_BACKGROUND_COLOR = '\027]11;?',
  ---Disable synchronized output mode.
  SYNC_MODE_DISABLE = '\027[?2026l',
  ---Enable synchronized output mode.
  SYNC_MODE_ENABLE = '\027[?2026h',
}

---Generates the escape code to move the cursor.
---Rounds down the column and row values.
---@param opts {row:number, col:number}
---@return string
function M.codes.move_cursor(opts)
  return string.format('\027[%s;%sH', math.floor(opts.row), math.floor(opts.col))
end

---Wraps one or more escape sequences for use with tmux passthrough.
---@param s string
---@return string
function M.codes.escape_tmux_passthrough(s)
  return ('\027Ptmux;' .. string.gsub(s, '\027', '\027\027')) .. '\027\\'
end

---@class (exact) vim.ui.img.utils.Rgb
---@field bit 8|16 how many bits
---@field r integer
---@field g integer
---@field b integer

---Attempts to match the OSC 11 terminal response to get the RGB values.
---@param s string
---@return vim.ui.img.utils.Rgb|nil
function M.codes.match_osc_11_response(s)
  local r, g, b = string.match(s, '\027]11;rgb:(%x+)/(%x+)/(%x+)')
  if r and g and b then
    -- Some terminals return AA/BB/CC (8-bit color)
    -- and others return AAAA/BBBB/CCCC (16-bit color)
    local bit = 8
    if string.len(r) > 2 or string.len(g) > 2 or string.len(b) > 2 then
      bit = 16
    end

    -- Cast our hexidecimal values to integers
    local rn = tonumber('0x' .. r)
    local gn = tonumber('0x' .. g)
    local bn = tonumber('0x' .. b)

    if rn and gn and bn then
      return { bit = bit, r = rn, g = gn, b = bn }
    end
  end
end

---Queries the terminal, sending some `query`, and waiting for an appropriate response.
---If `on_response` returns a non-nil value, that is considered a match.
---Defaults to 1000ms for `timeout`.
---@generic T
---@param query string
---@param opts? {timeout?:integer, write?:fun(...:string)}
---@param on_response fun(sequence:string, abort:fun()):(T|nil)
---@return vim.ui.img.utils.Promise<T>
function M.query_term(query, opts, on_response)
  opts = opts or {}
  local timeout = opts.timeout or 1000
  local write = opts.write or function(...)
    io.stdout:write(...)
  end

  local promise = require('vim.ui.img.utils.promise').new({
    context = 'utils.query_term',
  })

  local timer, err = vim.uv.new_timer()
  if err or not timer then
    promise:fail(err or 'failed to create libuv timer')
    return promise
  end

  ---@type fun(reason:string, ...:any):fun()
  local abort_fn

  local id = vim.api.nvim_create_autocmd('TermResponse', {
    callback = function(args)
      local seq = args.data.sequence ---@type string
      local value = on_response(seq, abort_fn('aborted'))
      if value ~= nil then
        timer:stop()
        timer:close()
        pcall(promise.ok, promise, value)
        return true
      end
    end,
  })

  abort_fn = function(reason, ...)
    local args = { ... }
    return vim.schedule_wrap(function()
      pcall(vim.api.nvim_del_autocmd, id)
      pcall(promise.fail, promise, string.format(reason, unpack(args)))
    end)
  end

  write(query)

  timer:start(timeout, 0, abort_fn('no response after %sms', timeout))

  return promise
end

---Queries the terminal for its background color using OSC 11.
---@param opts? {timeout?:integer, write?:fun(...:string)}
---@return vim.ui.img.utils.Promise<vim.ui.img.utils.Rgb>
function M.query_term_background_color(opts)
  return M.query_term(M.codes.QUERY_BACKGROUND_COLOR, opts, M.codes.match_osc_11_response)
end

---Returns the hex string (e.g. #ABCDEF) representing the color of the background.
---
---Attempt to detect the background color in two ways:
---1. Check if our global Normal is available and use it
---2. Query the terminal for a background color
---
---If neither is available, we don't attempt to set
---the alpha pixels to a background color
---@param opts? {timeout?:integer, write?:fun(...:string)}
---@return vim.ui.img.utils.Promise<string>
function M.query_bg_hex_str(opts)
  local promise = require('vim.ui.img.utils.promise').new({
    context = 'utils.query_bg_hex_str',
  })

  local bg = vim.api.nvim_get_hl(0, { name = 'Normal' }).bg
  local bg_color = bg and string.format('#%06x', bg)
  if bg_color then
    promise:ok(bg_color)
    return promise
  end

  ---@cast opts {timeout?:integer, write?:fun(...:string)}|nil
  M.query_term_background_color(opts)
    :on_ok(function(rgb)
      ---@type number
      local r = rgb.bit == 8 and rgb.r or ((rgb.r / 65535) * 255)
      ---@type number
      local g = rgb.bit == 8 and rgb.g or ((rgb.g / 65535) * 255)
      ---@type number
      local b = rgb.bit == 8 and rgb.b or ((rgb.b / 65535) * 255)
      promise:ok(string.format('#%02x%02x%02x', r, g, b))
    end)
    :on_fail(function(err)
      promise:fail(err)
    end)

  return promise
end

---Splits a string, whitespace-delimited, factoring in quoted items.
---@param s string
---@return string[]
function M.split_quoted(s)
  local components = {}

  local component = {}
  local in_escape = false
  local in_single = false
  local in_double = false

  for i = 1, string.len(s) do
    local c = string.sub(s, i, i)
    if in_escape then
      table.insert(component, c)
      in_escape = false
    elseif c == '\\' then
      in_escape = true
    elseif c == "'" and not in_double then
      in_single = not in_single
    elseif c == '"' and not in_single then
      in_double = not in_double
    elseif string.match(c, '%s') and not in_single and not in_double then
      -- When we hit whitespace and have non-empty component,
      -- then we have reached the end of a component
      if #component > 0 then
        table.insert(components, table.concat(component))
        component = {}
      end
    else
      table.insert(component, c)
    end
  end

  -- Catch the final component if we have one,
  -- since it may not have been terminated in
  -- the above loop
  if #component > 0 then
    table.insert(components, table.concat(component))
  end

  return components
end

---Creates a writer that will wait to send all bytes together.
---@param opts? {use_chan_send?:boolean, map?:(fun(s:string):string), multi?:boolean, write?:fun(...:string)}
---@return vim.ui.img.utils.BatchWriter
function M.new_batch_writer(opts)
  opts = opts or {}

  ---@class vim.ui.img.utils.BatchWriter
  ---@field private __queue string[]
  local writer = {
    __queue = {},
  }

  ---Queues up bytes to be written later.
  ---@param ... string
  function writer.write(...)
    vim.list_extend(writer.__queue, { ... })
  end

  ---Queues up bytes to be written later, using a format string.
  ---@param s string|number
  ---@param ... any
  function writer.write_format(s, ...)
    writer.write(string.format(s, ...))
  end

  ---Writes immediately skipping queue.
  ---@param ... string
  function writer.write_fast(...)
    writer.__write(writer.__concat(...))
  end

  ---Clears any queued bytes without sending them.
  function writer.clear()
    writer.__queue = {}
  end

  ---Flushes the bytes, sending them all together.
  function writer.flush()
    -- If nothing in the queue, don't write anything at all
    if #writer.__queue == 0 then
      return
    end

    ---@type string
    local bytes

    -- If multi specified, instead of concatentating all of the
    -- bytes together, we instead map each individually
    --
    -- Otherwise, we combine all bytes together and then map
    if opts.multi then
      bytes = writer.__concat(unpack(writer.__queue))
    else
      bytes = writer.__concat(table.concat(writer.__queue))
    end

    writer.__queue = {}
    writer.__write(bytes)
  end

  ---Transforms multiple bytes into a single sequence, mapping
  ---each individual series of bytes if we have a map function.
  ---@param ... string
  ---@return string
  function writer.__concat(...)
    ---@param s string
    return table.concat(vim.tbl_map(function(s)
      return opts.map and opts.map(s) or s
    end, { ... }))
  end

  ---@private
  ---@param bytes string
  function writer.__write(bytes)
    -- Depending on the configuration, will write one of three ways:
    --
    -- 1. Writes bytes using `opts.write()`
    -- 2. Writes bytes to stdout using `vim.api.nvim_chan_send()` to ensure that
    --    larger messages properly make use of errno to EAGAIN as mentioned in #26688
    -- 3. Writes bytes using `io.stdout:write()`
    if opts.write then
      opts.write(bytes)
    elseif opts.use_chan_send then
      vim.api.nvim_chan_send(2, bytes)
    else
      io.stdout:write(bytes)
      io.stdout:flush()
    end
  end

  ---@cast writer -function
  return writer
end

return M
