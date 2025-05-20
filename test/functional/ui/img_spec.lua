local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local eq = t.eq

local fn = n.fn
local clear = n.clear
local exec_lua = n.exec_lua
local testprg = n.testprg

---Max time to wait for an operation to complete in our tests.
---@type integer
local TEST_TIMEOUT = 10000

---4x4 PNG image that can be written to disk.
---@type string
-- stylua: ignore
local PNG_IMG_BYTES = string.char(unpack({
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 4, 0,
  0, 0, 4, 8, 6, 0, 0, 0, 169, 241, 158, 126, 0, 0, 0, 1, 115, 82, 71, 66, 0,
  174, 206, 28, 233, 0, 0, 0, 39, 73, 68, 65, 84, 8, 153, 99, 252, 207, 192,
  240, 159, 129, 129, 129, 193, 226, 63, 3, 3, 3, 3, 3, 3, 19, 3, 26, 96, 97,
  156, 1, 145, 250, 207, 184, 12, 187, 10, 0, 36, 189, 6, 125, 75, 9, 40, 46,
  0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
}))

---@param s string
---@return string
local function escape_ansi(s)
  return (
    string.gsub(s, '.', function(c)
      local byte = string.byte(c)
      if byte < 32 or byte == 127 then
        return string.format('\\%03d', byte)
      else
        return c
      end
    end)
  )
end

---@param s string
---@return string
local function base64_encode(s)
  return exec_lua(function()
    return vim.base64.encode(s)
  end)
end

---Sets up the provider `name` to write data to a global `_G.data`.
---@param name string
local function setup_provider(name)
  exec_lua(function()
    _G.data = {}
    vim.o.imgprovider = name

    -- Eagerly load the provider so we can inject a function
    -- to capture the output being written
    vim.ui.img.providers.load(name, {
      write = function(...)
        vim.list_extend(_G.data, { ... })
      end,
    })
  end)
end

---Configures ImageMagick using test program that simulates output and can save input.
---1. `stdout` is the text to print to stdout when the program is run.
---2. `stderr` is the text to print to stderr when the program is run.
---3. `args` is the file where arguments after -- are saved for reading later.
---4. `exit` is the exit code to use when the program returns (default 0).
---@param opts? {stdout?:string, stderr?:string, args?:string, exit?:integer}
local function setup_magick(opts)
  opts = opts or {}
  local cmd = { testprg('printio-test') }

  if opts.stdout then
    local filename = t.tmpname(true)
    t.write_file(filename, opts.stdout, true, false)
    table.insert(cmd, '-o')
    table.insert(cmd, filename)
  end

  if opts.stderr then
    local filename = t.tmpname(true)
    t.write_file(filename, opts.stderr, true, false)
    table.insert(cmd, '-e')
    table.insert(cmd, filename)
  end

  if opts.args then
    table.insert(cmd, '-a')
    table.insert(cmd, opts.args)
  end

  if opts.exit then
    table.insert(cmd, '-x')
    table.insert(cmd, tostring(opts.exit))
  end

  table.insert(cmd, '--')

  exec_lua(function()
    vim.o.imgprg = table.concat(cmd, ' ')
  end)
end

