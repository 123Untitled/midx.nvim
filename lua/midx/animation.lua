-- animation.lua
-- Moteur d'animation des highlights d'exécution — via decoration provider.
--
-- Rendu : un decoration provider pose des extmarks ÉPHÉMÈRES (recalculés à chaque
--   redraw, limités au viewport). La couleur n'est PAS recolorée par frame : on
--   pré-calcule des groups de PALIERS `accent × STEPS` (fond → accent), et le
--   provider choisit le palier le plus proche de l'alpha courant. Zéro nvim_set_hl
--   par frame → le coût CPU tombe sur le seul redraw (viewport).
--
-- Timer : ne rend plus rien — il PURGE les sources expirées et FORCE un redraw
--   (pump) tant qu'il reste des fades. S'arrête à count == 0.
--
-- Pas de suivi d'éditions : le serveur re-pousse tous les highlights ; au
--   changement de buffer le plugin coupe tout (clear).
--
-- Registre : anim[bufnr][id] = { l, s, e, g, accent, sources = {{onset,dur},…} }
-- Index ligne : rowmap[bufnr][row] = { [id]=true }   (lookup O(1) dans on_line)

local background = require('midx.background')

local M = {}

local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace('midx_animation')

-- Config (fixe)
local FRAME_MS  = 16      -- ~60 fps : fluidité du fade + granularité du retard d'onset
local MAX_ALPHA = 0.50    -- intensité par source au onset (0..1) ; le screen empile au-delà
local STEPS     = 128     -- paliers du gradient fond→accent (quantif. invisible à ce compte)
local PRIORITY  = 2000     -- au-dessus de la couche syntaxe (composite : fg statique + bg fade)
-- Enveloppe du fade (fractions de la durée) : montée → pic → fade
local ATTACK  = 0.00      -- montée 0 → pic (0 = pop instantané)
local PLATEAU = 0.33      -- maintien au pic avant de fader
local REL_G   = 0.33      -- courbe du fade final (>1 = ease-out)

-- Registre + index + état du moteur
local anim    = {}
local rowmap  = {}
local count   = 0         -- nb d'entrées actives → arrêt du timer à 0
local timer   = nil

-- Paliers pré-calculés : fades[accent] = { _ver, [step] = group_name }
-- Version bumpée au ColorScheme ET au changement de bg → invalide le cache.
local fades   = {}
local version = 0
local last_bg = nil

-- Cache accent : nom de group de sense → couleur fg (invalidé au ColorScheme)
local accents = {}

-- État de frame (stampé en on_start, relu par on_line)
local frame_now = 0

-- Offset d'horloge : client − serveur (ns), mesuré au message `sync`. Les onsets
-- arrivent en temps serveur absolu → onset_client = when + offset.
local offset = 0


-- -- Maths couleur -------------------------------------------------------------

--- enveloppe alpha(t) sur t∈[0,1] : montée (ATTACK) → pic maintenu (PLATEAU) → fade
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

--- couleur accent d'un group de sense (cachée)
local function accent_of(g)
	local a = accents[g]
	if a == nil then
		a = vim.api.nvim_get_hl(0, { name = g, link = false }).fg or 0xffffff
		accents[g] = a
	end
	return a
end

--- group de palier pour (accent, step) — défini paresseusement, mis en cache par version.
--  le fond est lu au moment de la définition ; une version cohérente = un même fond.
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

--- alpha combiné (SCREEN) des sources actives, à `now`. LECTURE SEULE (le timer purge).
--  saute les sources pas encore démarrées (elapsed<0) et expirées (elapsed>=dur).
local function combined_alpha(f, now)
	local acomb = 0
	for i = 1, #f.sources do
		local sc      = f.sources[i]
		local elapsed = now - sc.onset
		if elapsed >= 0 and elapsed < sc.dur then
			local a = MAX_ALPHA * envelope(elapsed / sc.dur)
			acomb   = 1 - (1 - acomb) * (1 - a)     -- SCREEN
		end
	end
	return acomb
end


-- -- Registre / timer ----------------------------------------------------------

--- force un redraw d'un buffer → relance le provider (efface aussi les éphémères)
local function force_redraw(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim__redraw, { buf = bufnr, valid = false, flush = true })
	end
end

--- retire un fade du registre + de l'index
local function drop(bufnr, id)
	local marks = anim[bufnr]
	if not marks then return end
	local f = marks[id]
	if not f then return end
	marks[id] = nil
	count = count - 1
	local rows = rowmap[bufnr]
	if rows and rows[f.l] then
		rows[f.l][id] = nil
		if next(rows[f.l]) == nil then rows[f.l] = nil end
	end
end

