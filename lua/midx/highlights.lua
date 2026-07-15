-- highlights.lua
-- Rendu des highlights envoyés par le serveur :
--   - syntaxe statique  (message "highlight")
--   - animation d'exécution (message "animation" : delay + durée + auto-expiration)
--   - diagnostics       (message "diagnostic")

local M = {}

-- Namespaces
local ns_syntax    = vim.api.nvim_create_namespace('midx')
local ns_animation = vim.api.nvim_create_namespace('midx_animation')
local ns_diag      = vim.api.nvim_create_namespace('midx_diag')

-- État d'animation par buffer : bufnr → { [id] = { mark, timers = {} } }
local anim = {}


-- -- Fade : gradient de groupes ------------------------------------------------

-- Config (ajustable)
local FADE_STEPS = 12     -- niveaux du gradient
local FRAME_MS   = 16     -- cadence du fade (~60 fps)
local MAX_ALPHA  = 0.35   -- intensité du glow au onset (0..1)
local FADE_GAMMA = 2.0    -- 1 = linéaire ; >1 = ease-out (chute vive + traîne) ; <1 = ease-in (tient puis lâche)

--- courbe du fade : progression temporelle t∈[0,1] → progression du gradient ∈[0,1]
local function curve(t)
	return 1 - (1 - t) ^ FADE_GAMMA
end

-- Cache : group de sense → { nom de highlight par niveau }
local gradients = {}

--- extrait (r, g, b) d'un 0xRRGGBB
local function rgb(c)
	return bit.band(bit.rshift(c, 16), 0xFF),
	       bit.band(bit.rshift(c, 8), 0xFF),
	       bit.band(c, 0xFF)
end

--- blend a → b au ratio t (0 = a, 1 = b)
local function blend(a, b, t)
	local ar, ag, ab = rgb(a)
	local br, bg, bb = rgb(b)
	local r  = math.floor(ar + (br - ar) * t + 0.5)
	local g  = math.floor(ag + (bg - ag) * t + 0.5)
	local bl = math.floor(ab + (bb - ab) * t + 0.5)
	return r * 65536 + g * 256 + bl
end


-- -- Résolution du fond ---------------------------------------------------------
-- Le fond du buffer est la cible du fade. Priorité :
--   Normal.bg (définitif)  →  OSC 11 (vrai fond terminal, async)
-- avec terminal_color_0 / gris en PROVISOIRE tant que l'OSC n'a pas répondu.

local resolved_bg = 0x1e1e1e   -- meilleure valeur connue (affinée par resolve_bg)
local osc_pending = false

--- valeur synchrone ; retourne (couleur, definitif)
--   definitif = true → Normal.bg posé, pas besoin d'OSC
local function sync_bg()
	local n = vim.api.nvim_get_hl(0, { name = 'Normal' }).bg
	if n then return n, true end

	local t0 = vim.g.terminal_color_0            -- ANSI 0 du colorscheme
	if type(t0) == 'string' then
		local v = tonumber((t0:gsub('#', '')), 16)
		if v then return v, false end
	end

	return (vim.o.background == 'light') and 0xeeeeee or 0x1e1e1e, false
end

--- interroge le terminal (OSC 11) ; la réponse arrive via TermResponse
local function query_terminal_bg()
	osc_pending = true
	local ok = pcall(function()
		io.stdout:write('\027]11;?\027\\')
		io.stdout:flush()
	end)
	if not ok then osc_pending = false end
end

--- (re)résout le fond : sync tout de suite, OSC si Normal.bg absent
local function resolve_bg()
	local bg, definitive = sync_bg()
	resolved_bg = bg
	gradients   = {}                 -- fond changé → gradients à reconstruire
	if not definitive then
		query_terminal_bg()          -- affinera resolved_bg à la réponse
	end
end

--- construit (et cache) le gradient de bg pour un group de sense
local function build_gradient(g)

	local cached = gradients[g]
	if cached then return cached end

	local sense  = vim.api.nvim_get_hl(0, { name = g, link = false })
	local accent = sense.fg or 0xffffff
	local bg     = resolved_bg

	local levels = {}
	for k = 0, FADE_STEPS - 1 do
		local alpha = MAX_ALPHA * (1 - k / (FADE_STEPS - 1))   -- MAX_ALPHA → 0
		local name  = string.format('MidxFade_%s_%d', g, k)
		vim.api.nvim_set_hl(0, name, { bg = blend(bg, accent, alpha) })
		levels[k + 1] = name
	end

	gradients[g] = levels
	return levels
end

-- Autocmds : re-setup au changement de colorscheme + capture de la réponse OSC
local augroup = vim.api.nvim_create_augroup('MidxHighlightColors', { clear = true })

-- changement de colorscheme → tout re-résoudre (fond + gradients)
vim.api.nvim_create_autocmd('ColorScheme', {
	group    = augroup,
	callback = function() resolve_bg() end,
})

-- réponse du terminal à notre requête OSC 11 (vrai fond)
vim.api.nvim_create_autocmd('TermResponse', {
	group    = augroup,
	callback = function(args)
		if not osc_pending then return end
		local seq = (type(args.data) == 'table' and args.data.sequence) or args.data or ''
		local r, g, b = tostring(seq):match('11;rgb:(%x+)/(%x+)/(%x+)')
		if not r then return end
		osc_pending = false
		-- composantes sur 16 bits (4 hex) → on garde les 2 premiers
		resolved_bg = tonumber(r:sub(1, 2), 16) * 65536
		            + tonumber(g:sub(1, 2), 16) * 256
		            + tonumber(b:sub(1, 2), 16)
		gradients = {}               -- vrai fond connu → gradients à reconstruire
	end,
})

