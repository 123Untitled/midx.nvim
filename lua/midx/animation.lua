-- animation.lua
-- Moteur d'animation des highlights d'exécution.
--
-- Un seul timer global pour tous les fades. À chaque frame, pour chaque token :
--   - on combine (SCREEN) l'alpha de ses sources actives,
--   - on pose son extmark au premier onset, on recolore SON group (pas l'extmark
--     → il suit les éditions, jamais "out of range"), on le retire à l'échéance.
--
-- Registre : anim[bufnr][id] = { l, s, e, g, accent, group, mark, last, sources }
--   sources = { { onset (ns), dur (ns) }, ... }   -- combinées en enveloppe

local background = require('midx.background')

local M = {}

local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace('midx_animation')

-- Config (fixe)
local FRAME_MS   = 16     -- ~60 fps : gouverne la fluidité du fade ET la granularité
                          -- du retard d'onset (l'allumage est capté au prochain tick)
local MAX_ALPHA  = 0.50   -- intensité par source au onset (0..1) ; le screen empile au-delà
-- Enveloppe du fade (fractions de la durée de la note) : montée → pic → fade
local ATTACK  = 0.00      -- montée 0 → pic (0 = pop instantané)
local PLATEAU = 0.33      -- maintien au pic avant de fader
local REL_G   = 0.33       -- courbe du fade final (>1 = ease-out : chute vive + traîne)

-- Registre + état du moteur
local anim    = {}
local count   = 0         -- nb d'entrées actives → arrêt du timer à 0
local timer   = nil

-- Cache accent : nom de group de sense → couleur fg (invalidé au ColorScheme)
local accents = {}


-- -- Maths couleur -------------------------------------------------------------

--- enveloppe alpha(t) sur t∈[0,1] : montée (ATTACK) → pic maintenu (PLATEAU) → fade
local function envelope(t)
	if t < ATTACK then
		return t / ATTACK                                -- montée vers le pic
	end
	t = t - ATTACK
	if t < PLATEAU then
		return 1.0                                       -- plateau au pic
	end
	local r = (t - PLATEAU) / (1 - ATTACK - PLATEAU)     -- 0→1 sur le release
	return (1 - r) ^ REL_G                               -- fade final
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


-- -- Registre / timer ----------------------------------------------------------

--- retire un fade (extmark + registre)
local function drop(bufnr, marks, id)
	local f = marks[id]
	if not f then return end
	marks[id] = nil
	count = count - 1
	if f.mark and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, f.mark)
	end
end

--- un tick du timer global
local function tick()
	local now = uv.hrtime()
	local bg  = background.get()

	for bufnr, marks in pairs(anim) do
		if not vim.api.nvim_buf_is_valid(bufnr) then
			for _ in pairs(marks) do count = count - 1 end   -- purge du décompte
			anim[bufnr] = nil
		else
			for id, f in pairs(marks) do

				-- enveloppe SCREEN sur les sources actives ; purge des expirées
				local acomb   = 0
				local started = false
				local i = 1
				while i <= #f.sources do
					local sc      = f.sources[i]
					local elapsed = now - sc.onset
					if elapsed >= sc.dur then
						table.remove(f.sources, i)          -- source terminée
					else
						if elapsed >= 0 then                -- source démarrée
							started = true
							local a = MAX_ALPHA * envelope(elapsed / sc.dur)
							acomb   = 1 - (1 - acomb) * (1 - a)
						end
						i = i + 1
					end
				end

				if #f.sources == 0 then
					drop(bufnr, marks, id)                  -- plus aucune source
				else
					-- pose l'extmark au PREMIER onset
					if started and not f.mark then
						local ok, mark = pcall(vim.api.nvim_buf_set_extmark,
							bufnr, ns, f.l, f.s,
							{ end_col = f.e, hl_group = f.group })
						if ok then f.mark = mark else drop(bufnr, marks, id) end
					end
					-- recolore dès que l'extmark existe (acomb=0 → fond pendant un gap)
					if f.mark then
						local color = blend(bg, f.accent, acomb)
						if color ~= f.last then
							f.last = color
							pcall(vim.api.nvim_set_hl, 0, f.group, { bg = color })
						end
					end
				end
			end
		end
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


-- -- API publique --------------------------------------------------------------

--- Animation d'exécution : delay global + durée par event, auto-expiration.
-- @param msg table - { delay (ns), clear?, on = [{ id, l, s, e, g, d (ns) }] }
function M.animate(bufnr, msg)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end
	if not anim[bufnr] then anim[bufnr] = {} end
	local marks = anim[bufnr]

	if msg.clear then
		for id in pairs(marks) do drop(bufnr, marks, id) end
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	end

	if not msg.on then return end

	local now   = uv.hrtime()
	local delay = msg.delay or 0        -- ns

	for _, h in ipairs(msg.on) do
		local id = h.id
		local f  = marks[id]

		if not f then
			local g = h.g or 'Normal'
			f = {
				l       = (h.l or 0),
				s       = (h.s or 0),
				e       = (h.e or -1),
				g       = g,                              -- sense (pour refresh accent)
				accent  = accent_of(g),
				group   = string.format('MidxFade_%d_%d', bufnr, id),
				mark    = nil,
				last    = nil,
				sources = {},
			}
			marks[id] = f
			count = count + 1
		end

		-- combine : on AJOUTE une source (on n'écrase pas les autres)
		f.sources[#f.sources + 1] = {
			onset = now + delay,                     -- ns
			dur   = math.max(1e6, h.d or 1e6),       -- ns, min 1 ms
		}
	end

	ensure_timer()
end

--- Efface les animations d'un buffer (buffer conservé)
function M.clear(bufnr)
	local marks = anim[bufnr]
	if marks then
		for id in pairs(marks) do drop(bufnr, marks, id) end
	end
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
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

--- Autocmds du moteur : rafraîchit les accents au changement de colorscheme
function M.setup()
	local augroup = vim.api.nvim_create_augroup('MidxAnimation', { clear = true })

	vim.api.nvim_create_autocmd('ColorScheme', {
		group    = augroup,
		callback = function()
			accents = {}                             -- invalide le cache accent
			for _, marks in pairs(anim) do           -- rafraîchit les fades en cours
				for _, f in pairs(marks) do
					f.accent = accent_of(f.g)
					f.last   = nil                   -- force un recolore au prochain tick
				end
			end
		end,
	})
end

--- Arrêt propre (reload à chaud) : stoppe le timer, vide le registre
function M.shutdown()
	if timer then
		timer:stop()
		if not timer:is_closing() then timer:close() end
		timer = nil
	end
	anim    = {}
	count   = 0
	accents = {}
end

return M
