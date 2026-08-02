-- syntax.lua
-- Static syntax rendering: tokens + comments → extmarks.
-- Each token carries a numeric sx::id (mapped to a highlight group via
-- protocol/mirror) and a dim flag; dimmed tokens keep their semantic group
-- but fade toward the background via a derived MidxDim<group> group.

local background = require('midx.background')
local mirror     = require('midx.protocol.mirror')

local M = {}

local ns_syntax = vim.api.nvim_create_namespace('midx')
local ns_dim    = vim.api.nvim_create_namespace('midx_dim')   -- base "Comment" layer


-- -- dim variants ---------------------------------------------------------------
-- The `d` flag keeps the semantic group; the color is blended toward the
-- background. Derived groups MidxDim<G>, built lazily, cache cleared on
-- ColorScheme.

local DIM_BLEND = 0.4          -- 0 = full color, 1 = background
local dim_cache = {}

--- linear per-channel blend between two 24-bit colors
local function dim_color(fg, bg, t)
	local rf = math.floor(fg / 65536) % 256
	local gf = math.floor(fg / 256)   % 256
	local bf = fg % 256
	local rb = math.floor(bg / 65536) % 256
	local gb = math.floor(bg / 256)   % 256
	local bb = bg % 256
	return math.floor(rf + (rb - rf) * t + 0.5) * 65536
	     + math.floor(gf + (gb - gf) * t + 0.5) * 256
	     + math.floor(bf + (bb - bf) * t + 0.5)
end


-- -- xterm-256 palette -----------------------------------------------------------
-- cterm schemes (or termguicolors off) render via ctermfg: dim variants must
-- exist in 256 colors too.

local ansi16 = {
	[0] = 0x000000, 0x800000, 0x008000, 0x808000,
	      0x000080, 0x800080, 0x008080, 0xc0c0c0,
	      0x808080, 0xff0000, 0x00ff00, 0xffff00,
	      0x0000ff, 0xff00ff, 0x00ffff, 0xffffff,
}

local cube = { [0] = 0, 95, 135, 175, 215, 255 }

--- xterm-256 index → 24-bit color (standard approximation for 0-15)
local function cterm_to_rgb(i)
	if i < 16 then
		return ansi16[i]
	end
	if i >= 232 then
		local v = 8 + (i - 232) * 10
		return v * 65536 + v * 256 + v
	end
	i = i - 16
	local r = cube[math.floor(i / 36)]
	local g = cube[math.floor(i / 6) % 6]
	local b = cube[i % 6]
	return r * 65536 + g * 256 + b
end

--- 24-bit color → nearest xterm-256 index (6x6x6 cube or grayscale)
local function rgb_to_cterm(c)
	local r = math.floor(c / 65536) % 256
	local g = math.floor(c / 256)   % 256
	local b = c % 256

	local function level(v)
		if v < 48  then return 0 end
		if v < 115 then return 1 end
		return math.min(5, math.floor((v - 35) / 40))
	end
	local qr, qg, qb = level(r), level(g), level(b)
	local cr, cg, cb = cube[qr], cube[qg], cube[qb]

	local avg = math.floor((r + g + b) / 3)
	local gi  = math.max(0, math.min(23, math.floor((avg - 3) / 10)))
	local gv  = 8 + gi * 10

	local function dist(x, y, z)
		return (r - x) ^ 2 + (g - y) ^ 2 + (b - z) ^ 2
	end

	if dist(gv, gv, gv) < dist(cr, cg, cb) then
		return 232 + gi
	end
	return 16 + 36 * qr + 6 * qg + qb
end

