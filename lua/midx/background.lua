-- background.lua
-- Résolution de la couleur de fond du buffer — cible du fade des animations.
-- Priorité : Normal.bg (définitif) → OSC 11 (vrai fond terminal, async)
--   avec terminal_color_0 / gris en PROVISOIRE tant que l'OSC n'a pas répondu.

local M = {}

local resolved    = 0x1e1e1e   -- meilleure valeur connue (affinée par resolve)
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
	if not ok then
		osc_pending = false
		return
	end
	-- garde-fou : si le terminal ne répond jamais (GUI, terminal muet),
	-- on débloque après 1 s → une réponse tardive/étrangère ne sera pas mal consommée
	vim.defer_fn(function() osc_pending = false end, 1000)
end

--- (re)résout le fond : sync tout de suite, OSC si Normal.bg absent
local function resolve()
	local bg, definitive = sync_bg()
	resolved = bg
	if not definitive then
		query_terminal_bg()          -- affinera `resolved` à la réponse
	end
end


-- -- API publique --------------------------------------------------------------

--- couleur de fond courante (relue à chaque frame par le moteur)
function M.get()
	return resolved
end

--- enregistre les autocmds + résolution initiale (appelé depuis le setup)
function M.setup()
	local augroup = vim.api.nvim_create_augroup('MidxBackground', { clear = true })

	-- changement de colorscheme → re-résoudre le fond
	vim.api.nvim_create_autocmd('ColorScheme', {
		group    = augroup,
		callback = function() resolve() end,
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
			resolved = tonumber(r:sub(1, 2), 16) * 65536
			         + tonumber(g:sub(1, 2), 16) * 256
			         + tonumber(b:sub(1, 2), 16)
		end,
	})

	resolve()
end

return M
