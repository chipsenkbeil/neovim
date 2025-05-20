local M = {}

---Endpoint for the nvim image API.
---
---The API follows a simplistic, object-oriented design similar to `vim.system()`.
---You specify an image, optionally eagerly loading its data, and then display it
---within nvim. The information about where and how it is displayed is provided
---through a single table.
---
---Each image, once shown, returns a placement, which represents the specific
---instance of the image on screen. This is to support the separation of an
---image and its data from the details and management of displaying it.
---
---The image API makes use of an internal `Promise<T>` class in order to support
---both synchronous and asynchronous operation, meaning that images can be loaded,
---shown, hidden, and updated asynchronously in order to be efficient, but also can
---manually be waited upon at any stage.
---
---Examples in action
---
---```lua
----- Supports loading PNG images into memory
---local img = assert(vim.ui.img.load("/path/to/img.png"):wait())
---
----- Supports lazy-loading image for a provider to request later if needed
---local img = vim.ui.img.new("/path/to/img.png")
---
----- Supports specifying an image and explicitly providing the data
---local img = vim.ui.img.new({ bytes = "...", filename = "/path/to/img.png" })
---```
---
---Placements are instances of images that have been "placed" onto the screen
---in nvim. Whenever you show an image, a placement is created.
---
---```lua
----- Once created, an image can be shown, returning an object
----- deemed a "placement" that represents the instance
---local placement = img:show():wait() -- Places in top-left of editor with default size
---local placement = img:show({ pos = { x = 4, y = 8, unit = 'cell' }):wait()
---local placement = img:show({ relative = 'cursor' }):wait()
---```
---
---```lua
---local placement = assert(img:hide():wait())
---```
---
---```lua
---local img = vim.ui.img.new("/path/to/img.png")
---local placement = assert(img:show({ pos = { x = 1, y = 2, unit = 'cell' } }):wait())
---
----- Supports updating a displayed image with a new position
---placement:update({ pos = { x = 5, y = 6, unit = 'cell' } }):wait()
---
----- Supports resizing a displayed image
---placement:update({ size = { width = 10, height = 5, unit = "cell" } }):wait()
---
----- Of course, you can do all of this at the same time
---placement:update({
---    pos = { x = 5, y = 6, unit = 'cell' },
---    size = { width = 10, height = 5, unit = 'cell' },
---}):wait()
---```
---
---Backed by promises
---
---Each Promise<T> supports chaining callbacks for individual
---conditions of success or failure as well as combining the two
---together.
--
---The on_* methods can be called multiple times and each
---callback will be invoked when finished.
---
---You can also still choose to wait in a synchronous fashion
---using `:wait()` which supports supplying a specific timeout
---in milliseconds.
---
---```lua
---img:show({ ... })
---    :on_ok(function(placement)
---        -- Use the placement once it has been confirmed as shown
---    end)
---    :on_fail(function(err)
---        -- Do something with the error that occurred
---    end)
---    :on_done(function(err, placement)
---        -- When either ok or fail happens
---    end)
---```
---
---Using magic on images
---
---Leveraging *ImageMagick* for the functionality, the image API supports
---converting images into different formats as well as transforming them.
---This is particularly needed for sixel, which would normally require
---advanced image decoding to convert to an RGB format and then packaged in
---sixel's format.
---
---By default, the path to the magick binary is specified with the *imgprg* option.
---
---```lua
---vim.o.imgprg = 'magick'
---```
---
---ImageMagick supports features like cropping and resizing,
---which we expose through the `convert` method.
---
---```lua
---img:convert({
---    format = 'jpeg', -- Supports a variety of formats, including sixel!
---    size = { width = 50, height = 30, unit = 'pixel' },
---}):on_done(function(err, data)
---    -- By default, this returns the data of the image
---    -- instead of updating the instance or saving it
---    -- to disk
---    --
---    -- Use img:convert({ out = '/path/to/img.jpeg' })
---    -- to write to disk instead
---end)
---```
---
---Additionally, the image API provides a retrieval method called `identify`
---(modeled after `magick identify`) to inspect images without needing advanced
---header parsing per image format in order to learn details like the true image
---format (not just reading the file extension) and pixel dimensions of the image.
---
---```lua
---img:identify({ format = true, size = true }):on_done(function(err, info)
---    -- Info is a table containing the information requested by each
---    -- field marked true.
---    --
---    -- In this case,
---    -- info.format == "PNG"
---    -- info.size == vim.ui.img.utils.Size { width = 50, height = 30, unit = 'pixel' }
---    --
---    -- If the field is unsupported, it can still be rovided using
---    -- name = "format" syntax of ImageMagick.
---    --
---    -- img:identify({ depth = "%z" }) would capture image depth
---    -- as specified by ImageMagick's escape shorthand for metadata:
---    -- https://imagemagick.org/script/escape.php
---end)
---```
---
---Providing an implementation
---
---nvim comes with three providers that interface with various
---graphics protocols supported by |TUI|s and GUIs.
---
---1. kitty
---2. iterm2
---3. sixel
---
---The global provider to use with all placements is specified via the option,
---*imgprovider*, which is set to *kitty* by default. When the global provider
---is changed, the old provider is unloaded.
---
---```lua
---vim.o.imgprovider = 'kitty'
---```
---
---The image API also supports 3rd party provider integrations. To create a
---new provider, the implementer should leverage `vim.ui.img.providers.new()`.
---
---To register the provider such that it is accessible globally, the implementer
---should assign it with a name to the dictionary at `vim.ui.img.providers`.
---
---```lua
---vim.ui.img.providers['neovide'] = vim.ui.img.providers.new({
---    ---(Optional) Called to initialize the provider.
---    ---@param ... any arguments for the specific provider upon loading
---    load = function(...)
---      -- Implement here
---    end,
---
---    ---(Optional) Called to cleanup the provider.
---    unload = function()
---      -- Implement here
---    end,
---
---    ---(Optional) Reports whether this provider is supported in the current environment.
---    ---@param on_supported? fun(supported:boolean) callback when finished checking
---    supported = function(on_supported)
---        -- Implement here
---    end,
---
---    ---Displays an image, returning (through callback) an id tied to the instance.
---    ---@param img vim.ui.Image image data container to display
---    ---@param opts vim.ui.img.Opts specification of how to display the image
---    ---@param on_shown? fun(err:string|nil, id:integer|nil) callback when finished showing
---    ---@return integer id unique identifier connected to the displayed image (not vim.ui.Image)
---    show = function(img, opts, on_shown)
---        -- Implement here
---    end,
---
---    ---Hides one or more displayed images.
---    ---@param ids integer[] list of displayed image ids to hide
---    ---@param on_hidden fun(err:string|nil, ids:integer[]|nil) callback when finished hiding
---    hide = function(ids, on_hidden)
---        -- Implement here
---    end,
---
---    ---(Optional) Updates an image, returning (through callback) a refreshed id tied to the instance.
---    ---If not specified, nvim will invoke `hide(id)` followed by `show(img, opts, on_updated)`.
---    ---@param id integer id of the displayed image to update
---    ---@param opts vim.ui.img.Opts specification of how to display the image
---    ---@param on_updated? fun(err:string|nil, id:integer|nil) callback when finished updating
---    ---@return integer id unique identifier connected to the displayed image (not vim.ui.Image)
---    update = function(id, opts, on_updated)
---        -- Implement here
---    end,
---})
---```
M.img = require('vim.ui.img')

