-- decoder.lua
-- MIDX protocol decoder (server → client) — mirror of pc::decoder.
-- Framing only: accumulation, header validation, magic resync,
-- dispatch by opcode. Payload decoders plug into the update
-- switch (_dispatch).
--
-- View contract: the payload (cdata) is only valid during the
-- callback — consume it, never store a pointer.

local ffi = require('ffi')

local M = {}

-- mirror of pc::header (header.h) — must match
-- u32 fields read native: little-endian, as all nvim targets
ffi.cdef[[
typedef struct {
	uint8_t  magic[4];
	uint32_t generation;
	uint32_t opcode;
	uint32_t length;
} midx_header;
]]

-- mirror of pc::update (update.h) — must match
local update = {
	syntax     = 0,
	comment    = 1,   -- reserved server-side (comments ride in the syntax tail)
	live       = 2,
	diagnostic = 3,
	clock      = 4,
	state      = 5,
}

local HEADER_SIZE = 16
assert(ffi.sizeof('midx_header') == HEADER_SIZE, 'midx_header layout mismatch')

-- sanity cap: beyond this, length is considered corrupted → resync
local MAX_PAYLOAD = 8 * 1024 * 1024

-- 'M', 'I', 'D', 'X'
local MAGIC = { 0x4D, 0x49, 0x44, 0x58 }


-- -- header state -------------------------------------------------------------
-- accumulates up to 16 bytes, then validates magic + length

function M:_on_header(src, i, len)
	local take = math.min(HEADER_SIZE - self.hdr_recv, len - i)

	ffi.copy(self.hdr_bytes + self.hdr_recv, src + i, take)
	self.hdr_recv = self.hdr_recv + take
	i = i + take

	if self.hdr_recv < HEADER_SIZE then
		return i
	end

	-- header complete
	local h = self.hdr
	self.hdr_recv = 0

	if h.magic[0] ~= MAGIC[1] or h.magic[1] ~= MAGIC[2]
	or h.magic[2] ~= MAGIC[3] or h.magic[3] ~= MAGIC[4]
	or h.length > MAX_PAYLOAD then
		-- framing lost: rescan the stream
		-- (the opcode is NOT validated here: a well-formed frame with an
		-- unknown opcode is skipped at dispatch — forward compatibility,
		-- never a resync)
		self.state  = 'resync'
		self.resync = 0
		return i
	end

	self.generation = h.generation
	self.opcode     = h.opcode
	self.length     = h.length

	-- empty payload: dispatch immediately
	if self.length == 0 then
		self:_dispatch(nil)
		return i
	end

	-- reused buffer, capacity retained (spool spirit):
	-- length is known → no concat ever, chunks are copied in place
	if self.length > self.cap then
		self.buf = ffi.new('uint8_t[?]', self.length)
		self.cap = self.length
	end

	self.received = 0
	self.state    = 'payload'
	return i
end


-- -- payload state ------------------------------------------------------------

function M:_on_payload(src, i, len)
	local take = math.min(self.length - self.received, len - i)

	ffi.copy(self.buf + self.received, src + i, take)
	self.received = self.received + take
	i = i + take

	if self.received == self.length then
		self.state = 'header'
		self:_dispatch(self.buf)
	end

	return i
end


-- -- resync state -------------------------------------------------------------
-- rescans the stream looking for the magic; match progress survives
-- chunk boundaries (magic split in two)

function M:_on_resync(src, i, len)
	while i < len do
		local byte = src[i]
		i = i + 1

		if byte == MAGIC[self.resync + 1] then
			self.resync = self.resync + 1

			if self.resync == 4 then
				-- magic found: rebuild the header prefix
				ffi.copy(self.hdr_bytes, 'MIDX', 4)
				self.hdr_recv = 4
				self.resync   = 0
				self.state    = 'header'
				return i
			end
		else
			-- retest the current byte as a magic start
			self.resync = (byte == MAGIC[1]) and 1 or 0
		end
	end

	return i
end


-- -- dispatch -----------------------------------------------------------------
-- the update switch: payload decoders plug in here.
-- payload (cdata, self.length bytes) is only valid during the call.

function M:_dispatch(payload)
	local op  = self.opcode
	local gen = self.generation

	if op == update.syntax then
		-- TODO: decode_syntax(payload, self.length) → self.handlers.syntax(gen, …)

	elseif op == update.live then
		-- TODO: decode_live(payload, self.length) → self.handlers.live(gen, …)

	elseif op == update.diagnostic then
		-- TODO: decode_diagnostic(payload, self.length) → self.handlers.diagnostic(gen, …)

	elseif op == update.clock then
		-- TODO: decode_clock(payload, self.length) → self.handlers.clock(gen, …)

	elseif op == update.state then
		-- TODO: decode_state(payload, self.length) → self.handlers.state(gen, …)

	else
		-- unknown opcode: well-formed frame, unknown content → skip
		vim.notify(
			string.format('[midx] unknown update opcode: %d', op),
			vim.log.levels.WARN
		)
	end
end


-- -- public API ---------------------------------------------------------------

--- New decoder (one per connection)
-- @param handlers table - { syntax, live, diagnostic, state } : fn(generation, …)
function M.new(handlers)
	local self = setmetatable({
		handlers = handlers or {},
		state    = 'header',

		-- header being accumulated
		hdr      = ffi.new('midx_header'),
		hdr_recv = 0,

		-- current header (parsed)
		generation = 0,
		opcode     = 0,
		length     = 0,

		-- payload being accumulated
		buf      = nil,
		cap      = 0,
		received = 0,

		-- magic match progress while resyncing
		resync = 0,
	}, { __index = M })

	self.hdr_bytes = ffi.cast('uint8_t*', self.hdr)
	return self
end

--- Feed the decoder with a raw TCP chunk
-- @param data string - received bytes (anchored for the duration of the call)
function M:feed(data)
	local src = ffi.cast('const uint8_t*', data)
	local len = #data
	local i   = 0

	while i < len do
		if self.state == 'header' then
			i = self:_on_header(src, i, len)
		elseif self.state == 'payload' then
			i = self:_on_payload(src, i, len)
		else
			i = self:_on_resync(src, i, len)
		end
	end
end

--- Reset (disconnection) — buffer capacity is retained
function M:reset()
	self.state    = 'header'
	self.hdr_recv = 0
	self.received = 0
	self.resync   = 0
end

return M
