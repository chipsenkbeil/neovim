---Pure-Lua PNG encoder for raw RGB / RGBA pixel buffers.
---
---Used by vim.ui.img._terminal to convert kitty graphics protocol RGB/RGBA
---transmissions (`f=24` / `f=32`) into PNG before handing off to vim.ui.img,
---which only accepts PNG. The output uses uncompressed deflate (stored
---blocks) since nvim does not expose a Lua zlib binding; this trades file
---size for portability — the resulting PNG is structurally valid and decoded
---by every conformant decoder.

local bit = require('bit')

local M = {}

-- Precomputed CRC32 table (IEEE 802.3 polynomial, reversed: 0xedb88320).
local crc_table = (function()
  local t = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if bit.band(c, 1) == 1 then
        c = bit.bxor(bit.rshift(c, 1), 0xedb88320)
      else
        c = bit.rshift(c, 1)
      end
    end
    t[i] = c
  end
  return t
end)()

---@param data string
---@return integer
local function crc32(data)
  local crc = 0xffffffff
  for i = 1, #data do
    local b = bit.band(bit.bxor(crc, data:byte(i)), 0xff)
    crc = bit.bxor(bit.rshift(crc, 8), crc_table[b])
  end
  return bit.band(bit.bxor(crc, 0xffffffff), 0xffffffff)
end

---Adler-32 (RFC 1950, used by zlib).
---@param data string
---@return integer
local function adler32(data)
  local a, b = 1, 0
  for i = 1, #data do
    a = (a + data:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 0x10000 + a
end

---@param n integer
---@return string 4-byte big-endian
local function be32(n)
  return string.char(
    bit.band(bit.rshift(n, 24), 0xff),
    bit.band(bit.rshift(n, 16), 0xff),
    bit.band(bit.rshift(n, 8), 0xff),
    bit.band(n, 0xff)
  )
end

---@param n integer
---@return string 2-byte little-endian
local function le16(n)
  return string.char(bit.band(n, 0xff), bit.band(bit.rshift(n, 8), 0xff))
end

---Wrap raw bytes in a zlib stream of stored (uncompressed) deflate blocks.
---@param data string
---@return string zlib stream
local function deflate_stored(data)
  -- zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01 → check value bits
  -- valid for FLEVEL=0 (fastest), no preset dict.
  local out = { '\120\001' }
  local pos = 1
  local len = #data
  local MAX = 65535
  while pos <= len do
    local end_pos = math.min(pos + MAX - 1, len)
    local block_len = end_pos - pos + 1
    local is_last = end_pos == len
    -- Block header byte: BFINAL bit (1=last) | BTYPE bits (00=stored)
    out[#out + 1] = string.char(is_last and 1 or 0)
    out[#out + 1] = le16(block_len)
    out[#out + 1] = le16(bit.band(bit.bnot(block_len), 0xffff))
    out[#out + 1] = data:sub(pos, end_pos)
    pos = end_pos + 1
  end
  out[#out + 1] = be32(adler32(data))
  return table.concat(out)
end

---@param chunk_type string 4-byte ASCII type code
---@param data string chunk payload
---@return string PNG chunk: 4-byte length + 4-byte type + data + 4-byte CRC32
local function chunk(chunk_type, data)
  return be32(#data) .. chunk_type .. data .. be32(crc32(chunk_type .. data))
end

---Encode raw pixel data as a PNG file.
---
---@param pixels string raw bytes; row-major, no per-row filter byte
---@param width integer image width in pixels
---@param height integer image height in pixels
---@param bpp integer bytes per pixel: 3 for RGB, 4 for RGBA
---@return string png PNG file bytes
function M.encode(pixels, width, height, bpp)
  assert(bpp == 3 or bpp == 4, 'bpp must be 3 (RGB) or 4 (RGBA)')
  local color_type = (bpp == 4) and 6 or 2 -- PNG color types: 6=RGBA, 2=RGB

  -- Apply PNG row filtering (filter type 0 = None: prepend 0x00 to each row).
  local row_bytes = width * bpp
  local rows = {}
  for r = 0, height - 1 do
    rows[#rows + 1] = '\0' .. pixels:sub(r * row_bytes + 1, (r + 1) * row_bytes)
  end
  local idat = deflate_stored(table.concat(rows))

  -- IHDR: width, height, bit_depth=8, color_type, compression=0, filter=0, interlace=0
  local ihdr = be32(width) .. be32(height) .. string.char(8, color_type, 0, 0, 0)

  return '\137PNG\r\n\26\n' .. chunk('IHDR', ihdr) .. chunk('IDAT', idat) .. chunk('IEND', '')
end

return M
