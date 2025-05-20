---Id of the last image created.
---@type integer
local LAST_IMAGE_ID = 0

---@class vim.ui.Image
---@field id integer unique id associated with the image
---@field bytes string|nil bytes of the image loaded into memory
---@field filename string path to the image on disk
---@field private __metadata vim.ui.img.Metadata
local M = {}
M.__index = M

---Path to the directory where images may be cached.
---@type string
---@diagnostic disable-next-line:param-type-mismatch
M.cache_dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'img')

---Collection of names to associated providers used to display and manipulate images.
---@type vim.ui.img.Providers
M.providers = require('vim.ui.img.providers')

---Creates a new image instance, optionally taking pre-loaded bytes.
---@param opts string|{bytes?:string, filename:string}
---@return vim.ui.Image
function M.new(opts)
  vim.validate('opts', opts, { 'string', 'table' })
  if type(opts) == 'table' then
    vim.validate('opts.bytes', opts.bytes, 'string', true)
    vim.validate('opts.filename', opts.filename, 'string')
  end

  local instance = {}
  setmetatable(instance, M)

  instance.id = LAST_IMAGE_ID + 1
  instance.__metadata = {}
  if type(opts) == 'table' then
    instance.bytes = opts.bytes
    instance.filename = opts.filename
  elseif type(opts) == 'string' then
    instance.filename = opts
  end

  -- Bump our counter for future image ids
  LAST_IMAGE_ID = instance.id

  return instance
end

---Loads bytes for an image from a local file.
---@param filename string
---@return vim.ui.img.utils.Promise<vim.ui.Image>
function M.load(filename)
  local promise = require('vim.ui.img.utils.promise').new({
    context = 'image.load',
  })

  local img = M.new({ filename = filename })
  img
    :reload()
    :on_ok(function()
      promise:ok(img)
    end)
    :on_fail(function(err)
      promise:fail(err)
    end)

  return promise
end

---Reloads the bytes for an image from its filename.
---@return vim.ui.img.utils.Promise<vim.NIL>
function M:reload()
  local filename = self.filename
  local promise = require('vim.ui.img.utils.promise').new({
    context = 'image.reload',
  })

  ---@param err string|nil
  ---@return boolean
  local function report_err(err)
    if err then
      promise:fail(err)
    end

    return err ~= nil
  end

  vim.uv.fs_stat(filename, function(stat_err, stat)
    if report_err(stat_err) then
      return
    end
    if not stat then
      report_err('missing stat')
      return
    end

    vim.uv.fs_open(filename, 'r', 644, function(open_err, fd)
      if report_err(open_err) then
        return
      end
      if not fd then
        report_err('missing fd')
        return
      end

      vim.uv.fs_read(fd, stat.size, -1, function(read_err, bytes)
        if report_err(read_err) then
          return
        end

        self.bytes = bytes or ''
        self.filename = filename

        vim.uv.fs_close(fd, function()
          promise:ok(vim.NIL)
        end)
      end)
    end)
  end)

  return promise
end

---Returns the byte length of the image's bytes, or 0 if not loaded.
---@return integer
function M:len()
  return string.len(self.bytes or '')
end

---Returns a hash (sha256) of the image's bytes.
---@return string
function M:hash()
  return vim.fn.sha256(self.bytes or '')
end

