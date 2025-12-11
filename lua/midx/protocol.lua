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




local M = {}

local function u32_be(n)
	return string.char(
		bit.band(bit.rshift(n, 24), 0xFF),
		bit.band(bit.rshift(n, 16), 0xFF),
		bit.band(bit.rshift(n, 8), 0xFF),
		bit.band(n, 0xFF)
	)
end

local function u32_le(n)
	return string.char(
		bit.band(n, 0xFF),
		bit.band(bit.rshift(n, 8), 0xFF),
		bit.band(bit.rshift(n, 16), 0xFF),
		bit.band(bit.rshift(n, 24), 0xFF)
	)
end


-- magic number "MIDX" (endianness: 0x4D='M', 0x49='I', 0x44='D', 0x58='X')
--local magic = 0x4D494458
local magic = 'MIDX'


local function make_header(method, length)
	return magic .. u32_le(0) .. u32_le(method) .. u32_le(length)
end
	--return u32_le(magic) .. u32_le(0) .. u32_le(method) .. u32_le(length)


-- Message buffer for partial JSON accumulation
local buffer = ''

--- Encode UPDATE message
-- @param content string - Buffer content to send
-- @return string - Encoded message ready to send
function M.encode_update(payload)
	if type(payload) ~= 'string' then
		error('protocol.encode_update: payload must be a string')
	end

	local header = make_header(method.update, #payload)
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
	local header = make_header(method.toggle, 0)
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