--- Prompts the user to pick from a list of items, allowing arbitrary (potentially asynchronous)
--- work until `on_choice`.
---
--- Example:
---
--- ```lua
--- vim.ui.select({ 'tabs', 'spaces' }, {
---     prompt = 'Select tabs or spaces:',
---     format_item = function(item)
---         return "I'd like to choose " .. item
---     end,
--- }, function(choice)
---     if choice == 'spaces' then
---         vim.o.expandtab = true
---     else
---         vim.o.expandtab = false
---     end
--- end)
--- ```
---
---@generic T
---@param items T[] Arbitrary items
---@param opts table Additional options
---     - prompt (string|nil)
---               Text of the prompt. Defaults to `Select one of:`
---     - format_item (function item -> text)
---               Function to format an
---               individual item from `items`. Defaults to `tostring`.
---     - kind (string|nil)
---               Arbitrary hint string indicating the item shape.
---               Plugins reimplementing `vim.ui.select` may wish to
---               use this to infer the structure or semantics of
---               `items`, or the context in which select() was called.
---@param on_choice fun(item: T|nil, idx: integer|nil)
---               Called once the user made a choice.
---               `idx` is the 1-based index of `item` within `items`.
---               `nil` if the user aborted the dialog.
function M.select(items, opts, on_choice)
  vim.validate('items', items, 'table')
  vim.validate('on_choice', on_choice, 'function')
  opts = opts or {}
  local choices = { opts.prompt or 'Select one of:' }
  local format_item = opts.format_item or tostring
  for i, item in
    ipairs(items --[[@as any[] ]])
  do
    table.insert(choices, string.format('%d: %s', i, format_item(item)))
  end
  local choice = vim.fn.inputlist(choices)
  if choice < 1 or choice > #items then
    on_choice(nil, nil)
  else
    on_choice(items[choice], choice)
  end
end