--- un tick du timer global : purge des sources expirées + pump de redraw
local function tick()
	local now = uv.hrtime()

	-- bg dynamique (OSC 11 async / colorscheme) → invalide les paliers
	local bg = background.get()
	if bg ~= last_bg then
		version = version + 1
		last_bg = bg
	end

	for bufnr, marks in pairs(anim) do
		if not vim.api.nvim_buf_is_valid(bufnr) then
			for _ in pairs(marks) do count = count - 1 end   -- purge du décompte
			anim[bufnr]   = nil
			rowmap[bufnr] = nil
		else
			for id, f in pairs(marks) do
				local i = 1
				while i <= #f.sources do
					local sc = f.sources[i]
					if now - sc.onset >= sc.dur then
						table.remove(f.sources, i)          -- source terminée
					else
						i = i + 1
					end
				end
				if #f.sources == 0 then
					drop(bufnr, id)                         -- plus aucune source
				end
			end
		end
	end

	-- pump : redraw des buffers restants (et une dernière fois pour effacer à vide)
	for bufnr in pairs(anim) do
		force_redraw(bufnr)
	end

	if count <= 0 and timer then
		timer:stop()
		if not timer:is_closing() then timer:close() end
		timer = nil
	end
end

--- démarre le timer global si besoin
local function ensure_timer()
	if timer then return end
	timer = uv.new_timer()
	timer:start(FRAME_MS, FRAME_MS, vim.schedule_wrap(tick))
end


-- -- Decoration provider --------------------------------------------------------

--- début du cycle de redraw : stampe le temps commun à toutes les lignes de la frame
local function on_start()
	frame_now = uv.hrtime()
end

--- par fenêtre : ignore les buffers sans animation (skip on_line)
local function on_win(_, _, bufnr)
	local marks = anim[bufnr]
	if not marks or next(marks) == nil then
		return false
	end
	return true
end

--- par ligne visible : pose un extmark éphémère pour chaque token de cette ligne
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
				pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, f.l, f.s, {
					end_col   = f.e,
					hl_group  = fade_group(f.accent, step),
					ephemeral = true,
					priority  = PRIORITY,
				})
			end
		end
	end
end


-- -- API publique --------------------------------------------------------------

--- Animation d'exécution : onset ABSOLU global (`when`, horloge serveur) + durée
--  par event, auto-expiration. onset_client = when + offset.
--  Le nettoyage n'est plus piloté par le serveur : le client clear au stop.
-- @param msg table - { when (ns absolu), at = [{ id, l, s, e, g, d (ns) }] }
function M.animate(bufnr, msg)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end
	if not msg.at then return end

	anim[bufnr]   = anim[bufnr]   or {}
	rowmap[bufnr] = rowmap[bufnr] or {}
	local marks = anim[bufnr]
	local rows  = rowmap[bufnr]

	local now   = uv.hrtime()
	local onset = (msg.when or 0) + offset     -- serveur absolu → horloge client

	for _, h in ipairs(msg.at) do
		local dur = math.max(1e6, h.d or 1e6)  -- ns, min 1 ms

		-- skip les outdated : fade ENTIÈREMENT dans le passé (traité en retard).
		-- partiellement actif ou futur → gardé (combined_alpha gère la queue).
		if onset + dur >= now then
			local id = h.id
			local f  = marks[id]

			if not f then
				local g = h.g or 'Normal'
				f = {
					l       = (h.l or 0),
					s       = (h.s or 0),
					e       = (h.e or -1),
					g       = g,                          -- sense (pour refresh accent)
					accent  = accent_of(g),
					sources = {},
				}
				marks[id] = f
				rows[f.l] = rows[f.l] or {}
				rows[f.l][id] = true
				count = count + 1
			end

			-- combine : on AJOUTE une source (on n'écrase pas les autres)
			f.sources[#f.sources + 1] = { onset = onset, dur = dur }
		end
	end

	if count > 0 then ensure_timer() end
end

--- Synchro d'horloge : offset = client − serveur (ns), mesuré à la réception.
--  même machine (socket Unix) → offset constant, une mesure au connect suffit.
-- @param server_now number - host_time::now().to_ns() du serveur
function M.sync(server_now)
	local client_now = uv.hrtime()
	offset = client_now - (server_now or 0)
end

--- Efface les animations d'un buffer (buffer conservé)
function M.clear(bufnr)
	local marks = anim[bufnr]
	if marks then
		for id in pairs(marks) do drop(bufnr, id) end
	end
	anim[bufnr]   = {}
	rowmap[bufnr] = {}
	force_redraw(bufnr)
end

--- Nettoyage complet quand un buffer est déchargé
function M.detach(bufnr)
	local marks = anim[bufnr]
	if marks then
		for id in pairs(marks) do drop(bufnr, id) end
	end
	anim[bufnr]   = nil
	rowmap[bufnr] = nil
end

--- Autocmds + enregistrement du provider (appelé depuis le setup)
function M.setup()
	vim.api.nvim_set_decoration_provider(ns, {
		on_start = on_start,
		on_win   = on_win,
		on_line  = on_line,
	})

	local augroup = vim.api.nvim_create_augroup('MidxAnimation', { clear = true })

	-- colorscheme → invalide accents + paliers, rafraîchit les accents en cours
	vim.api.nvim_create_autocmd('ColorScheme', {
		group    = augroup,
		callback = function()
			accents = {}
			version = version + 1                     -- invalide les paliers
			for _, marks in pairs(anim) do
				for _, f in pairs(marks) do
					f.accent = accent_of(f.g)
				end
			end
		end,
	})
end

--- Arrêt propre (reload à chaud) : stoppe le timer, vide tout
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
