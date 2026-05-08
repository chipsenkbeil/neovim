local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local clear = n.clear
local exec_lua = n.exec_lua
local eq = t.eq

describe(':terminal kitty graphics', function()
  before_each(function()
    clear()
    -- The functional test harness starts nvim with `-u NONE`, so plugin
    -- files are not auto-sourced. Source ours explicitly.
    exec_lua([[
      vim.cmd('runtime! plugin/nvim.ui.img.lua')

      -- Stub vim.ui.img.set so we can observe what got placed.
      _G._captured = {}
      local orig = vim.ui.img.set
      vim.ui.img.set = function(data, opts)
        table.insert(_G._captured, { data = data, opts = opts })
        return 1234
      end
      _G._restore_ui_img = function() vim.ui.img.set = orig end
    ]])
  end)

  after_each(function()
    exec_lua('if _G._restore_ui_img then _G._restore_ui_img() end')
  end)

  it('end-to-end: a=T placement creates a buffer-relative image', function()
    -- Start a :terminal running `cat`, then write a kitty APC into its stdin
    -- so vterm processes it and fires TermRequest.
    local placed = exec_lua([[
      vim.cmd('terminal cat')
      local buf = vim.api.nvim_get_current_buf()
      local chan = vim.b[buf].terminal_job_id
      assert(chan, 'no terminal_job_id')

      -- "AAAA" decodes to 3 NUL bytes — a tiny "image" for the test.
      -- Trailing newline: cat is line-buffered on a pty, so we need a LF
      -- to flush the APC bytes back to the outer vterm where TermRequest fires.
      vim.api.nvim_chan_send(chan, '\27_Ga=T,f=100,i=1,c=2,r=1;AAAA\27\\\n')

      -- Spin briefly so vterm processes the bytes and fires TermRequest.
      vim.wait(2000, function() return #_G._captured > 0 end)
      return _G._captured
    ]])

    eq(1, #placed)
    eq('buffer', placed[1].opts.relative)
    eq(2, placed[1].opts.width)
    eq(1, placed[1].opts.height)
    -- "AAAA" → 3 NUL bytes
    eq(3, #placed[1].data)
  end)

  it('cleanup deletes images when the terminal buffer is wiped', function()
    local deleted = exec_lua([[
      _G._deleted = {}
      vim.ui.img.del = function(id) table.insert(_G._deleted, id); return true end

      vim.cmd('terminal cat')
      local buf = vim.api.nvim_get_current_buf()
      local chan = vim.b[buf].terminal_job_id
      vim.api.nvim_chan_send(chan, '\27_Ga=T,f=100,i=1,c=2,r=1;AAAA\27\\\n')
      vim.wait(2000, function() return #_G._captured > 0 end)

      -- Send EOF (^D) so `cat` exits cleanly; otherwise bwipeout!
      -- on a still-running terminal job can hot-loop term_delayed_free.
      vim.api.nvim_chan_send(chan, '\4')
      vim.wait(500, function() return vim.fn.jobwait({ chan }, 0)[1] ~= -1 end)

      vim.cmd('bwipeout!')
      return _G._deleted
    ]])

    -- Exactly the id our stub returned (1234).
    assert(#deleted >= 1, 'expected at least one del call')
    eq(1234, deleted[1])
  end)
end)
