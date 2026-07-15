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
local FRAME_MS   = 16     -- cadence du fade (~60 fps)
local MAX_ALPHA  = 0.35   -- intensité du glow au onset (0..1)
local FADE_GAMMA = 0.5    -- 1 = linéaire ; >1 = ease-out (chute vive + traîne) ; <1 = ease-in (tient puis lâche)

--- courbe du fade : progression temporelle t∈[0,1] → progression du gradient ∈[0,1]
local function curve(t)
	return 1 - (1 - t) ^ FADE_GAMMA
end

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
	if not definitive then
		query_terminal_bg()          -- affinera resolved_bg à la réponse
	end
end

-- Autocmds : re-setup au changement de colorscheme + capture de la réponse OSC
local augroup = vim.api.nvim_create_augroup('MidxHighlightColors', { clear = true })

-- changement de colorscheme → re-résoudre le fond (les fades le relisent à chaque frame)
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
	end,
})

-- résolution initiale (l'autocmd TermResponse est déjà posé pour capter la réponse)
resolve_bg()


-- -- Timer global ------------------------------------------------------------
-- Un seul timer pour tous les fades. À chaque frame : place à l'onset,
-- recolore le group du token (fade continu), retire à l'échéance.
-- On recolore le GROUP (pas l'extmark) → l'extmark n'est jamais retouché
-- après pose → il suit les éditions et ne peut plus être "out of range".

local fade_timer = nil

--- retire un fade (extmark + registre)
local function drop(bufnr, marks, id)
	local f = marks[id]
	if not f then return end
	marks[id] = nil
	if f.mark and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_animation, f.mark)
	end
end

--- reste-t-il des fades en cours ?
local function any_active()
	for _, marks in pairs(anim) do
		if next(marks) then return true end
	end
	return false
end

--- un tick du timer global
local function tick()
	local now = vim.loop.hrtime()

	for bufnr, marks in pairs(anim) do
		if not vim.api.nvim_buf_is_valid(bufnr) then
			anim[bufnr] = nil
		else
			for id, f in pairs(marks) do

				-- enveloppe = max de l'alpha sur les sources actives ; purge des expirées
				local amax = -1
				local i = 1
				while i <= #f.sources do
					local sc      = f.sources[i]
					local elapsed = now - sc.onset
					if elapsed >= sc.dur then
						table.remove(f.sources, i)          -- source terminée
					else
						if elapsed >= 0 then                -- source démarrée (onset passé)
							local a = MAX_ALPHA * (1 - curve(elapsed / sc.dur))
							if a > amax then amax = a end
						end
						i = i + 1
					end
				end

				if #f.sources == 0 then
					drop(bufnr, marks, id)                  -- plus aucune source
				elseif amax >= 0 then
					-- au moins une source a démarré → pose (si besoin) + recolore
					if not f.mark then
						local ok, mark = pcall(vim.api.nvim_buf_set_extmark,
							bufnr, ns_animation, f.l, f.s,
							{ end_col = f.e, hl_group = f.group })
						if ok then f.mark = mark else drop(bufnr, marks, id) end
					end
					if f.mark then
						local color = blend(resolved_bg, f.accent, amax)
						if color ~= f.last then             -- évite les set_hl redondants
							f.last = color
							pcall(vim.api.nvim_set_hl, 0, f.group, { bg = color })
						end
					end
				end
				-- sinon : sources encore en attente d'onset → on ne pose pas encore
			end
		end
	end

	if not any_active() and fade_timer then
		fade_timer:stop()
		if not fade_timer:is_closing() then fade_timer:close() end
		fade_timer = nil
	end
end

--- démarre le timer global si besoin
local function ensure_timer()
	if fade_timer then return end
	fade_timer = vim.loop.new_timer()
	fade_timer:start(FRAME_MS, FRAME_MS, vim.schedule_wrap(tick))
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
		for id in pairs(marks) do drop(bufnr, marks, id) end
		vim.api.nvim_buf_clear_namespace(bufnr, ns_animation, 0, -1)
	end

	if not msg.on then return end

	local now   = vim.loop.hrtime()
	local delay = msg.delay or 0        -- ns

	for _, h in ipairs(msg.on) do
		local id = h.id
		local f  = marks[id]

		if not f then
			local sense = vim.api.nvim_get_hl(0, { name = (h.g or 'Normal'), link = false })
			f = {
				l       = (h.l or 0),
				s       = (h.s or 0),
				e       = (h.e or -1),
				accent  = sense.fg or 0xffffff,
				group   = string.format('MidxFade_%d_%d', bufnr, id),
				mark    = nil,
				last    = nil,
				sources = {},
			}
			marks[id] = f
		end

		-- combine : on AJOUTE une source (on n'écrase pas les autres)
		f.sources[#f.sources + 1] = {
			onset = now + delay,                     -- ns
			dur   = math.max(1e6, h.d or 1e6),       -- ns, min 1 ms
		}
	end

	ensure_timer()
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
	local marks = anim[bufnr]
	if marks then
		for id in pairs(marks) do drop(bufnr, marks, id) end
	end
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns_animation, 0, -1)
	end
	anim[bufnr] = {}
end

--- Nettoyage complet quand un buffer est déchargé
function M.detach(bufnr)
	local marks = anim[bufnr]
	if marks then
		for id in pairs(marks) do drop(bufnr, marks, id) end
	end
	anim[bufnr] = nil
end

return M
