-- protocol.lua
-- MIDX protocol message encoding and decoding
-- Part of MIDX Neovim plugin refactored architecture (Layer 2: Services)

local M = {}

local method = {
	buffer = 0,
	diff   = 1,

	play   = 2,
	stop   = 3,
	toggle = 4,

	attach = 5,
	detach = 6,
	force  = 7,
	lock   = 8,
	unlock = 9,

	state  = 10
}

local function u32_le(n)
	return string.char(
		bit.band(n, 0xFF),
		bit.band(bit.rshift(n, 8), 0xFF),
		bit.band(bit.rshift(n, 16), 0xFF),
		bit.band(bit.rshift(n, 24), 0xFF)
	)
end

local magic = 'MIDX'

local function make_header(method, length)
	return magic .. u32_le(0) .. u32_le(method) .. u32_le(length)
end

--- Encode BUFFER message
-- @param payload string - Buffer content to send
-- @return string - Encoded message ready to send
function M.encode_buffer(payload)
	if type(payload) ~= 'string' then
		error('protocol.encode_buffer: payload must be a string')
	end

	local header = make_header(method.buffer, #payload)
	return header .. payload
end

--- Encode TOGGLE message
-- @return string - Encoded message ready to send
function M.encode_toggle()
	return make_header(method.toggle, 0)
end

--- Create a new decoder instance (one per connection)
-- @return table - Decoder with decode(data, callback) method
function M.new_decoder()
	local buffer = ''

	return {
		decode = function(self, data, on_message)
			buffer = buffer .. data

			while true do
				local newline_pos = buffer:find("\r\n")
				if not newline_pos then
					return
				end

				local json_chunk = buffer:sub(1, newline_pos - 1)
				buffer = buffer:sub(newline_pos + 2)

				local ok, msg = pcall(vim.json.decode, json_chunk)
				if not ok then
					vim.notify(
						string.format('[midx] JSON decode error: %s', tostring(msg)),
						vim.log.levels.ERROR
					)
					buffer = ''
					return
				end

				on_message(msg)
			end
		end,

		reset = function(self)
			buffer = ''
		end,
	}
end

return M
