-- session.lua
-- Per-buffer session: connection, decoder, and state
-- One session per .midx buffer, stored in sessions[bufnr]

local connection = require('midx.connection')
local encoder    = require('midx.protocol.encoder')
local decoder    = require('midx.protocol.decoder')
local event      = require('midx.event')

local M = {}

-- Session registry:
-- bufnr → { conn, decoder, is_connected, is_playing, revision, generation }
local sessions = {}


--- Get a state value for a session
-- @param bufnr number
-- @param key string
-- @return any
function M.get_state(bufnr, key)
	local s = sessions[bufnr]
	if not s then
		return nil
	end
	return s[key]
end

--- Set a state value for a session and emit change event
-- @param bufnr number
-- @param key string
-- @param value any
function M.set_state(bufnr, key, value)
	local s = sessions[bufnr]
	if not s then
		return
	end

	if s[key] == value then
		return
	end

	s[key] = value
	event.emit('state:changed', bufnr, key, value)
end

--- Get content of a buffer, in nvim's canonical byte representation.
-- nvim's internal byte accounting (the one on_bytes offsets use) always ends
-- every line with '\n', including the last — regardless of the 'eol' option,
-- which only affects file writing. The full-buffer baseline must match, or it
-- would disagree with the diff stream by a trailing '\n'.
-- @param bufnr number
-- @return string|nil
function M.get_content(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return table.concat(lines, '\n') .. '\n'
end

--- Attach a .midx buffer — creates a session with its own connection
-- @param bufnr number
-- @param handlers table - decoder handlers { syntax, live, diagnostic, state, clock }
-- @return boolean
function M.attach(bufnr, handlers)
	if type(bufnr) ~= 'number' then
		error('session.attach: bufnr must be a number')
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify(
			string.format('[midx] Cannot attach: buffer %d is invalid', bufnr),
			vim.log.levels.ERROR
		)
		return false
	end

	-- Already attached
	if sessions[bufnr] then
		return true
	end

	local conn = connection.new()
	-- the decoder's immediacy gate reads the client's authoritative generation
	-- (this session's outgoing counter) to drop superseded position frames
	local dec  = decoder.new(handlers, function()
		local s = sessions[bufnr]
		return s and s.generation
	end)

	sessions[bufnr] = {
		conn         = conn,
		decoder      = dec,
		is_connected = false,
		is_playing   = false,
		revision     = 0,
		-- generation : version du monde source, frappée par le client —
		-- incrémentée à CHAQUE envoi mutant (buffer et diff), adoptée par
		-- le serveur qui la répercute dans ses updates. Subsume revision
		-- à terme (chaîne +1 validée côté serveur).
		generation   = 0,
	}

	-- Wire up callbacks: raw TCP bytes → binary decoder
	conn.on_data = function(data)
		dec:feed(data)
	end

	conn.on_connected = function()
		M.set_state(bufnr, 'is_connected', true)
		local content = M.get_content(bufnr)
		if content then
			local s = sessions[bufnr]
			if s then
				s.revision   = 0
				s.generation = s.generation + 1
			end
			conn:send(encoder.buffer(content, s and s.generation))
		end
	end

	conn.on_disconnected = function()
		M.set_state(bufnr, 'is_connected', false)
		M.set_state(bufnr, 'is_playing', false)
		dec:reset()
	end

	conn:connect()

	vim.notify(
		string.format('[midx] Attached to buffer #%d', bufnr),
		vim.log.levels.DEBUG
	)

	return true
end

--- Detach a buffer — closes connection and removes session
-- @param bufnr number
function M.detach(bufnr)
	local s = sessions[bufnr]
	if not s then
		return
	end

	s.conn:disconnect()
	sessions[bufnr] = nil

	vim.notify(
		string.format('[midx] Detached from buffer #%d', bufnr),
		vim.log.levels.DEBUG
	)
end

--- Send buffer content
-- A full-buffer send resets the diff revision sequence on both sides.
-- @param bufnr number
function M.send_buffer(bufnr)
	local s = sessions[bufnr]
	if not s or not s.is_connected then
		return
	end

	local content = M.get_content(bufnr)
	if content then
		s.revision   = 0
		s.generation = s.generation + 1
		s.conn:send(encoder.buffer(content, s.generation))
	end
end

--- Send toggle play/pause
-- @param bufnr number
function M.send_toggle(bufnr)
	local s = sessions[bufnr]
	if not s then
		return
	end

	s.conn:send(encoder.toggle(s.generation))
end

--- Send a byte-splice diff (bumps the revision within the current generation).
-- generation is NOT bumped here: the server doesn't apply diffs yet (no world
-- created). When it does, the increment migrates from the buffer to the diff.
-- @param bufnr number
-- @param d table - byte-splice record { offset, removed, added, text }
-- @param cursor_row number - 0-based
-- @param cursor_col number - 0-based
function M.send_diff(bufnr, d, cursor_row, cursor_col)
	local s = sessions[bufnr]
	if not s or not s.is_connected then
		return
	end

	s.revision = s.revision + 1
	s.conn:send(encoder.diff(d, s.revision, cursor_row, cursor_col, s.generation))
end

--- Whether a session exists for this buffer.
-- @param bufnr number
-- @return boolean
function M.is_attached(bufnr)
	return sessions[bufnr] ~= nil
end

return M