--- derived dimmed group for a semantic group
-- @param g string - source group (e.g. 'Operator')
-- @return string - derived group name
local function dim_group(g)
	local cached = dim_cache[g]
	if cached then return cached end

	local name = 'MidxDim' .. g:gsub('[^%w]', '_')

	-- resolve the link chain by hand to reach concrete attributes
	-- (link=false is not reliable across nvim versions)
	local hl
	local target = g
	for _ = 1, 8 do
		local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = target })
		if not ok or not h then break end
		if h.link then
			target = h.link
		else
			hl = h
			break
		end
	end

	local fg  = (hl and hl.fg)      or nil
	local cfg = (hl and hl.ctermfg) or nil

	if fg or cfg then
		local bg  = background.get()
		local def = { bold = hl.bold, italic = hl.italic }

		if fg then
			def.fg = dim_color(fg, bg, DIM_BLEND)
		end
		if cfg then
			def.ctermfg = rgb_to_cterm(dim_color(cterm_to_rgb(cfg), bg, DIM_BLEND))
		end

		vim.api.nvim_set_hl(0, name, def)
	else
		-- no resolvable color in any mode: fall back to Comment
		vim.api.nvim_set_hl(0, name, { link = 'Comment' })
	end

	dim_cache[g] = name
	return name
end


-- -- rendering -----------------------------------------------------------------

--- Apply the current generation's static highlights.
-- @param bufnr number
-- @param tokens table - [{ group (sx::id), dimmed, chunks = [{ln,cs,ce}] }]
-- @param comments table - [{ ls, le, cs, ce }]
function M.apply(bufnr, tokens, comments)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end

	vim.api.nvim_buf_clear_namespace(bufnr, ns_syntax, 0, -1)

	local set = vim.api.nvim_buf_set_extmark

	-- nvim_buf_set_extmark raises on an out-of-bounds position. In theory the
	-- current generation's positions match the current buffer (immediacy gate +
	-- synchronous apply), so they are valid — but we do NOT trust the server:
	-- a bug there could produce a bad range, and pcall isolates it so one bad
	-- extmark doesn't abort the whole repaint.
	--
	-- PERF: pcall wraps every extmark (per chunk, per keystroke). The fast path
	-- below drops it. Enable ONLY once the server is trusted — WARNING: without
	-- pcall, a single bad position from the server aborts the entire repaint.

	for _, tk in ipairs(tokens) do
		local group = mirror.GROUPS[tk.group] or 'Normal'
		if tk.dimmed then
			group = dim_group(group)
		end
		for _, c in ipairs(tk.chunks) do
			-- pcall(set, bufnr, ns_syntax, c.ln, c.cs, {
			-- 	end_row  = c.ln,          -- a chunk is always single-line
			-- 	end_col  = c.ce,
			-- 	hl_group = group,
			-- 	priority = 100,           -- above the base "Comment" layer (prio 1)
			-- })
			-- fast path (no pcall) — see WARNING above:
			set(bufnr, ns_syntax, c.ln, c.cs, {
				end_row = c.ln, end_col = c.ce, hl_group = group, priority = 100,
			})
		end
	end

	for _, c in ipairs(comments) do
		pcall(set, bufnr, ns_syntax, c.ls, c.cs, {
			end_row  = c.le,              -- comments may span lines
			end_col  = c.ce,
			hl_group = 'Comment',
			priority = 100,
		})
		-- fast path (no pcall) — see WARNING above:
		-- set(bufnr, ns_syntax, c.ls, c.cs, {
		-- 	end_row = c.le, end_col = c.ce, hl_group = 'Comment', priority = 100,
		-- })
	end
end

--- Base "Comment" layer covering the WHOLE buffer (under the syntax layer).
--  Re-applied on each edit to cover new content before the server answers.
--  Named `cover` to avoid confusion with the dimmed-token machinery above.
function M.cover(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end
	vim.api.nvim_buf_clear_namespace(bufnr, ns_dim, 0, -1)
	local last = vim.api.nvim_buf_line_count(bufnr) - 1
	local line = vim.api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1] or ''
	pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_dim, 0, 0, {
		end_row  = last,
		end_col  = #line,
		hl_group = 'Comment',
		priority = 1,
	})
end

--- Clear the syntax layer (back to the "Comment" base) — on server disconnect.
function M.clear(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns_syntax, 0, -1)
	end
end

--- Setup: invalidate the dim cache on ColorScheme (colors + bg moved).
function M.setup()
	vim.api.nvim_create_autocmd('ColorScheme', {
		group    = vim.api.nvim_create_augroup('MidxSyntaxDim', { clear = true }),
		callback = function()
			dim_cache = {}
		end,
	})
end

return M
