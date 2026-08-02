-- animation.lua
-- Execution-highlight fade engine — via a decoration provider.
--
-- Rendering: a decoration provider places EPHEMERAL extmarks (recomputed each
--   redraw, viewport-limited). The color is not recolored per frame: precomputed
--   step groups `accent × STEPS` (bg → accent), the provider picks the step
--   nearest the current alpha. Zero nvim_set_hl per frame.
--
-- Timer: purges expired sources and FORCES a redraw (pump) while fades remain.
--   Stops at count == 0.
--
-- Registry (token-keyed, multi-chunk): a fire targets a TOKEN, which spans N
--   chunks. One fade entry per token, covering all its ranges, with a single
--   accent (the token's group) and a shared source stack.
--     anim[bufnr][token_id] = { ranges = {{ln,cs,ce},…}, accent, sources = {{onset,dur},…} }
--     rowmap[bufnr][row][token_id] = true      (every chunk's row is indexed)
--
-- Fades do NOT survive a generation change: render calls M.clear on new syntax.
--   Positions are captured at creation and never re-resolved.

local M = {}

local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace('midx_animation')

-- Config
local FRAME_MS  = 16      -- ~60 fps
local MAX_ALPHA = 0.50    -- per-source intensity at onset (0..1); screen stacks beyond
local STEPS     = 128     -- bg→accent gradient steps
local PRIORITY  = 1000    -- above the syntax layer
-- Fade envelope (fractions of duration)
local ATTACK  = 0.00
local PLATEAU = 0.33
local REL_G   = 0.33

local background = require('midx.background')

-- Registry + index + engine state
local anim    = {}
local rowmap  = {}
local count   = 0
local timer   = nil

-- Precomputed steps: fades[accent] = { _ver, [step] = group_name }
local fades   = {}
local version = 0
local last_bg = nil

-- Accent cache: group name → fg color (invalidated on ColorScheme)
local accents = {}

-- Frame state (stamped in on_start, read by on_line)
local frame_now = 0

-- Clock offset: client − server (ns), measured on `clock` update.
local offset = 0


-- -- color math -----------------------------------------------------------------

local function envelope(t)
	if t < ATTACK then
		return t / ATTACK
	end
	t = t - ATTACK
	if t < PLATEAU then
		return 1.0
	end
	local r = (t - PLATEAU) / (1 - ATTACK - PLATEAU)
	return (1 - r) ^ REL_G
end

local function rgb(c)
	return bit.band(bit.rshift(c, 16), 0xFF),
	       bit.band(bit.rshift(c, 8), 0xFF),
	       bit.band(c, 0xFF)
end

local function blend(a, b, t)
	local ar, ag, ab = rgb(a)
	local br, bg, bb = rgb(b)
	local r  = math.floor(ar + (br - ar) * t + 0.5)
	local g  = math.floor(ag + (bg - ag) * t + 0.5)
	local bl = math.floor(ab + (bb - ab) * t + 0.5)
	return r * 65536 + g * 256 + bl
end

local function accent_of(g)
	local a = accents[g]
	if a == nil then
		a = vim.api.nvim_get_hl(0, { name = g, link = false }).fg or 0xffffff
		accents[g] = a
	end
	return a
end

local function fade_group(accent, step)
	local t = fades[accent]
	if not t or t._ver ~= version then
		t = { _ver = version }
		fades[accent] = t
	end
	local name = t[step]
	if not name then
		name = string.format('MidxFade_%06x_%d', accent, step)
		local alpha = step / (STEPS - 1)
		pcall(vim.api.nvim_set_hl, 0, name, { bg = blend(background.get(), accent, alpha) })
		t[step] = name
	end
	return name
end

--- combined (SCREEN) alpha of active sources at `now`. READ-ONLY.
local function combined_alpha(f, now)
	local acomb = 0
	for i = 1, #f.sources do
		local sc      = f.sources[i]
		local elapsed = now - sc.onset
		if elapsed >= 0 and elapsed < sc.dur then
			local a = MAX_ALPHA * envelope(elapsed / sc.dur)
			acomb   = 1 - (1 - acomb) * (1 - a)
		end
	end
	return acomb
end


-- -- registry / timer ------------------------------------------------------------

local function force_redraw(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim__redraw, { buf = bufnr, valid = false, flush = true })
	end
end

--- remove a fade from the registry + index
local function drop(bufnr, id)
	local marks = anim[bufnr]
	if not marks then return end
	local f = marks[id]
	if not f then return end
	marks[id] = nil
	count = count - 1
	local rows = rowmap[bufnr]
	if rows then
		for _, r in ipairs(f.ranges) do
			local set = rows[r.ln]
			if set then
				set[id] = nil
				if next(set) == nil then rows[r.ln] = nil end
			end
		end
	end
end

--- one timer tick: purge expired sources + pump a redraw
local function tick()
	local now = uv.hrtime()

	local bg = background.get()
	if bg ~= last_bg then
		version = version + 1
		last_bg = bg
	end

	for bufnr, marks in pairs(anim) do
		if not vim.api.nvim_buf_is_valid(bufnr) then
			for _ in pairs(marks) do count = count - 1 end
			anim[bufnr]   = nil
			rowmap[bufnr] = nil
		else
			for id, f in pairs(marks) do
				local i = 1
				while i <= #f.sources do
					local sc = f.sources[i]
					if now - sc.onset >= sc.dur then
						table.remove(f.sources, i)
					else
						i = i + 1
					end
				end
				if #f.sources == 0 then
					drop(bufnr, id)
				end
			end
		end
	end

	for bufnr in pairs(anim) do
		force_redraw(bufnr)
	end

	if count <= 0 and timer then
		timer:stop()
		if not timer:is_closing() then timer:close() end
		timer = nil
	end
end

local function ensure_timer()
	if timer then return end
	timer = uv.new_timer()
	timer:start(FRAME_MS, FRAME_MS, vim.schedule_wrap(tick))
end


-- -- decoration provider ---------------------------------------------------------

local function on_start()
	frame_now = uv.hrtime()
end

local function on_win(_, _, bufnr)
	local marks = anim[bufnr]
	if not marks or next(marks) == nil then
		return false
	end
	return true
end

--- per visible line: place an ephemeral extmark for each token range on this row
local function on_line(_, _, bufnr, row)
	local rows = rowmap[bufnr]
	local ids  = rows and rows[row]
	if not ids then return end

	local marks = anim[bufnr]
	for id in pairs(ids) do
		local f = marks[id]
		if f then
			local acomb = combined_alpha(f, frame_now)
			local step  = math.floor(acomb * (STEPS - 1) + 0.5)
			if step > 0 then
				local group = fade_group(f.accent, step)
				for _, r in ipairs(f.ranges) do
					if r.ln == row then
						pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, r.ln, r.cs, {
							end_col   = r.ce,
							hl_group  = group,
							ephemeral = true,
							priority  = PRIORITY,
						})
					end
				end
			end
		end
	end
end


-- -- public API -----------------------------------------------------------------

--- Execution animation: absolute onset (`when`, server clock) + per-fire
--  duration, auto-expiring. onset_client = when + offset.
--  Cleared entirely on a new generation (render calls M.clear).
-- @param bufnr number
-- @param when number - absolute onset, server ns
-- @param resolved table - [{ id (token), group (name), dur (ns), chunks = [{ln,cs,ce}] }]
function M.animate(bufnr, when, resolved)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end
	if not resolved then return end

	anim[bufnr]   = anim[bufnr]   or {}
	rowmap[bufnr] = rowmap[bufnr] or {}
	local marks = anim[bufnr]
	local rows  = rowmap[bufnr]

	local now   = uv.hrtime()
	local onset = (when or 0) + offset

	for _, e in ipairs(resolved) do
		local dur = math.max(1e6, e.dur or 1e6)   -- ns, min 1 ms

		-- skip outdated: fade entirely in the past.
		if onset + dur >= now then
			local id = e.id
			local f  = marks[id]

			if not f then
				local ranges = {}
				for _, c in ipairs(e.chunks) do
					ranges[#ranges + 1] = { ln = c.ln, cs = c.cs, ce = c.ce }
					rows[c.ln] = rows[c.ln] or {}
					rows[c.ln][id] = true
				end
				f = { ranges = ranges, accent = accent_of(e.group), sources = {} }
				marks[id] = f
				count = count + 1
			end

			-- add a source (screen-stacked with prior ones)
			f.sources[#f.sources + 1] = { onset = onset, dur = dur }
		end
	end

	if count > 0 then ensure_timer() end
end

--- Clock sync: offset = client − server (ns), measured on receipt.
-- @param server_now number - server host time in ns
function M.sync(server_now)
	offset = uv.hrtime() - (server_now or 0)
end

--- Clear all fades of a buffer (buffer kept). Called on new generation + stop.
function M.clear(bufnr)
	local marks = anim[bufnr]
	if marks then
		for id in pairs(marks) do drop(bufnr, id) end
	end
	anim[bufnr]   = {}
	rowmap[bufnr] = {}
	force_redraw(bufnr)
end

--- Full cleanup when a buffer is unloaded.
function M.detach(bufnr)
	local marks = anim[bufnr]
	if marks then
		for id in pairs(marks) do drop(bufnr, id) end
	end
	anim[bufnr]   = nil
	rowmap[bufnr] = nil
end

--- Autocmds + provider registration (called from setup)
function M.setup()
	-- idempotent: a re-run of setup() (same module instance, e.g. reload)
	-- tears down the shared engine first so timer/provider never leak
	M.shutdown()

	vim.api.nvim_set_decoration_provider(ns, {
		on_start = on_start,
		on_win   = on_win,
		on_line  = on_line,
	})

	local augroup = vim.api.nvim_create_augroup('MidxAnimation', { clear = true })

	-- ColorScheme: invalidate accent + step caches. In-flight fades keep their
	-- captured accent number and re-render via rebuilt step groups (new bg);
	-- short-lived, so a slight color drift until they expire is fine. New fires
	-- resolve fresh accents.
	vim.api.nvim_create_autocmd('ColorScheme', {
		group    = augroup,
		callback = function()
			accents = {}
			version = version + 1
		end,
	})
end

--- Clean stop (hot reload): stop the timer, clear everything
function M.shutdown()
	if timer then
		timer:stop()
		if not timer:is_closing() then timer:close() end
		timer = nil
	end
	anim    = {}
	rowmap  = {}
	fades   = {}
	accents = {}
	count   = 0
	last_bg = nil
end

return M