--- Prompts the user for input, allowing arbitrary (potentially asynchronous) work until
--- `on_confirm`.
---
--- Example:
---
--- ```lua
--- vim.ui.input({ prompt = 'Enter value for shiftwidth: ' }, function(input)
---     vim.o.shiftwidth = tonumber(input)
--- end)
--- ```
---
---@param opts table? Additional options. See |input()|
---     - prompt (string|nil)
---               Text of the prompt
---     - default (string|nil)
---               Default reply to the input
---     - completion (string|nil)
---               Specifies type of completion supported
---               for input. Supported types are the same
---               that can be supplied to a user-defined
---               command using the "-complete=" argument.
---               See |:command-completion|
---     - highlight (function)
---               Function that will be used for highlighting
---               user inputs.
---@param on_confirm function ((input|nil) -> ())
---               Called once the user confirms or abort the input.
---               `input` is what the user typed (it might be
---               an empty string if nothing was entered), or
---               `nil` if the user aborted the dialog.
function M.input(opts, on_confirm)
  vim.validate('opts', opts, 'table', true)
  vim.validate('on_confirm', on_confirm, 'function')

  opts = (opts and not vim.tbl_isempty(opts)) and opts or vim.empty_dict()

  -- Note that vim.fn.input({}) returns an empty string when cancelled.
  -- vim.ui.input() should distinguish aborting from entering an empty string.
  local _canceled = vim.NIL
  opts = vim.tbl_extend('keep', opts, { cancelreturn = _canceled })

  local ok, input = pcall(vim.fn.input, opts)
  if not ok or input == _canceled then
    on_confirm(nil)
  else
    on_confirm(input)
  end
end

--- Opens `path` with the system default handler (macOS `open`, Windows `explorer.exe`, Linux
--- `xdg-open`, …), or returns (but does not show) an error message on failure.
---
--- Can also be invoked with `:Open`. [:Open]()
---
--- Expands "~/" and environment variables in filesystem paths.
---
--- Examples:
---
--- ```lua
--- -- Asynchronous.
--- vim.ui.open("https://neovim.io/")
--- vim.ui.open("~/path/to/file")
--- -- Use the "osurl" command to handle the path or URL.
--- vim.ui.open("gh#neovim/neovim!29490", { cmd = { 'osurl' } })
--- -- Synchronous (wait until the process exits).
--- local cmd, err = vim.ui.open("$VIMRUNTIME")
--- if cmd then
---   cmd:wait()
--- end
--- ```
---
---@param path string Path or URL to open
---@param opt? { cmd?: string[] } Options
---     - cmd string[]|nil Command used to open the path or URL.
---
---@return vim.SystemObj|nil # Command object, or nil if not found.
---@return nil|string # Error message on failure, or nil on success.
---
---@see |vim.system()|
function M.open(path, opt)
  vim.validate('path', path, 'string')
  local is_uri = path:match('%w+:')
  if not is_uri then
    path = vim.fs.normalize(path)
  end

  opt = opt or {}
  local cmd ---@type string[]
  local job_opt = { text = true, detach = true } --- @type vim.SystemOpts

  if opt.cmd then
    cmd = vim.list_extend(opt.cmd --[[@as string[] ]], { path })
  elseif vim.fn.has('mac') == 1 then
    cmd = { 'open', path }
  elseif vim.fn.has('win32') == 1 then
    if vim.fn.executable('rundll32') == 1 then
      cmd = { 'rundll32', 'url.dll,FileProtocolHandler', path }
    else
      return nil, 'vim.ui.open: rundll32 not found'
    end
  elseif vim.fn.executable('xdg-open') == 1 then
    cmd = { 'xdg-open', path }
    job_opt.stdout = false
    job_opt.stderr = false
  elseif vim.fn.executable('wslview') == 1 then
    cmd = { 'wslview', path }
  elseif vim.fn.executable('explorer.exe') == 1 then
    cmd = { 'explorer.exe', path }
  elseif vim.fn.executable('lemonade') == 1 then
    cmd = { 'lemonade', 'open', path }
  else
    return nil, 'vim.ui.open: no handler found (tried: wslview, explorer.exe, xdg-open, lemonade)'
  end

  return vim.system(cmd, job_opt), nil
end

--- Returns all URLs at cursor, if any.
--- @return string[]
function M._get_urls()
  local urls = {} ---@type string[]

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, -1, { row, col }, { row, col }, {
    details = true,
    type = 'highlight',
    overlap = true,
  })
  for _, v in ipairs(extmarks) do
    local details = v[4]
    if details and details.url then
      urls[#urls + 1] = details.url
    end
  end

  local highlighter = vim.treesitter.highlighter.active[bufnr]
  if highlighter then
    local range = { row, col, row, col }
    local ltree = highlighter.tree:language_for_range(range)
    local lang = ltree:lang()
    local query = vim.treesitter.query.get(lang, 'highlights')
    if query then
      local tree = assert(ltree:tree_for_range(range))
      for _, match, metadata in query:iter_matches(tree:root(), bufnr, row, row + 1) do
        for id, nodes in pairs(match) do
          for _, node in ipairs(nodes) do
            if vim.treesitter.node_contains(node, range) then
              local url = metadata[id] and metadata[id].url
              if url and match[url] then
                for _, n in
                  ipairs(match[url] --[[@as TSNode[] ]])
                do
                  urls[#urls + 1] =
                    vim.treesitter.get_node_text(n, bufnr, { metadata = metadata[url] })
                end
              end
            end
          end
        end
      end
    end
  end

  if #urls == 0 then
    -- If all else fails, use the filename under the cursor
    table.insert(
      urls,
      vim._with({ go = { isfname = vim.o.isfname .. ',@-@' } }, function()
        return vim.fn.expand('<cfile>')
      end)
    )
  end

  return urls
end

return M
