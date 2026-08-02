-- decoder.lua
-- MIDX protocol decoder (server → client) — mirror of pc::decoder.
-- Framing (accumulation, header validation, magic resync) + payload
-- decoders that turn wire records into plain Lua tables.
--
-- This file is the sole home of wire knowledge: byte layout, endianness,
-- 0-based ids, flag bits — none of it crosses the decoder boundary.
--
-- View contract: the FFI payload buffer is REUSED by the next frame.
-- Decoders must copy everything into Lua tables before returning; the
-- handlers receive tables, never cdata.

local ffi = require('ffi')

local M = {}


-- -- wire structs (mirror of syntax.h / header.h) — MUST MATCH ----------------
-- u32/u64 read native little-endian, as all nvim (LuaJIT) targets.
-- All structs are padding-free by design; the sizeof asserts guard it.

ffi.cdef[[
typedef struct { uint8_t magic[4]; uint32_t generation; uint32_t opcode; uint32_t length; } midx_header;

typedef struct { uint32_t tokens; uint32_t comments; } midx_syntax;
typedef struct { uint32_t chunks; uint16_t group; uint16_t flags; } midx_token;
typedef struct { uint32_t ln; uint32_t cs; uint32_t ce; } midx_chunk;
typedef struct { uint32_t ls; uint32_t le; uint32_t cs; uint32_t ce; } midx_comment;

typedef struct { uint64_t when; uint64_t reserved; } midx_epoch;
typedef struct { uint32_t id; uint32_t dur; } midx_live;

typedef struct { uint32_t token; uint16_t code; uint8_t level; uint8_t extra; } midx_diagnostic;

typedef struct { uint64_t now; } midx_clock;
typedef struct { uint32_t flags; } midx_state;
]]

assert(ffi.sizeof('midx_header')     == 16, 'midx_header layout mismatch')
assert(ffi.sizeof('midx_syntax')     ==  8, 'midx_syntax layout mismatch')
assert(ffi.sizeof('midx_token')      ==  8, 'midx_token layout mismatch')
assert(ffi.sizeof('midx_chunk')      == 12, 'midx_chunk layout mismatch')
assert(ffi.sizeof('midx_comment')    == 16, 'midx_comment layout mismatch')
assert(ffi.sizeof('midx_epoch')      == 16, 'midx_epoch layout mismatch')
assert(ffi.sizeof('midx_live')       ==  8, 'midx_live layout mismatch')
assert(ffi.sizeof('midx_diagnostic') ==  8, 'midx_diagnostic layout mismatch')
assert(ffi.sizeof('midx_clock')      ==  8, 'midx_clock layout mismatch')
assert(ffi.sizeof('midx_state')      ==  4, 'midx_state layout mismatch')

local SZ_SYNTAX  = ffi.sizeof('midx_syntax')
local SZ_TOKEN   = ffi.sizeof('midx_token')
local SZ_CHUNK   = ffi.sizeof('midx_chunk')
local SZ_COMMENT = ffi.sizeof('midx_comment')
local SZ_EPOCH   = ffi.sizeof('midx_epoch')
local SZ_LIVE    = ffi.sizeof('midx_live')
local SZ_DIAG    = ffi.sizeof('midx_diagnostic')
local SZ_CLOCK   = ffi.sizeof('midx_clock')
local SZ_STATE   = ffi.sizeof('midx_state')

-- mirror of pc::update (update.h) — MUST MATCH
local update = {
	syntax     = 0,
	comment    = 1,   -- reserved server-side (comments ride in the syntax tail)
	live       = 2,
	diagnostic = 3,
	clock      = 4,
	state      = 5,
}

-- immediacy gate: position-bearing updates are dropped when their generation
-- no longer matches the client's current buffer state (nvim already moved on),
-- BEFORE decoding the payload. clock/state carry no buffer positions and stay
-- valid across edits → exempt.
local GENERATION_BOUND = {
	[update.syntax]     = true,
	[update.live]       = true,
	[update.diagnostic] = true,
}

local HEADER_SIZE = 16

-- sanity cap: beyond this, length is considered corrupted → resync
local MAX_PAYLOAD = 8 * 1024 * 1024

-- 'M', 'I', 'D', 'X'
local MAGIC = { 0x4D, 0x49, 0x44, 0x58 }


-- -- payload decoders ---------------------------------------------------------
-- Each returns Lua tables/values on success, nil on a malformed payload.
-- Wire-isms normalized here: ids → 1-based, flag bits → booleans.

