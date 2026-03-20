-- buffer.lua
-- Multi-buffer lifecycle management — one connection per buffer
-- Part of MIDX Neovim plugin refactored architecture (Layer 2: Services)

local connection = require('midx.connection')
local state      = require('midx.state')
local protocol   = require('midx.protocol')

local M = {}

-- Active buffers: bufnr → { conn, decoder }
local buffers = {}

--- Get the connection/decoder entry for a buffer
-- @param bufnr number
-- @return table|nil
function M.get(bufnr)
	return buffers[bufnr]
end

--- Get content of a buffer
-- @param bufnr number - Buffer number
-- @return string|nil
function M.get_content(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return table.concat(lines, '\n')
end

--- Attach to a .midx buffer
-- @param bufnr number - Buffer number to attach
-- @param on_message function(bufnr, msg) - Message handler callback
-- @return boolean
function M.attach(bufnr, on_message)
	if type(bufnr) ~= 'number' then
		error('buffer.attach: bufnr must be a number')
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify(
			string.format('[midx] Cannot attach: buffer %d is invalid', bufnr),
			vim.log.levels.ERROR
		)
		return false
	end

	-- Already attached
	if buffers[bufnr] then
		return true
	end

	-- Create connection and decoder for this buffer
	local conn = connection.new()
	local decoder = protocol.new_decoder()

	buffers[bufnr] = { conn = conn, decoder = decoder }

	-- Wire up callbacks
	conn.on_data = function(data)
		decoder:decode(data, function(msg)
			on_message(bufnr, msg)
		end)
	end

	conn.on_connected = function()
		state.set(bufnr, 'is_connected', true)
		-- Send buffer content on connect
		local content = M.get_content(bufnr)
		if content then
			conn:send(protocol.encode_update(content))
		end
	end

	conn.on_disconnected = function()
		state.set(bufnr, 'is_connected', false)
		state.set(bufnr, 'is_playing', false)
		decoder:reset()
	end

	-- Connect
	conn:connect()

	vim.notify(
		string.format('[midx] Attached to buffer #%d', bufnr),
		vim.log.levels.INFO
	)

	return true
end

--- Detach from a buffer
-- @param bufnr number - Buffer number to detach
function M.detach(bufnr)
	local entry = buffers[bufnr]
	if not entry then
		return
	end

	entry.conn:disconnect()
	buffers[bufnr] = nil
	state.remove(bufnr)

	vim.notify(
		string.format('[midx] Detached from buffer #%d', bufnr),
		vim.log.levels.INFO
	)
end

--- Send an update for a buffer
-- @param bufnr number - Buffer number
function M.send_update(bufnr)
	local entry = buffers[bufnr]
	if not entry then
		return
	end

	local content = M.get_content(bufnr)
	if content then
		entry.conn:send(protocol.encode_update(content))
	end
end

--- Send toggle for a buffer
-- @param bufnr number - Buffer number
function M.send_toggle(bufnr)
	local entry = buffers[bufnr]
	if not entry then
		return
	end

	entry.conn:send(protocol.encode_toggle())
end

return M
