-- update.lua
-- Per-buffer coordinator for server updates — the client counterpart of the
-- server session. Holds the current "world" (generation table of tokens/
-- comments), provides the decoder handlers, resolves token ids into positions,
-- and routes to the rendering primitives.
--
-- Dependency direction: update → session (set_state) is one-way; session does
-- NOT require update (buffer wires update.handlers into session.attach).

local syntax     = require('midx.syntax')
local diagnostic = require('midx.diagnostic')
local animation  = require('midx.animation')
local session    = require('midx.session')
local mirror     = require('midx.protocol.mirror')

local M = {}

-- gen_state[bufnr] = { tokens, comments } — the current world's table.
-- No generation stored: the immediacy gate lives in the decoder, so only
-- fresh frames reach these handlers.
local gen_state = {}


-- -- handlers -------------------------------------------------------------------
-- Returned to session.attach, wired into decoder.new. Each closes over bufnr.

-- The immediacy gate (drop frames for a superseded buffer generation) lives
-- in the decoder: position-bearing frames whose generation no longer matches
-- the client's current state never reach these handlers. So here we only
-- render what arrives.

function M.handlers(bufnr)
	return {

		-- syntax defines the render for the current world: wipe all in-flight
		-- fades, store the new table, repaint the static layer.
		syntax = function(_, tokens, comments)
			animation.clear(bufnr)
			gen_state[bufnr] = { tokens = tokens, comments = comments }
			syntax.apply(bufnr, tokens, comments)
		end,

		-- live references token ids into the current table.
		live = function(_, when, fires)
			local st = gen_state[bufnr]
			if not st then return end

			local tokens   = st.tokens
			local resolved = {}
			for _, fire in ipairs(fires) do
				local tk = tokens[fire.id]
				if tk then
					resolved[#resolved + 1] = {
						id     = fire.id,
						group  = mirror.GROUPS[tk.group] or 'Normal',
						dur    = fire.dur * 1000,   -- µs → ns
						chunks = tk.chunks,          -- {ln,cs,ce}, shared read-only
					}
				end
			end
			animation.animate(bufnr, when, resolved)
		end,

		-- diagnostic targets a token; resolve to its chunks.
		diagnostic = function(_, diags)
			local st = gen_state[bufnr]
			if not st then return end

			local tokens  = st.tokens
			local entries = {}
			for _, d in ipairs(diags) do
				local tk = tokens[d.token]
				if tk then
					local ranges = {}
					for _, ck in ipairs(tk.chunks) do
						ranges[#ranges + 1] = { ln = ck.ln, cs = ck.cs, ce = ck.ce }
					end
					entries[#entries + 1] = { ranges = ranges, code = d.code, level = d.level }
				end
			end
			diagnostic.apply(bufnr, entries)
		end,

		state = function(_, playing)
			session.set_state(bufnr, 'is_playing', playing)
		end,

		clock = function(_, now)
			animation.sync(now)
		end,
	}
end

--- Buffer unloaded: drop the generation table (renderers cleaned by init).
function M.detach(bufnr)
	gen_state[bufnr] = nil
end

return M
