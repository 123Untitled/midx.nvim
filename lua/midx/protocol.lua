-- protocol.lua
-- MIDX protocol message encoding and decoding
-- Part of MIDX Neovim plugin refactored architecture (Layer 2: Services)

local events = require('midx.events')

local method = {
	update = 0,
	play   = 1,
	stop   = 2,
	toggle = 3,
	state  = 4
}

local fmt = '<I4I4I4I4'  -- 4 unsigned 32-bit integers (little-endian)
local magic = string.unpack('>I4', 'MIDX')  -- Magic number for protocol identification


local M = {}

-- Message buffer for partial JSON accumulation
local buffer = ''

--- Encode UPDATE message
-- @param content string - Buffer content to send
-- @return string - Encoded message ready to send
function M.encode_update(payload)
	if type(payload) ~= 'string' then
		error('protocol.encode_update: payload must be a string')
	end

	local header = string.pack(fmt, magic, 0, method.update, #payload)
	return header .. payload
end
--function M.encode_update(content)
--	if type(content) ~= 'string' then
--		error('protocol.encode_update: content must be a string')
--	end
--
--	local size = #content
--	local header = 'UPDATE' .. tostring(size) .. '\n'
--	return header .. content
--end

--- Encode TOGGLE message
-- @return string - Encoded message ready to send
function M.encode_toggle()
	local header = string.pack(fmt, magic, 0, method.toggle, 0)
	return header
end
--function M.encode_toggle()
--	return 'TOGGLE\n'
--end

--- Decode incoming raw data
-- Accumulates partial messages and emits complete JSON messages
-- @param data string - Raw bytes received from socket
function M.decode(data)
	if type(data) ~= 'string' then
		error('protocol.decode: data must be a string')
	end

	-- Append to buffer
	buffer = buffer .. data

	-- Process all complete messages (delimited by \r\n)
	while true do
		local newline_pos = buffer:find("\r\n")
		if not newline_pos then
			return -- No complete message yet
		end

		-- Extract one complete message
		local json_chunk = buffer:sub(1, newline_pos - 1)
		buffer = buffer:sub(newline_pos + 2)

		-- Parse JSON
		local ok, msg = pcall(vim.json.decode, json_chunk)
		if not ok then
			vim.schedule(function()
				vim.notify(
					string.format('[midx] JSON decode error: %s', tostring(msg)),
					vim.log.levels.ERROR
				)
			end)
			-- Clear buffer on error to recover from bad state
			buffer = ''
			return
		end

		-- Emit parsed message
		events.emit('message:received', msg)
	end
end

--- Reset internal message buffer (useful for reconnection)
function M.reset_buffer()
	buffer = ''
end

--- Setup protocol event listeners
function M.setup()
	-- Listen for incoming data from connection layer
	events.on('connection:data', M.decode)

	-- Clear buffer on disconnect
	events.on('connection:lost', M.reset_buffer)
end

return M
