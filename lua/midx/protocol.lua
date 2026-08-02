-- protocol.lua
-- MIDX protocol message encoding and decoding
-- Part of MIDX Neovim plugin refactored architecture (Layer 2: Services)

local M = {}

-- miroir de pc::control (control.h) — must match
local control = {
	buffer = 0,
	diff   = 1,

	play   = 2,
	stop   = 3,
	toggle = 4,

	state  = 5,
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

-- header : magic(4) + generation(4) + opcode(4) + length(4)
-- generation = génération courante du client (0 tant que le décodeur
-- binaire ne l'a pas apprise du serveur)
local function make_header(opcode, length, generation)
	return magic .. u32_le(generation or 0) .. u32_le(opcode) .. u32_le(length)
end

--- Encode BUFFER message
-- @param payload string - Buffer content to send
-- @param generation number|nil - Client's current generation
-- @return string - Encoded message ready to send
function M.encode_buffer(payload, generation)
	if type(payload) ~= 'string' then
		error('protocol.encode_buffer: payload must be a string')
	end

	local header = make_header(control.buffer, #payload, generation)
	return header .. payload
end

--- Encode TOGGLE message
-- @param generation number|nil - Client's current generation
-- @return string - Encoded message ready to send
function M.encode_toggle(generation)
	return make_header(control.toggle, 0, generation)
end

--- Encode DIFF message
-- Payload mirrors pc::diff: 6 x u32 LE (revision, offset, removed, added,
-- cursor_row, cursor_col) followed by the inserted text.
-- @param d table - Byte-splice record { offset, removed, added, text }
-- @param revision number - Monotonic counter (a BUFFER send resets it to 0)
-- @param cursor_row number - Cursor row, 0-based
-- @param cursor_col number - Cursor col, 0-based
-- @param generation number|nil - Client's current generation
-- @return string - Encoded message ready to send
function M.encode_diff(d, revision, cursor_row, cursor_col, generation)
	local payload = u32_le(revision)
	             .. u32_le(d.offset)
	             .. u32_le(d.removed)
	             .. u32_le(d.added)
	             .. u32_le(cursor_row)
	             .. u32_le(cursor_col)
	             .. d.text

	local header = make_header(control.diff, #payload, generation)
	return header .. payload
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
