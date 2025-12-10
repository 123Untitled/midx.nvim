-- statusline.lua
-- Winbar UI rendering (read-only view of state)
-- Part of MIDX Neovim plugin refactored architecture (Layer 3: UI)

local state = require('midx.state')

local M = {}

-- Track which buffers have winbar enabled
local enabled_buffers = {}

--- Build the winbar content
-- Reads from state.lua (no local state stored here)
-- @return string - Winbar string with highlight groups
function M.build()
	local parts = {}


	-- Connection status indicator
	if state.get('is_connected') then
		table.insert(parts, "  %#MidxConnected#● %#Normal#")
		-- MIDX branding
		table.insert(parts, "%#MidxBrand#MIDX connected %#Normal#")

	else
		table.insert(parts, "  %#MidxDisconnected#○ %#Normal#")
		table.insert(parts, "%#MidxBrand#MIDX disconnected %#Normal#")
	end


	-- Playing status
	if state.get('is_playing') then
		table.insert(parts, "%#MidxPlaying# ▶ PLAYING %#Normal#")
	else
		table.insert(parts, "%#MidxPaused# ⏸ PAUSED  %#Normal#")
	end

	-- Connection attempts (only show if attempting and not connected)
	local attempts = state.get('connection_attempts')
	if attempts and attempts > 0 and not state.get('is_connected') then
		table.insert(parts, string.format("%%#MidxInfo# (retry %d) %%#Normal#", attempts))
	end

	-- Spacer
	--table.insert(parts, " │ ")

	-- TODO: Add more info when available from server:
	-- BPM, playback position, current measure, etc.

	-- Right align
	table.insert(parts, "%=")

	-- Error indicator (if any)
	local error = state.get('last_error')
	if error then
		table.insert(parts, "%#MidxError# ⚠ Error %#Normal#")
	end

	return table.concat(parts, "")
end

--- Refresh the winbar for all enabled buffers
function M.refresh()
	for bufnr, _ in pairs(enabled_buffers) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			-- Get all windows showing this buffer
			local windows = vim.fn.win_findbuf(bufnr)
			for _, winid in ipairs(windows) do
				-- Force winbar update by setting it again
				vim.wo[winid].winbar = '%!v:lua.require("midx.statusline").build()'
			end
		else
			-- Clean up invalid buffers
			enabled_buffers[bufnr] = nil
		end
	end
end

--- Setup winbar highlight groups
function M.setup()
	-- Link to existing Neovim highlight groups for colorscheme compatibility
	vim.api.nvim_set_hl(0, 'MidxBrand', {link = 'Normal', default = true})
	vim.api.nvim_set_hl(0, 'MidxConnected', {link = 'String', default = true})
	vim.api.nvim_set_hl(0, 'MidxDisconnected', {link = 'Error', default = true})
	vim.api.nvim_set_hl(0, 'MidxPlaying', {link = 'Keyword', default = true})
	vim.api.nvim_set_hl(0, 'MidxPaused', {link = 'Normal', default = true})
	vim.api.nvim_set_hl(0, 'MidxInfo', {link = 'WarningMsg', default = true})
	vim.api.nvim_set_hl(0, 'MidxError', {link = 'ErrorMsg', default = true})
end

--- Enable winbar for a buffer
-- @param bufnr number - Buffer number to enable winbar for
function M.enable(bufnr)
	if type(bufnr) ~= 'number' then
		error('statusline.enable: bufnr must be a number')
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify(
			string.format('[midx] Cannot enable winbar: buffer %d is invalid', bufnr),
			vim.log.levels.WARN
		)
		return
	end

	-- Track this buffer
	enabled_buffers[bufnr] = true

	-- Set winbar for all windows showing this buffer
	local windows = vim.fn.win_findbuf(bufnr)
	for _, winid in ipairs(windows) do
		vim.wo[winid].winbar = '%!v:lua.require("midx.statusline").build()'
	end
end

--- Disable winbar for a buffer
-- @param bufnr number - Buffer number to disable winbar for
function M.disable(bufnr)
	if enabled_buffers[bufnr] then
		enabled_buffers[bufnr] = nil

		-- Clear winbar for all windows showing this buffer
		local windows = vim.fn.win_findbuf(bufnr)
		for _, winid in ipairs(windows) do
			vim.wo[winid].winbar = nil
		end
	end
end

return M