-- résolution initiale (l'autocmd TermResponse est déjà posé pour capter la réponse)
resolve_bg()


-- -- Helpers internes ---------------------------------------------------------

--- Annule les timers + retire l'extmark d'un id
local function cancel_mark(bufnr, marks, id)
	local entry = marks[id]
	if not entry then return end
	marks[id] = nil
	for _, t in ipairs(entry.timers) do
		t:stop()
		if not t:is_closing() then t:close() end
	end
	if entry.mark and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_animation, entry.mark)
	end
end

--- Annule toutes les animations d'un buffer
local function cancel_all(bufnr)
	local marks = anim[bufnr]
	if not marks then return end
	for id in pairs(marks) do
		cancel_mark(bufnr, marks, id)
	end
end


-- -- API publique -------------------------------------------------------------

--- Highlights de syntaxe (statique)
-- @param list table - [{ ls, cs, ce, le?, g }]
function M.syntax(bufnr, list)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end

	vim.api.nvim_buf_clear_namespace(bufnr, ns_syntax, 0, -1)

	for _, h in ipairs(list or {}) do
		local ok, err = pcall(
			vim.api.nvim_buf_set_extmark,
			bufnr, ns_syntax,
			(h.ls or 0), (h.cs or 0),
			{
				end_row  = (h.le or h.ls or 0),
				end_col  = (h.ce or -1),
				hl_group = (h.g or 'Normal'),
			})
		if not ok then
			vim.notify(
				string.format('[midx] syntax extmark failed: %s (l=%s c=%s..%s g=%s)',
					tostring(err), tostring(h.ls), tostring(h.cs), tostring(h.ce), tostring(h.g)),
				vim.log.levels.WARN)
		end
	end
end

--- Animation d'exécution : delay global + durée par event, auto-expiration.
-- @param msg table - { delay (ns), clear?, on = [{ id, l, s, e, g, d (ns) }] }
function M.animate(bufnr, msg)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end
	if not anim[bufnr] then anim[bufnr] = {} end
	local marks = anim[bufnr]

	if msg.clear then
		cancel_all(bufnr)
		vim.api.nvim_buf_clear_namespace(bufnr, ns_animation, 0, -1)
	end

	if not msg.on then return end

	local delay_ms = math.max(0, math.floor((msg.delay or 0) / 1e6))

	for _, h in ipairs(msg.on) do
		local id = h.id
		cancel_mark(bufnr, marks, id)   -- re-trigger : on écrase le fade en cours

		local entry = { mark = nil, timers = {} }
		marks[id] = entry

		local dur_ms = math.max(1, math.floor((h.d or 0) / 1e6))
		local l, s, e, g = (h.l or 0), (h.s or 0), (h.e or -1), (h.g or 'Normal')

		-- timer onset : après le delay global (synchro avec l'émission MIDI)
		local t_on = vim.loop.new_timer()
		entry.timers[#entry.timers + 1] = t_on
		t_on:start(delay_ms, 0, vim.schedule_wrap(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				cancel_mark(bufnr, marks, id); return
			end
			local levels = build_gradient(g)
			local ok, mark = pcall(vim.api.nvim_buf_set_extmark,
				bufnr, ns_animation, l, s,
				{ end_col = e, hl_group = levels[1] })
			if not ok then
				cancel_mark(bufnr, marks, id); return
			end
			entry.mark = mark

			-- fade : parcourt le gradient sur dur_ms, puis retire
			local elapsed  = 0
			local last_lvl = 1
			local t_fade = vim.loop.new_timer()
			entry.timers[#entry.timers + 1] = t_fade
			t_fade:start(FRAME_MS, FRAME_MS, vim.schedule_wrap(function()
				if not vim.api.nvim_buf_is_valid(bufnr) or not entry.mark then
					cancel_mark(bufnr, marks, id); return
				end
				elapsed = elapsed + FRAME_MS
				if elapsed >= dur_ms then
					cancel_mark(bufnr, marks, id); return
				end
				local lvl = math.min(FADE_STEPS,
					math.floor(curve(elapsed / dur_ms) * FADE_STEPS) + 1)
				if lvl ~= last_lvl then
					last_lvl = lvl
					-- position ACTUELLE (nvim l'a ajustée aux éditions) → jamais out of range
					local pos = vim.api.nvim_buf_get_extmark_by_id(
						bufnr, ns_animation, entry.mark, { details = true })
					if not pos or not pos[1] then
						cancel_mark(bufnr, marks, id); return
					end
					pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_animation,
						pos[1], pos[2],
						{
							id       = entry.mark,
							end_row  = pos[3] and pos[3].end_row,
							end_col  = pos[3] and pos[3].end_col,
							hl_group = levels[lvl],
						})
				end
			end))
		end))
	end
end

--- Diagnostics
-- @param list table - [{ l, s, e, m }]
function M.diagnostics(bufnr, list)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end

	local diags = {}
	for _, d in ipairs(list or {}) do
		diags[#diags + 1] = {
			lnum     = (d.l or 0),
			col      = (d.s or 0),
			end_col  = math.max((d.e or 0), (d.s or 0) + 1),
			message  = (d.m or 'unknown error'),
			severity = vim.diagnostic.severity.ERROR,
			source   = 'midx',
		}
	end
	vim.diagnostic.set(ns_diag, bufnr, diags, {})
end

--- Efface les animations d'un buffer (toggle / stop côté client), buffer conservé
function M.clear(bufnr)
	cancel_all(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns_animation, 0, -1)
	end
	anim[bufnr] = {}
end

--- Nettoyage complet quand un buffer est déchargé
function M.detach(bufnr)
	cancel_all(bufnr)
	anim[bufnr] = nil
end

return M
