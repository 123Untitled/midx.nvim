-- buffer.lua
-- Per-buffer edit lifecycle: attaching/detaching a .midx buffer's session and
-- translating nvim buffer mutations into outgoing messages.
--
-- This is the "input side" (nvim edits → wire). It never touches session
-- internals — it builds splices via diff and hands them to session's public
-- send API. Dependency direction is one-way (buffer → everything else).

local session    = require('midx.session')
local update     = require('midx.update')
local syntax     = require('midx.syntax')
local animation  = require('midx.animation')
local diagnostic = require('midx.diagnostic')
local diff       = require('midx.diff')

local M = {}

-- Byte-level change tracking → DIFF messages. Runs alongside the full-buffer
-- send (TextChanged, in init) during the validation phase.
local function attach_bytes(bufnr)
	vim.api.nvim_buf_attach(bufnr, false, {

		on_bytes = function(_, buf, _tick,
		                    start_row, start_col, byte_offset,
		                    _old_end_row, _old_end_col, old_len,
		                    new_end_row, new_end_col, new_len)

			-- session gone → returning true detaches this callback
			if not session.is_attached(buf) then
				return true
			end

			-- offline edits are dropped: reconnection resends the full
			-- buffer, which resynchronizes the sequence
			if not session.get_state(buf, 'is_connected') then
				return
			end

			local d = diff.from_bytes(buf, start_row, start_col, byte_offset,
				old_len, new_end_row, new_end_col, new_len)
			if not d then
				return
			end

			local row, col = diff.cursor(buf)
			session.send_diff(buf, d, row, col)
		end,

		-- :e! and friends rewrite the buffer wholesale — resync with a full
		-- BUFFER send (which resets the revision sequence)
		on_reload = function(_, buf)
			if not session.is_attached(buf) then
				return true
			end
			session.send_buffer(buf)
		end,
	})
end


--- Attach a .midx buffer: open its session, wire byte tracking, lay the base
--- cover layer, set the comment string.
-- @param bufnr number
function M.attach(bufnr)
	session.attach(bufnr, update.handlers(bufnr))
	attach_bytes(bufnr)
	syntax.cover(bufnr)                     -- base "Comment" layer before connection
	vim.bo[bufnr].commentstring = '\\\\ %s'
end

--- Detach a .midx buffer: detach the session and clean every per-buffer render.
-- @param bufnr number
function M.detach(bufnr)
	session.detach(bufnr)
	update.detach(bufnr)
	animation.detach(bufnr)
	diagnostic.clear(bufnr)
end

return M
