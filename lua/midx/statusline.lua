-- statusline.lua
-- Winbar UI rendering — shows state of the current buffer
-- Part of MIDX Neovim plugin refactored architecture (Layer 3: UI)

local state = require('midx.state')

local M = {}

-- Track which buffers have winbar enabled
local enabled_buffers = {}

--- Build the winbar content for the current buffer
-- @return string - Winbar string with highlight groups
function M.build()
	local bufnr = vim.api.nvim_get_current_buf()
	local parts = {}

	local connected = state.get(bufnr, 'is_connected')
	local playing = state.get(bufnr, 'is_playing')

	-- Connection status indicator
	if connected then
		table.insert(parts, "  %#MidxConnected#● %#Normal#")
		table.insert(parts, "%#MidxBrand#MIDX connected %#Normal#")
	else
		table.insert(parts, "  %#MidxDisconnected#○ %#Normal#")
		table.insert(parts, "%#MidxBrand#MIDX disconnected %#Normal#")
	end

	-- Playing status
	if playing then
		table.insert(parts, "%#MidxPlaying# ▶ PLAYING %#Normal#")
	else
		table.insert(parts, "%#MidxPaused# ⏸ PAUSED  %#Normal#")
	end

	-- Right align
	table.insert(parts, "%=")

	-- Error indicator
	local error = state.get(bufnr, 'last_error')
	if error then
		table.insert(parts, "%#MidxError# ⚠ Error %#Normal#")
	end

	return table.concat(parts, "")
end

--- Refresh the winbar for all enabled buffers
function M.refresh()
	for bufnr, _ in pairs(enabled_buffers) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			local windows = vim.fn.win_findbuf(bufnr)
			for _, winid in ipairs(windows) do
				vim.wo[winid].winbar = '%!v:lua.require("midx.statusline").build()'
			end
		else
			enabled_buffers[bufnr] = nil
		end
	end
end

--- Setup winbar highlight groups
function M.setup()
	vim.api.nvim_set_hl(0, 'MidxBrand', {link = 'Normal', default = true})
	vim.api.nvim_set_hl(0, 'MidxConnected', {link = 'String', default = true})
	vim.api.nvim_set_hl(0, 'MidxDisconnected', {link = 'Error', default = true})
	vim.api.nvim_set_hl(0, 'MidxPlaying', {link = 'Keyword', default = true})
	vim.api.nvim_set_hl(0, 'MidxPaused', {link = 'Normal', default = true})
	vim.api.nvim_set_hl(0, 'MidxInfo', {link = 'WarningMsg', default = true})
	vim.api.nvim_set_hl(0, 'MidxError', {link = 'ErrorMsg', default = true})
end

--- Enable winbar for a buffer
-- @param bufnr number
function M.enable(bufnr)
	if type(bufnr) ~= 'number' then
		error('statusline.enable: bufnr must be a number')
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	enabled_buffers[bufnr] = true

	local windows = vim.fn.win_findbuf(bufnr)
	for _, winid in ipairs(windows) do
		vim.wo[winid].winbar = '%!v:lua.require("midx.statusline").build()'
	end
end

--- Disable winbar for a buffer
-- @param bufnr number
function M.disable(bufnr)
	if enabled_buffers[bufnr] then
		enabled_buffers[bufnr] = nil

		local windows = vim.fn.win_findbuf(bufnr)
		for _, winid in ipairs(windows) do
			vim.wo[winid].winbar = nil
		end
	end
end

return M