---Check if the image is PNG format, optionally loading the magic number of the image.
---Will throw an error if unable to load the bytes of the file.
---Works without ImageMagick.
---@return boolean
function M:is_png()
  if self.__metadata.format == 'PNG' then
    return true
  end

  ---Magic number of a PNG file.
  ---@type string
  local PNG_SIGNATURE = '\137PNG\r\n\26\n'

  -- Use loaded bytes, or synchronously load the file magic number
  local bytes = self.bytes
  if not bytes then
    local fd = assert(vim.uv.fs_open(self.filename, 'r', 0))
    bytes = assert(vim.uv.fs_read(fd, 8, nil)) or ''
    vim.uv.fs_close(fd, function() end)
  end

  local is_png = string.sub(bytes, 1, #PNG_SIGNATURE) == PNG_SIGNATURE
  if is_png then
    self.__metadata.format = 'PNG'
  end
  return is_png
end

---Converts this image into a PNG version.
---Default compression is 7 and filter type is 5.
---@param opts? {compression?:0|1|2|3|4|5|6|7|8|9, filter?:0|1|2|3|4|5|6|7|8|9, force?:boolean}
---@return vim.ui.img.utils.Promise<vim.ui.Image>
function M:into_png(opts)
  opts = opts or {}
  local promise = require('vim.ui.img.utils.promise').new({
    context = 'image.into_png',
  })

  -- If true and trying to use cache, will force recreation
  local force = opts.force or false
  local compression = opts.compression
  local filter_type = opts.filter

  ---@type integer|nil
  local quality = nil
  if compression or filter_type then
    quality = ((compression or 7) * 10) + ((filter_type or 5) % 10)
  end

  -- If image is a png, we are good to show it as is,
  -- otherwise we'll need to convert it to a png
  if self:is_png() and not force then
    return promise:ok(self)
  end

  local cache_dir = M.cache_dir
  assert(vim.fn.mkdir(cache_dir, 'p') == 1, 'failed to create ' .. cache_dir)

  vim.uv.fs_realpath(
    self.filename,
    vim.schedule_wrap(function(err_realpath, path)
      if err_realpath then
        promise:fail(err_realpath)
        return
      end

      -- Cached output image uses a sha256 of the full path to the original file
      -- so we don't accidentally use a previously-cached image with a similar name
      local out = vim.fs.joinpath(cache_dir, string.format('%s.png', vim.fn.sha256(path)))
      local png = vim.ui.img.new(out)

      -- Check if the image already exists
      vim.uv.fs_stat(out, function(_, stat)
        if stat and not force then
          png
            :into_png(opts)
            :on_ok(function()
              promise:ok(png)
            end)
            :on_fail(function(err)
              promise:fail(err)
            end)
        else
          self
            :convert({ format = 'png', out = out, quality = quality })
            :on_ok(function()
              promise:ok(png)
            end)
            :on_fail(function(err)
              promise:fail(err)
            end)
        end
      end)
    end)
  )

  return promise
end

---@class vim.ui.img.IdentifyOpts
---@field format? boolean
---@field size? boolean
---@field [string] string|nil

---@class vim.ui.img.Metadata
---@field format? string
---@field size? vim.ui.img.utils.Size
---@field [string] string|nil

---Returns information about the image by invoking ImageMagick's identify.
---This will be some uppercase string like 'PNG'.
---@param opts? vim.ui.img.IdentifyOpts
---@return vim.ui.img.utils.Promise<vim.ui.img.Metadata>
function M:identify(opts)
  opts = opts or {}
  local promise = require('vim.ui.img.utils.promise').new({
    context = 'image.identify',
  })

  -- If everything we want is already cached, return it
  local has_everything = true
  ---@cast opts table<string, string|boolean>
  for name, want in pairs(opts) do
    if want and self.__metadata[name] == nil then
      has_everything = false
      break
    end
  end

  if has_everything then
    return promise:ok(self.__metadata)
  end

  -- Schedule now to allow access to the ImageMagick option
  -- in the case that we're currently in a fast function
  vim.schedule(function()
    -- Build a string representing our format in json
    local format = {
      format = opts.format and '%m' or nil,
      width = opts.size and '%w' or nil,
      height = opts.size and '%h' or nil,
    }

    -- Support extra requests that follow ImageMagick's escape formatting
    -- E.g. ["depth"] = "%z" will include the image depth as "depth"
    for name, value in pairs(opts) do
      if type(value) == 'string' then
        format[name] = value
      end
    end

    ---@type string[]
    local cmd = require('vim.ui.img.utils').split_quoted(vim.o.imgprg)
    vim.list_extend(cmd, {
      'identify',
      '-format',
      vim.json.encode(format),
      self.filename,
    })

    local ok, err = pcall(vim.system, cmd, nil, function(out)
      if out.code ~= 0 then
        promise:fail(out.stderr and out.stderr or 'failed to identify image')
        return
      end

      local data = out.stdout
      if not data or data == '' then
        promise:fail('failed to identify image')
        return
      end

      ---@type boolean, table<string, string>|string
      local ok, tbl_or_err = pcall(vim.json.decode, vim.trim(data), {
        array = true,
        object = true,
      })
      if not ok then
        ---@cast tbl_or_err string
        promise:fail(tbl_or_err)
        return
      else
        ---@cast tbl_or_err -string
        local tbl = tbl_or_err

        local size = nil
        if tbl.width and tbl.height then
          local width = tonumber(tbl.width)
          local height = tonumber(tbl.height)
          if width and height then
            size = require('vim.ui.img.utils.size').new({
              width = width,
              height = height,
              unit = 'pixel',
            })
          end
        end

        -- Update our cached metadata
        self.__metadata.format = tbl.format or self.__metadata.format
        self.__metadata.size = size or self.__metadata.size

        promise:ok({
          format = tbl.format,
          size = size,
        })
      end
    end)

    if not ok then
      ---@cast err +string
      ---@cast err -vim.SystemObj
      promise:fail(err)
    end
  end)

  return promise
end

---Returns an iterator over the chunks of the image, returning the chunk, byte position, and
---an indicator of whether the current chunk is the last chunk.
---
---If `base64=true`, will encode the bytes using base64 before iterating chunks.
---Takes an optional size to indicate how big each chunk should be, defaulting to 4096.
---
---Examples:
---
---```lua
----- Some predefined image
---local img = vim.ui.img.new({ ... })
---
------@param chunk string
------@param pos integer
------@param last boolean
---img:chunks():each(function(chunk, pos, last)
---  vim.print("Chunk bytes", chunk)
---  vim.print("Chunk starts at", pos)
---  vim.print("Is last chunk", last)
---end)
---```
---
---@param opts? {base64?:boolean, size?:integer}
---@return Iter
function M:chunks(opts)
  opts = opts or {}

  -- Chunk size, defaulting to 4k
  local chunk_size = opts.size or 4096

  local bytes = self.bytes
  if not bytes or bytes == '' then
    return vim.iter(function()
      return nil, nil, nil
    end)
  end

  if opts.base64 then
    bytes = vim.base64.encode(bytes)
  end

  local pos = 1
  local len = string.len(bytes)

  return vim.iter(function()
    -- If we are past the last chunk, this iterator should terminate
    if pos > len then
      return nil, nil, nil
    end

    -- Get our next chunk from [pos, pos + chunk_size)
    local end_pos = pos + chunk_size - 1
    local chunk = bytes:sub(pos, end_pos)

    -- If we have a chunk available, mark as such
    local last = true
    if string.len(chunk) > 0 then
      last = not (end_pos + 1 <= len)
    end

    -- Mark where our current chunk is positioned
    local chunk_pos = pos

    -- Update our global position
    pos = end_pos + 1

    return chunk, chunk_pos, last
  end)
end

---@class (exact) vim.ui.img.ConvertOpts
---@field background? string hex string representing background color
---@field crop? vim.ui.img.utils.Region
---@field format? string such as 'png', 'rgb', or 'sixel' (default 'png')
---@field out? string write to output instead of stdout
---@field quality? integer default for PNG is 75 (see https://imagemagick.org/script/command-line-options.php#quality)
---@field size? vim.ui.img.utils.Size
---@field timeout? integer maximum time (in milliseconds) to wait for conversion

---Converts an image using ImageMagick, returning the bytes of the new image.
---
---If `background` is specified, will convert alpha pixels to the background color (e.g. #ABCDEF).
---If `crop` is specified, will crop the image to the specified pixel dimensions.
---If `format` is specified, will convert to the image format, defaulting to png.
---If `out` is specified, will treat as output file and write to it, and promise returns empty str.
---If `size` is specified, will resize the image to the desired size.
---@param opts? vim.ui.img.ConvertOpts
---@return vim.ui.img.utils.Promise<string>
function M:convert(opts)
  opts = opts or {}

  local promise = require('vim.ui.img.utils.promise').new({
    context = 'image.convert',
  })

  -- Schedule now to allow access to the ImageMagick option
  -- in the case that we're currently in a fast function
  vim.schedule(function()
    ---@type string[]
    local cmd = require('vim.ui.img.utils').split_quoted(vim.o.imgprg)
    table.insert(cmd, 'convert')
    table.insert(cmd, self.filename)

    if opts.background then
      table.insert(cmd, '-background')
      table.insert(cmd, opts.background)
      table.insert(cmd, '-flatten')
    end
    if opts.crop then
      local region = opts.crop:to_pixels()
      table.insert(cmd, '-crop')
      table.insert(
        cmd,
        string.format('%sx%s+%s+%s', region.width, region.height, region.x, region.y)
      )
    end
    if opts.size then
      local size_px = opts.size:to_pixels()
      table.insert(cmd, '-resize')
      table.insert(cmd, string.format('%sx%s', size_px.width, size_px.height))
    end

    if opts.quality then
      table.insert(cmd, '-quality')
      table.insert(cmd, tostring(opts.quality))
    end

    local format = opts.format or 'png'
    local output = opts.out or '-'
    table.insert(cmd, format .. ':' .. output)

    local ok, err = pcall(vim.system, cmd, nil, function(out)
      if out.code ~= 0 then
        promise:fail(out.stderr and out.stderr or 'failed to convert image')
        return
      end

      -- In the case we wrote to a file, there's nothing to capture
      if opts.out ~= nil then
        promise:ok('')
        return
      end

      local data = out.stdout
      if not data or data == '' then
        promise:fail('converted image output missing')
        return
      end

      promise:ok(data)
    end)

    if not ok then
      ---@cast err +string
      ---@cast err -vim.SystemObj
      promise:fail(err)
    end
  end)

  return promise
end

---Displays an image, returning a reference to its visual representation (placement).
---```lua
---local img = ...
---
-----Can be invoked synchronously
---local placement = assert(img:show({ ... }):wait())
---
-----Can also be invoked asynchronously
---img:show({ ... }):on_done(function(err, placement)
---  -- Do something
---end)
---```
---@param opts? vim.ui.img.Opts|{provider?:string}
---@return vim.ui.img.utils.Promise<vim.ui.img.Placement>
function M:show(opts)
  local promise = require('vim.ui.img.utils.promise').new({
    context = 'image.show',
  })

  local placement = self:new_placement(opts)
  placement
    :show(opts)
    :on_ok(function()
      promise:ok(placement)
    end)
    :on_fail(function(err)
      promise:fail(err)
    end)

  return promise
end

---Creates a placement of this image that is not yet visible.
---@param opts? {provider?:string}
---@return vim.ui.img.Placement
function M:new_placement(opts)
  return require('vim.ui.img.placement').new(self, opts)
end

return M
