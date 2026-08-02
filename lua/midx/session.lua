-- session.lua
-- Per-buffer session: connection, decoder, and state
-- One session per .midx buffer, stored in sessions[bufnr]

local connection = require('midx.connection')
local protocol   = require('midx.protocol')
local events     = require('midx.events')
local diff       = require('midx.diff')

local M = {}

-- Session registry: bufnr → { conn, decoder, is_connected, is_playing, revision }
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
	events.emit('state:changed', bufnr, key, value)
end

--- Get content of a buffer
-- @param bufnr number
-- @return string|nil
function M.get_content(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return table.concat(lines, '\n')
end

--- Attach a .midx buffer — creates a session with its own connection
-- @param bufnr number
-- @param on_message function(bufnr, msg)
-- @return boolean
function M.attach(bufnr, on_message)
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

	local    conn = connection.new()
	local decoder = protocol.new_decoder()

	sessions[bufnr] = {
		conn         = conn,
		decoder      = decoder,
		is_connected = false,
		is_playing   = false,
		revision     = 0,
		-- generation : version du monde source, frappée par le client —
		-- incrémentée à CHAQUE envoi mutant (buffer et diff), adoptée par
		-- le serveur qui la répercute dans ses updates. Subsume revision
		-- à terme (chaîne +1 validée côté serveur).
		generation   = 0,
	}

	-- Wire up callbacks
	conn.on_data = function(data)
		decoder:decode(data, function(msg)
			on_message(bufnr, msg)
		end)
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
			conn:send(protocol.encode_buffer(content, s and s.generation))
		end
	end

	conn.on_disconnected = function()
		M.set_state(bufnr, 'is_connected', false)
		M.set_state(bufnr, 'is_playing', false)
		decoder:reset()
	end

	-- Byte-level change tracking → DIFF messages.
	-- Runs alongside the full-buffer send (TextChanged) during the
	-- validation phase: the server can cross-check its spliced shadow
	-- copy against each incoming BUFFER message.
	vim.api.nvim_buf_attach(bufnr, false, {

		on_bytes = function(_, buf, _tick,
		                    start_row, start_col, byte_offset,
		                    _old_end_row, _old_end_col, old_len,
		                    new_end_row, new_end_col, new_len)

			local s = sessions[buf]

			-- session gone → returning true detaches this callback
			if not s then
				return true
			end

			-- offline edits are dropped: reconnection resends the
			-- full buffer, which resynchronizes the sequence
			if not s.is_connected then
				return
			end

			local d = diff.from_bytes(buf, start_row, start_col, byte_offset,
				old_len, new_end_row, new_end_col, new_len)
			if not d then
				return
			end

			-- pas de generation++ ici : le serveur n'applique pas encore
			-- les diffs (aucun monde créé) — le jour où il les appliquera,
			-- l'incrément migrera du buffer vers le diff
			s.revision = s.revision + 1
			local row, col = diff.cursor(buf)
			s.conn:send(protocol.encode_diff(d, s.revision, row, col, s.generation))
		end,

		-- :e! and friends rewrite the buffer wholesale — resync with a
		-- full BUFFER send (which resets the revision sequence)
		on_reload = function(_, buf)
			if not sessions[buf] then
				return true
			end
			M.send_buffer(buf)
		end,
	})

	conn:connect()

	vim.notify(
		string.format('[midx] Attached to buffer #%d', bufnr),
		vim.log.levels.INFO
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
		vim.log.levels.INFO
	)
end

--- Send buffer content
-- A full-buffer send resets the diff revision sequence on both sides.
-- @param bufnr number
function M.send_buffer(bufnr)
	local s = sessions[bufnr]
	if not s then
		return
	end

	local content = M.get_content(bufnr)
	if content then
		s.revision   = 0
		s.generation = s.generation + 1
		s.conn:send(protocol.encode_buffer(content, s.generation))
	end
end

--- Send toggle play/pause
-- @param bufnr number
function M.send_toggle(bufnr)
	local s = sessions[bufnr]
	if not s then
		return
	end

	s.conn:send(protocol.encode_toggle(s.generation))
end

return M