--- syntax: preamble { T tokens, K comments }, then INTERLEAVED
--- (token then its `chunks` chunk records) ×T, then K comment records in tail.
-- @return tokens, comments  (nil on malformed)
local function decode_syntax(buf, len)
	if len < SZ_SYNTAX then return nil end

	local pre = ffi.cast('const midx_syntax*', buf)
	local T   = pre.tokens
	local K   = pre.comments

	-- comments occupy the tail; the token/chunk section is [SZ_SYNTAX, tail)
	local tail = len - K * SZ_COMMENT
	if tail < SZ_SYNTAX then return nil end

	local off    = SZ_SYNTAX
	local tokens = {}

	for i = 1, T do
		if off + SZ_TOKEN > tail then return nil end
		local tk = ffi.cast('const midx_token*', buf + off)
		off = off + SZ_TOKEN

		local n      = tk.chunks
		local chunks = {}
		for j = 1, n do
			if off + SZ_CHUNK > tail then return nil end
			local ck = ffi.cast('const midx_chunk*', buf + off)
			off = off + SZ_CHUNK
			chunks[j] = { ln = ck.ln, cs = ck.cs, ce = ck.ce }
		end

		tokens[i] = {
			group  = tk.group,                    -- sx::id (mapped downstream)
			dimmed = bit.band(tk.flags, 0x1) ~= 0,
			chunks = chunks,
		}
	end

	-- the walk must land exactly on the comment tail
	if off ~= tail then return nil end

	local comments = {}
	for i = 1, K do
		local c = ffi.cast('const midx_comment*', buf + off)
		off = off + SZ_COMMENT
		comments[i] = { ls = c.ls, le = c.le, cs = c.cs, ce = c.ce }
	end

	return tokens, comments
end

--- live: epoch { when } then fire records { id, dur }.
-- @return when(ns), fires  (nil on malformed)
local function decode_live(buf, len)
	if len < SZ_EPOCH or (len - SZ_EPOCH) % SZ_LIVE ~= 0 then return nil end

	local ep   = ffi.cast('const midx_epoch*', buf)
	local when = tonumber(ep.when)   -- u64 ns → double (exact up to ~104 days)

	local n     = (len - SZ_EPOCH) / SZ_LIVE
	local fires = {}
	for i = 1, n do
		local r = ffi.cast('const midx_live*', buf + SZ_EPOCH + (i - 1) * SZ_LIVE)
		fires[i] = { id = r.id + 1, dur = r.dur }   -- id → 1-based ; dur in µs
	end

	return when, fires
end

--- diagnostic: fixed records { token, code, level, extra }.
-- @return diags  (nil on malformed)
local function decode_diagnostic(buf, len)
	if len % SZ_DIAG ~= 0 then return nil end

	local n     = len / SZ_DIAG
	local diags = {}
	for i = 1, n do
		local d = ffi.cast('const midx_diagnostic*', buf + (i - 1) * SZ_DIAG)
		diags[i] = {
			token = d.token + 1,   -- → 1-based
			code  = d.code,
			level = d.level,
			extra = d.extra,
		}
	end

	return diags
end

--- state: flags (bit 0 = playing).
-- @return playing(bool)  (nil on malformed)
local function decode_state(buf, len)
	if len ~= SZ_STATE then return nil end
	local s = ffi.cast('const midx_state*', buf)
	return bit.band(s.flags, 0x1) ~= 0
end

--- clock: server time in ns.
-- @return now(ns)  (nil on malformed)
local function decode_clock(buf, len)
	if len ~= SZ_CLOCK then return nil end
	local c = ffi.cast('const midx_clock*', buf)
	return tonumber(c.now)
end


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
-- the update switch. payload (cdata, self.length bytes) is only valid during
-- the call. A malformed payload in a well-framed frame is dropped + logged;
-- the framing itself stays sound (no resync).

function M:_dispatch(payload)
	local op  = self.opcode
	local gen = self.generation
	local len = self.length
	local h   = self.handlers

	-- drop superseded position-bearing frames before decoding the payload
	if GENERATION_BOUND[op] and self.current_gen and gen ~= self.current_gen() then
		return
	end

	if op == update.syntax then
		local tokens, comments = decode_syntax(payload, len)
		if tokens ~= nil then
			if h.syntax then h.syntax(gen, tokens, comments) end
		else
			self:_bad('syntax')
		end

	elseif op == update.live then
		local when, fires = decode_live(payload, len)
		if when ~= nil then
			if h.live then h.live(gen, when, fires) end
		else
			self:_bad('live')
		end

	elseif op == update.diagnostic then
		local diags = decode_diagnostic(payload, len)
		if diags ~= nil then
			if h.diagnostic then h.diagnostic(gen, diags) end
		else
			self:_bad('diagnostic')
		end

	elseif op == update.clock then
		local now = decode_clock(payload, len)
		if now ~= nil then
			if h.clock then h.clock(gen, now) end
		else
			self:_bad('clock')
		end

	elseif op == update.state then
		local playing = decode_state(payload, len)
		if playing ~= nil then
			if h.state then h.state(gen, playing) end
		else
			self:_bad('state')
		end

	else
		-- unknown opcode: well-formed frame, unknown content → skip
		vim.notify(
			string.format('[midx] unknown update opcode: %d', op),
			vim.log.levels.WARN
		)
	end
end

function M:_bad(name)
	vim.notify(
		string.format('[midx] malformed %s payload (%d bytes) — dropped', name, self.length),
		vim.log.levels.WARN
	)
end


-- -- public API ---------------------------------------------------------------

--- New decoder (one per connection)
-- @param handlers table - { syntax, live, diagnostic, state, clock } : fn(generation, …)
--   syntax(gen, tokens, comments) · live(gen, when, fires)
--   diagnostic(gen, diags) · state(gen, playing) · clock(gen, now)
-- @param current_gen function|nil - () → client's authoritative generation;
--   position-bearing frames whose generation differs are dropped (immediacy).
function M.new(handlers, current_gen)
	local self = setmetatable({
		handlers    = handlers or {},
		current_gen = current_gen,
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
