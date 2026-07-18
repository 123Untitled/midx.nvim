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
end

--- Arrêt propre (reload à chaud) : stoppe le timer du moteur
function M.shutdown()
	animation.shutdown()
end

return M
