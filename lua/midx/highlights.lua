-- highlights.lua
-- Façade de rendu des messages serveur :
--   - syntaxe statique  (message "highlight")
--   - diagnostics        (message "diagnostic")
--   - animation d'exécution → déléguée à animation.lua (le moteur)
-- Le fond, cible du fade, est géré par background.lua.

local background = require('midx.background')
local animation  = require('midx.animation')

local M = {}

local ns_syntax = vim.api.nvim_create_namespace('midx')
local ns_diag   = vim.api.nvim_create_namespace('midx_diag')
local ns_dim    = vim.api.nvim_create_namespace('midx_dim')   -- fond "Comment" par défaut


-- -- variantes dim --------------------------------------------------------------
-- Flag `d` du serveur : le token garde son groupe sémantique, la couleur est
-- fondue vers le fond. Groupes dérivés « MidxDim<G> », créés paresseusement,
-- cache invalidé au ColorScheme.

local DIM_BLEND = 0.4          -- 0 = couleur pleine, 1 = fond
local dim_cache = {}

--- fond linéaire par canal entre deux couleurs 24 bits
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


-- -- palette xterm-256 ----------------------------------------------------------
-- Les schemes cterm (ou termguicolors off) rendent via ctermfg : les variantes
-- dim doivent donc exister aussi en 256 couleurs.

local ansi16 = {
	[0] = 0x000000, 0x800000, 0x008000, 0x808000,
	      0x000080, 0x800080, 0x008080, 0xc0c0c0,
	      0x808080, 0xff0000, 0x00ff00, 0xffff00,
	      0x0000ff, 0xff00ff, 0x00ffff, 0xffffff,
}

local cube = { [0] = 0, 95, 135, 175, 215, 255 }

--- indice xterm-256 → couleur 24 bits (approximation standard pour 0-15)
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

--- couleur 24 bits → indice xterm-256 le plus proche (cube 6x6x6 ou gris)
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

	-- candidat niveau de gris
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

--- groupe dérivé dimmé pour un groupe sémantique
-- @param g string - groupe source (ex: 'Operator')
-- @return string - nom du groupe dérivé
local function dim_group(g)
	local cached = dim_cache[g]
	if cached then return cached end

	local name = 'MidxDim' .. g:gsub('[^%w]', '_')

	-- résout la chaîne de liens à la main pour obtenir la vraie
	-- couleur sémantique (link=false n'est pas fiable partout)
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

		-- attributs gui (termguicolors)
		if fg then
			def.fg = dim_color(fg, bg, DIM_BLEND)
		end

		-- attributs cterm : dim dans l'espace RGB puis re-quantization 256
		if cfg then
			def.ctermfg = rgb_to_cterm(dim_color(cterm_to_rgb(cfg), bg, DIM_BLEND))
		end

		vim.api.nvim_set_hl(0, name, def)
	else
		-- aucune couleur résolvable dans aucun mode : retombe sur Comment
		vim.api.nvim_set_hl(0, name, { link = 'Comment' })
	end

	dim_cache[g] = name
	return name
end


--- Highlights de syntaxe (statique)
-- @param list table - [{ ls, cs, ce, le?, g, d? }]
function M.syntax(bufnr, list)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end

	vim.api.nvim_buf_clear_namespace(bufnr, ns_syntax, 0, -1)

	for _, h in ipairs(list or {}) do
		local group = h.g or 'Normal'
		if h.d then
			group = dim_group(group)
		end
		local ok, err = pcall(
			vim.api.nvim_buf_set_extmark,
			bufnr, ns_syntax,
			(h.ls or 0), (h.cs or 0),
			{
				end_row  = (h.le or h.ls or 0),
				end_col  = (h.ce or -1),
				hl_group = group,
				priority = 100,                 -- au-dessus du fond "Comment" (prio 1)
			})
		if not ok then
			vim.notify(
				string.format('[midx] syntax extmark failed: %s (l=%s c=%s..%s g=%s)',
					tostring(err), tostring(h.ls), tostring(h.cs), tostring(h.ce), tostring(h.g)),
				vim.log.levels.WARN)
		end
	end
end

--- Fond "Comment" sur TOUT le buffer (couche de base, sous la syntaxe).
--  Ré-appliqué à chaque édition pour couvrir le nouveau contenu.
function M.dim(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end
	vim.api.nvim_buf_clear_namespace(bufnr, ns_dim, 0, -1)
	local last = vim.api.nvim_buf_line_count(bufnr) - 1
	local line = vim.api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1] or ''
	pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_dim, 0, 0, {
		end_row  = last,
		end_col  = #line,
		hl_group = 'Comment',
		priority = 1,                       -- sous la syntaxe (prio 100)
	})
end

--- Efface la syntaxe (retour au fond "Comment") — à la déconnexion serveur.
function M.clear_syntax(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns_syntax, 0, -1)
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

-- Animation : délégué au moteur
M.animate = animation.animate
M.clear   = animation.clear
M.detach  = animation.detach
M.sync    = animation.sync

--- Initialisation (appelée depuis init.lua M.setup) : fond + moteur
function M.setup()
	background.setup()
	animation.setup()

	-- colorscheme changé : couleurs et fond ont bougé, et un éventuel
	-- `hi clear` a effacé les groupes dérivés — reconstruction IMMÉDIATE
	-- (les extmarks existants les référencent déjà, pas de message à attendre)
	vim.api.nvim_create_autocmd('ColorScheme', {
		group    = vim.api.nvim_create_augroup('MidxDimGroups', { clear = true }),
		callback = function()
			local groups = vim.tbl_keys(dim_cache)
			dim_cache = {}
			for _, g in ipairs(groups) do
				dim_group(g)
			end
		end,
	})
end

--- Arrêt propre (reload à chaud) : stoppe le timer du moteur
function M.shutdown()
	animation.shutdown()
end

return M