---Executes zero or more operations for the image at `filename`.
---
---If operation `show`, will create a placement using `opts` and store as `id` for future ops.
---If operation `hide`, will hide a placement referenced by `id`.
---If operation `update`, will update a placement using `opts` referenced by `id`.
---If operation 'clear', will wipe the output data at that point in processing operations.
---
---Note that `bytes` can be supplied during `show` operation to supply them to the image.
---
---Returns the output from executing the following operations.
---@param ... { op:'show'|'hide'|'update'|'clear', id?:integer, bytes?:string, filename?:string, opts?:vim.ui.img.Opts }
---@return string output
local function img_execute(...)
  local args = { ... }

  return exec_lua(function()
    ---@type table<string, vim.ui.Image>
    local images = {}

    ---@type table<integer, vim.ui.img.Placement>
    local placements = {}

    -- Reset our data to make sure we start clean
    _G.data = {}

    for _, arg in ipairs(args) do
      if arg.op == 'show' then
        -- Create the image (if first time) without loading as some providers need
        -- the data while others do not
        local opts = {
          bytes = arg.bytes,
          filename = assert(arg.filename, 'operation show requires a filename'),
        }
        local img = images[opts.filename] or vim.ui.img.new(opts)
        images[opts.filename] = img

        -- Perform the actual show operation
        local placement = assert(img:show(arg.opts):wait({ timeout = TEST_TIMEOUT }))

        -- Save the placement if we were given an id to refer to it later
        local id = arg.id
        if id then
          placements[id] = placement
        end
      elseif arg.op == 'hide' then
        local id = assert(arg.id, 'operation hide requires an id')
        local placement = assert(placements[id], 'no placement with id ' .. tostring(id))
        placement:hide():wait({ timeout = TEST_TIMEOUT })
      elseif arg.op == 'update' then
        local id = assert(arg.id, 'operation update requires an id')
        local placement = assert(placements[id], 'no placement with id ' .. tostring(id))
        placement:update(arg.opts):wait({ timeout = TEST_TIMEOUT })
      elseif arg.op == 'clear' then
        _G.data = {}
      end
    end

    return table.concat(_G.data)
  end)
end

---Loads an image, returning its data as bytes.
---@param filename string
---@return string bytes
local function img_load(filename)
  return exec_lua(function()
    local img = assert(vim.ui.img.load(filename):wait({ timeout = TEST_TIMEOUT }))
    return img.bytes
  end)
end

