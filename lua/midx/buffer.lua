-- buffer.lua
-- Active .midx buffer lifecycle management
-- Part of MIDX Neovim plugin refactored architecture (Layer 2: Services)

local events = require('midx.events')
local state  = require('midx.state')

local M = {}


-- on bytes callback
local function _on_bytes(_, buf, changedtick,
						 -- start row of the changed text
						 start_row,
						 -- start column of the changed text
						 start_col,
						 -- byte offset of the changed text (from the start of the buffer)
						 byte_offset,
						 -- old end row of the changed text (offset from start row)
						 old_end_row,
						 -- old end column of the changed text (if old end row = 0, offset from start column)
						 old_end_col,
						 -- old end byte length of the changed text
						 old_byte_len,
						 -- new end row of the changed text (offset from start row)
						 new_end_row,
						 -- new end column of the changed text (if new end row = 0, offset from start column)
						 new_end_col,
						 -- new end byte length of the changed text
						 new_byte_len)

	-- ignorer si ce n'est plus le buffer actif
	if buf ~= state.get('active_buffer') then
		return true  -- true = detach
	end

	-- recuperer le contenu insere
	local inserted = ''
	if new_byte_len > 0 then
		local end_row = start_row + new_end_row
		local end_col = (new_end_row == 0)
		and (start_col + new_end_col)
		or new_end_col
		local ok, lines = pcall(vim.api.nvim_buf_get_text,
		buf, start_row, start_col, end_row, end_col, {})
		if ok then
			inserted = table.concat(lines, '\\n')
		end
	end

	print(string.format(
		'tick=%d pos=(%d,%d) byte=%d del=(%dr,%dc,%db) ins=(%dr,%dc,%db) [%s]',
		changedtick,
		start_row, start_col, byte_offset,
		old_end_row, old_end_col, old_byte_len,
		new_end_row, new_end_col, new_byte_len,
		inserted
	))

end


-- private function to log buffer changes (for debugging)
local function log_buffer_changes(bufnr)

	options = { on_bytes = _on_bytes }

	vim.api.nvim_buf_attach(bufnr, false, options)
end



--- Attach to a .midx buffer
-- @param bufnr number - Buffer number to attach
-- @return boolean - true if attached successfully
function M.attach(bufnr)
	if type(bufnr) ~= 'number' then
		error('buffer.attach: bufnr must be a number')
	end

	-- Check if buffer is valid
	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify(
			string.format('[midx] Cannot attach: buffer %d is invalid', bufnr),
			vim.log.levels.ERROR
		)
		return false
	end

	local current_buffer = state.get('active_buffer')

	if current_buffer then
		if current_buffer == bufnr then
			-- Already attached to this buffer
			return true
		else
			-- Another buffer is active
			vim.notify(
				string.format('[midx] Another buffer is already active (use :MidxSwitch)'),
				vim.log.levels.WARN
			)
			return false
		end
	end

	-- Set as active buffer
	state.set('active_buffer', bufnr)

	log_buffer_changes(bufnr)

	vim.notify(
		string.format('[midx] Attached to buffer #%d', bufnr),
		vim.log.levels.INFO
	)

	-- Emit attachment event
	events.emit('buffer:attached', bufnr)

	return true
end

--- Detach from the currently active buffer
function M.detach()
	local bufnr = state.get('active_buffer')

	if not bufnr then
		return -- No active buffer
	end

	vim.notify(
		string.format('[midx] Detached from buffer #%d', bufnr),
		vim.log.levels.INFO
	)

	-- Clear active buffer
	state.set('active_buffer', nil)

	-- Emit detachment event
	events.emit('buffer:detached', bufnr)
end

--- Switch to a different .midx buffer
-- @param bufnr number - Buffer number to switch to
-- @return boolean - true if switched successfully
function M.switch(bufnr)
	if type(bufnr) ~= 'number' then
		error('buffer.switch: bufnr must be a number')
	end

	-- Validate buffer
	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify(
			string.format('[midx] Cannot switch: buffer %d is invalid', bufnr),
			vim.log.levels.ERROR
		)
		return false
	end

	-- Check if it's a .midx file
	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path:match('%.midx$') then
		vim.notify(
			'[midx] Cannot switch: buffer is not a .midx file',
			vim.log.levels.ERROR
		)
		return false
	end

	local current_buffer = state.get('active_buffer')

	if current_buffer == bufnr then
		vim.notify(
			string.format('[midx] Already attached to buffer #%d', bufnr),
			vim.log.levels.INFO
		)
		return true
	end

	-- Detach from current buffer (if any)
	if current_buffer then
		M.detach()
	end

	-- Attach to new buffer
	return M.attach(bufnr)
end

--- Get content of the active buffer
-- @return string|nil - Buffer content as string, or nil if no active buffer
function M.get_content()
	local bufnr = state.get('active_buffer')

	if not bufnr then
		return nil
	end

	-- Validate buffer still exists
	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify(
			'[midx] Active buffer is no longer valid',
			vim.log.levels.WARN
		)
		M.detach()
		return nil
	end

	-- Read all lines
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return table.concat(lines, '\n')
end

--- Display status of active buffer
function M.status()
	local bufnr = state.get('active_buffer')
	local is_connected = state.get('is_connected')

	if not is_connected then
		vim.notify('[midx] Not connected to server', vim.log.levels.INFO)
		return
	end

	local status_msg = '[midx] Status: '

	if bufnr then
		local path = vim.api.nvim_buf_get_name(bufnr)
		status_msg = status_msg .. string.format('Active buffer #%d (%s)', bufnr, path)
	else
		status_msg = status_msg .. 'No active buffer'
	end

	vim.notify(status_msg, vim.log.levels.INFO)
end

return M
