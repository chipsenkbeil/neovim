-- Inbound kitty graphics protocol handler for |:terminal|. Watches
-- |TermRequest| for kitty APC sequences and dispatches them through
-- vim.ui.img. The implementation lives in vim.ui.img._terminal so it can
-- be unit-tested without an autocmd context.

if vim.g.loaded_nvim_ui_img then
  return
end
vim.g.loaded_nvim_ui_img = true

local terminal = require('vim.ui.img._terminal')
local group = vim.api.nvim_create_augroup('nvim.ui.img.terminal', {})

vim.api.nvim_create_autocmd('TermRequest', {
  group = group,
  nested = true,
  callback = function(ev)
    local seq = ev.data and ev.data.sequence
    local cursor = ev.data and ev.data.cursor
    if type(seq) ~= 'string' or type(cursor) ~= 'table' then
      return
    end
    terminal.dispatch(ev.buf, seq, cursor)
  end,
})

vim.api.nvim_create_autocmd({ 'TermClose', 'BufWipeout' }, {
  group = group,
  callback = function(ev)
    terminal.cleanup(ev.buf)
  end,
})