describe('ui/img', function()
  ---@type string
  local img_filename

  before_each(function()
    clear()

    -- Create the image on disk in a temporary location
    img_filename = t.tmpname(true)
    t.write_file(img_filename, PNG_IMG_BYTES, true, false)
  end)

  it('should be able to load an image from disk', function()
    -- Synchronous loading from disk
    ---@type vim.ui.Image
    local sync_img = exec_lua(function()
      return assert(vim.ui.img.load(img_filename):wait())
    end)

    eq(img_filename, sync_img.filename)
    eq(PNG_IMG_BYTES, sync_img.bytes)
  end)

  it('should unload the old provider when vim.o.imgprovider changes', function()
    ---@type boolean
    local was_unloaded = exec_lua(function()
      local was_unloaded = false
      vim.ui.img.providers['test'] = vim.ui.img.providers.new({
        show = function(_, _, on_shown)
          on_shown(nil, 0)
        end,
        hide = function() end,
        unload = function()
          was_unloaded = true
        end,
      })

      -- Ensure the provider is loaded, as otherwise it won't unload
      vim.ui.img.providers.load('test')

      -- Force a change away from our test provider
      vim.o.imgprovider = 'test'
      vim.o.imgprovider = 'kitty'

      return was_unloaded
    end)

    eq(true, was_unloaded, 'test provider unloaded')
  end)

  describe('iterm2 provider', function()
    before_each(function()
      setup_provider('iterm2')
    end)

    it('can display an image in neovim', function()
      local img_bytes = img_load(img_filename)

      -- Display a single copy of our image
      local actual = img_execute({
        op = 'show',
        filename = img_filename,
        opts = {
          pos = { x = 1, y = 2, unit = 'cell' },
          size = { width = 3, height = 4, unit = 'cell' },
        },
      })

      local expected = table.concat({
        -- Start terminal sync mode
        '\027[?2026h',
        -- Hide cursor so it doesn't move around
        '\027[?25l',
        -- Save cursor position so it can be restored later
        '\0277',
        -- Move cursor to top-left of image position
        '\027[2;1H',
        -- iterm2 image file display escape sequence
        string.format(
          '\027]1337;File=%s:%s\007',
          string.format(
            'name=%s;size=%s;preserveAspectRatio=0;inline=1;width=3;height=4',
            base64_encode(fn.fnamemodify(img_filename, ':t:r')),
            string.len(img_bytes)
          ),
          base64_encode(img_bytes)
        ),
        -- Restore original cursor position
        '\0278',
        -- Show cursor again
        '\027[?25h',
        -- End terminal sync mode
        '\027[?2026l',
      })

      eq(escape_ansi(expected), escape_ansi(actual))
    end)

    it('can hide an image in neovim', function()
      -- Show the same image in multiple places, and then we'll hide one of them
      -- NOTE: Since iterm2 doesn't check the PNG data (it just sends it), we
      --       can supply fake data for the PNGs to use for testing later
      local actual = img_execute({
        op = 'show',
        filename = 'abc',
        id = 12345,
        bytes = 'abc',
        opts = {
          pos = { x = 1, y = 2, unit = 'cell' },
          size = { width = 3, height = 4, unit = 'cell' },
          z = 1,
        },
      }, {
        op = 'show',
        filename = 'def',
        bytes = 'def',
        opts = {
          pos = { x = 2, y = 3, unit = 'cell' },
          size = { width = 4, height = 5, unit = 'cell' },
          z = 2,
        },
      }, {
        op = 'show',
        filename = 'ghi',
        bytes = 'ghi',
        opts = {
          pos = { x = 3, y = 4, unit = 'cell' },
          size = { width = 5, height = 6, unit = 'cell' },
          z = 3,
        },
      }, { op = 'clear' }, { op = 'hide', id = 12345 })

      -- Hiding an image just involves clearing the screen and showing
      -- images other than the one hidden
      local expected = table.concat({
        -- Start terminal sync mode
        '\027[?2026h',
        -- Hide cursor so it doesn't move around
        '\027[?25l',
        -- Save cursor position so it can be restored later
        '\0277',
        -- Move cursor to top-left of image position (image b)
        '\027[3;2H',
        -- iterm2 image file display escape sequence (image b)
        string.format(
          '\027]1337;File=%s:%s\007',
          string.format(
            'name=%s;size=%s;preserveAspectRatio=0;inline=1;width=4;height=5',
            base64_encode('def'),
            string.len('def')
          ),
          base64_encode('def')
        ),
        -- Move cursor to top-left of image position (image c)
        '\027[4;3H',
        -- iterm2 image file display escape sequence (image c)
        string.format(
          '\027]1337;File=%s:%s\007',
          string.format(
            'name=%s;size=%s;preserveAspectRatio=0;inline=1;width=5;height=6',
            base64_encode('ghi'),
            string.len('ghi')
          ),
          base64_encode('ghi')
        ),
        -- Restore original cursor position
        '\0278',
        -- Show cursor again
        '\027[?25h',
        -- End terminal sync mode
        '\027[?2026l',
      })

      eq(escape_ansi(expected), escape_ansi(actual))
    end)

    it('can update an image in neovim', function()
      local img_bytes = img_load(img_filename)
      local actual = img_execute({
        op = 'show',
        filename = img_filename,
        id = 12345,
        opts = {
          pos = { x = 1, y = 2, unit = 'cell' },
          size = { width = 3, height = 4, unit = 'cell' },
        },
      }, { op = 'clear' }, {
        op = 'update',
        id = 12345,
        opts = {
          pos = { x = 5, y = 6, unit = 'cell' },
          size = { width = 7, height = 8, unit = 'cell' },
        },
      })

      -- Updating is just like displaying as iterm2 has to send the full
      -- data each time an image is displayed, and updating merely clears
      -- the screen before re-displaying the images again
      local expected = table.concat({
        -- Start terminal sync mode
        '\027[?2026h',
        -- Hide cursor so it doesn't move around
        '\027[?25l',
        -- Save cursor position so it can be restored later
        '\0277',
        -- Move cursor to top-left of image position
        '\027[6;5H',
        -- iterm2 image file display escape sequence
        string.format(
          '\027]1337;File=%s:%s\007',
          string.format(
            'name=%s;size=%s;preserveAspectRatio=0;inline=1;width=7;height=8',
            base64_encode(fn.fnamemodify(img_filename, ':t:r')),
            string.len(img_bytes)
          ),
          base64_encode(img_bytes)
        ),
        -- Restore original cursor position
        '\0278',
        -- Show cursor again
        '\027[?25h',
        -- End terminal sync mode
        '\027[?2026l',
      })

      eq(escape_ansi(expected), escape_ansi(actual))
    end)
  end)

  describe('kitty provider', function()
    before_each(function()
      setup_provider('kitty')
    end)

    ---@param esc string actual escape sequence
    ---@param opts? {strict?:boolean}
    ---@return {i:integer, j:integer, control:table<string, string>, data:string|nil}
    local function parse_kitty_seq(esc, opts)
      opts = opts or {}
      local i, j, c, d = string.find(esc, '\027_G([^;\027]+)([^\027]*)\027\\')
      assert(c, 'invalid kitty escape sequence: ' .. escape_ansi(esc))

      if opts.strict then
        assert(i == 1, 'not starting with kitty graphics sequence: ' .. escape_ansi(esc))
      end

      ---@type table<string, string>, integer|nil
      local control, idx = {}, 0
      while true do
        local k, v, _
        idx, _, k, v = string.find(c, '(%a+)=([^,]+),?', idx + 1)
        if idx == nil then
          break
        end
        if k and v then
          control[k] = v
        end
      end

      -- Strip leading ; if we got data
      ---@type string|nil
      local payload
      if d and d ~= '' then
        payload = string.sub(d, 2)
      end

      return { i = i, j = j, control = control, data = payload }
    end

    it('can display an image in neovim', function()
      local esc_codes = img_execute({
        op = 'show',
        filename = img_filename,
        id = 12345,
        opts = {
          crop = { x = 5, y = 6, width = 7, height = 8, unit = 'pixel' },
          pos = { x = 1, y = 2, unit = 'cell' },
          size = { width = 3, height = 4, unit = 'cell' },
          z = 123,
        },
      })

      -- First, we upload an image and assign it an id
      local seq = parse_kitty_seq(esc_codes, { strict = true })
      local image_id = seq.control.i
      eq({
        f = '100',
        a = 't',
        t = 'f',
        i = image_id,
        q = '2',
      }, seq.control, 'transmit image control data')
      eq(base64_encode(img_filename), seq.data)
      esc_codes = string.sub(esc_codes, seq.j + 1)

      -- Second, we save the current cursor position to restore it later
      eq(escape_ansi('\0277'), escape_ansi(string.sub(esc_codes, 1, 2)), 'cursor save')
      esc_codes = string.sub(esc_codes, 3)

      -- Third, we hide the cursor so it doesn't jump around on screeen
      eq(escape_ansi('\027[?25l'), escape_ansi(string.sub(esc_codes, 1, 6)), 'cursor hide')
      esc_codes = string.sub(esc_codes, 7)

      -- Fourth, we move the cursor to the top-left of image position
      eq(escape_ansi('\027[2;1H'), escape_ansi(string.sub(esc_codes, 1, 6)), 'cursor movement')
      esc_codes = string.sub(esc_codes, 7)

      -- Fifth, we display the image using its id and a placement id
      seq = parse_kitty_seq(esc_codes, { strict = true })
      local img_placement_id = seq.control.p
      eq({
        a = 'p',
        i = image_id,
        p = img_placement_id,
        C = '1',
        q = '2',
        x = '5',
        y = '6',
        w = '7',
        h = '8',
        c = '3',
        r = '4',
        z = '123',
      }, seq.control, 'display image control data')
      esc_codes = string.sub(esc_codes, seq.j + 1)

      -- Sixth, we restore the cursor position to where it was before displaying images
      eq(escape_ansi('\0278'), escape_ansi(string.sub(esc_codes, 1, 2)), 'cursor restore')
      esc_codes = string.sub(esc_codes, 3)

      -- Seventh, we show the cursor again
      eq(escape_ansi('\027[?25h'), escape_ansi(string.sub(esc_codes, 1, 6)), 'cursor show')
    end)

    it('can hide an image in neovim', function()
      local esc_codes = img_execute({
        op = 'show',
        filename = img_filename,
        id = 12345,
      }, { op = 'clear' }, { op = 'hide', id = 12345 })

      local seq = parse_kitty_seq(esc_codes, { strict = true })
      -- stylua: ignore
      eq({
        a = 'd',           -- Perform a deletion
        d = 'i',           -- Target an image or placement
        i = seq.control.i, -- Specific kitty image to delete
        p = seq.control.p, -- Specific kitty placement to delete
        q = '2',           -- Suppress all responses
      }, seq.control, 'delete image and placement')
    end)

    it('can update an image in neovim', function()
      local esc_codes = img_execute({
        op = 'show',
        filename = img_filename,
        id = 12345,
      }, { op = 'clear' }, {
        op = 'update',
        id = 12345,
        opts = {
          crop = { x = 1, y = 2, width = 3, height = 4, unit = 'pixel' },
          pos = { x = 5, y = 6, unit = 'cell' },
          size = { width = 7, height = 8, unit = 'cell' },
          z = 9,
        },
      })

      -- First, we save the current cursor position to restore it later
      eq(escape_ansi('\0277'), escape_ansi(string.sub(esc_codes, 1, 2)), 'cursor save')
      esc_codes = string.sub(esc_codes, 3)

      -- Second, we hide the cursor so it doesn't jump around on screeen
      eq(escape_ansi('\027[?25l'), escape_ansi(string.sub(esc_codes, 1, 6)), 'cursor hide')
      esc_codes = string.sub(esc_codes, 7)

      -- Third, we move the cursor to the top-left of image position
      eq(escape_ansi('\027[6;5H'), escape_ansi(string.sub(esc_codes, 1, 6)), 'cursor movement')
      esc_codes = string.sub(esc_codes, 7)

      -- Fourth, we display the image using its id and a placement id,
      -- which for kitty will result in a flicker-free visual update
      local seq = parse_kitty_seq(esc_codes, { strict = true })
      eq({
        a = 'p',
        i = seq.control.i,
        p = seq.control.p,
        C = '1',
        q = '2',
        x = '1',
        y = '2',
        w = '3',
        h = '4',
        c = '7',
        r = '8',
        z = '9',
      }, seq.control, 'display image control data')
      esc_codes = string.sub(esc_codes, seq.j + 1)

      -- Fifth, we restore the cursor position to where it was before displaying images
      eq(escape_ansi('\0278'), escape_ansi(string.sub(esc_codes, 1, 2)), 'cursor restore')
      esc_codes = string.sub(esc_codes, 3)

      -- Sixth, we show the cursor again
      eq(escape_ansi('\027[?25h'), escape_ansi(string.sub(esc_codes, 1, 6)), 'cursor show')
    end)
  end)

  describe('sixel provider', function()
    -- Sixel data representing the PNG image above, cropped to
    -- x=1,y=2,w=2,h=1 and resized to a 8x8 pixel dimension.
    -- stylua: ignore
    local SIXEL_ESC_SEQ = table.concat({
      '\027P',                   -- Begin sixel
      '0;0;0q',                  -- Macro parameter for aspect ratio (0;0 = use default)
      '"1;1;8;4',                -- Set raster attributes
      '#0;2;37;38;87',           -- Color register 0; 2 = rgb mode; r=37%, g=38%, b=87%
      '#1;2;86;8;70',            -- Color register 1; ...
      '#2;2;100;0;63',           -- Color register 2; ...
      '#3;2;63;22;78',           -- Color register 3; ...
      '#4;2;1;59;100',           -- Color register 4; ...
      '#5;2;14;51;95',           -- Color register 5; ...
      '#6;2;0;63;100',           -- Color register 6; ...
      '#6N#4N#5N#0N#3N#1N#2NN-', -- Image data
      '\027\\',                  -- End sixel
    })

    before_each(function()
      setup_provider('sixel')
      setup_magick({ stdout = SIXEL_ESC_SEQ })
    end)

    it('can display an image in neovim', function()
      -- Display a single copy of our image
      local actual = img_execute({
        op = 'show',
        filename = img_filename,
        opts = {
          crop = { x = 1, y = 2, width = 2, height = 1, unit = 'pixel' },
          pos = { x = 1, y = 2, unit = 'cell' },
          size = { width = 8, height = 8, unit = 'pixel' },
        },
      })

      local expected = table.concat({
        -- Start terminal sync mode
        '\027[?2026h',
        -- Hide cursor so it doesn't move around
        '\027[?25l',
        -- Save cursor position so it can be restored later
        '\0277',
        -- Move cursor to top-left of image position
        '\027[2;1H',
        -- sixel image file display escape sequence
        SIXEL_ESC_SEQ,
        -- Restore original cursor position
        '\0278',
        -- Show cursor again
        '\027[?25h',
        -- End terminal sync mode
        '\027[?2026l',
      })

      eq(escape_ansi(expected), escape_ansi(actual))
    end)

    it('can hide an image in neovim', function()
      -- Show the same image in multiple places, and then we'll hide one of them
      -- NOTE: Since sixel does check the PNG data, we use the same file, but
      --       with different parameters since that will result in different output
      local actual = img_execute({
        op = 'show',
        filename = img_filename,
        id = 12345,
        opts = {
          pos = { x = 1, y = 2, unit = 'cell' },
          size = { width = 3, height = 4, unit = 'cell' },
          z = 1,
        },
      }, {
        op = 'show',
        filename = img_filename,
        opts = {
          crop = { x = 1, y = 2, width = 2, height = 1, unit = 'pixel' },
          pos = { x = 1, y = 2, unit = 'cell' },
          size = { width = 8, height = 8, unit = 'pixel' },
          z = 2,
        },
      }, { op = 'clear' }, { op = 'hide', id = 12345 })

      local expected = table.concat({
        -- Start terminal sync mode
        '\027[?2026h',
        -- Hide cursor so it doesn't move around
        '\027[?25l',
        -- Save cursor position so it can be restored later
        '\0277',
        -- Move cursor to top-left of image position
        '\027[2;1H',
        -- sixel image file display escape sequence
        SIXEL_ESC_SEQ,
        -- Restore original cursor position
        '\0278',
        -- Show cursor again
        '\027[?25h',
        -- End terminal sync mode
        '\027[?2026l',
      })

      eq(escape_ansi(expected), escape_ansi(actual))
    end)

    it('can update an image in neovim', function()
      local actual = img_execute({
        op = 'show',
        filename = img_filename,
        id = 12345,
        opts = {
          pos = { x = 1, y = 2, unit = 'cell' },
          size = { width = 3, height = 4, unit = 'cell' },
          z = 1,
        },
      }, { op = 'clear' }, {
        op = 'update',
        id = 12345,
        opts = {
          crop = { x = 1, y = 2, width = 2, height = 1, unit = 'pixel' },
          pos = { x = 1, y = 2, unit = 'cell' },
          size = { width = 8, height = 8, unit = 'pixel' },
          z = 2,
        },
      })

      local expected = table.concat({
        -- Start terminal sync mode
        '\027[?2026h',
        -- Hide cursor so it doesn't move around
        '\027[?25l',
        -- Save cursor position so it can be restored later
        '\0277',
        -- Move cursor to top-left of image position
        '\027[2;1H',
        -- sixel image file display escape sequence
        SIXEL_ESC_SEQ,
        -- Restore original cursor position
        '\0278',
        -- Show cursor again
        '\027[?25h',
        -- End terminal sync mode
        '\027[?2026l',
      })

      eq(escape_ansi(expected), escape_ansi(actual))
    end)
  end)
end)
