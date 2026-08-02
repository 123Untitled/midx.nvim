-- diagnostics.lua
-- Diagnostic rendering: resolved diagnostic entries → vim.diagnostic.
-- A diagnostic targets a token (resolved upstream into its chunks); one
-- vim.diagnostic entry is produced PER CHUNK. Messages are generic per
-- an::code (the trait is ignored for now), via protocol/mirror.

local mirror = require('midx.protocol.mirror')

local M = {}

local ns_diag = vim.api.nvim_create_namespace('midx_diag')

--- Apply the current generation's diagnostics.
-- @param bufnr number
-- @param entries table - [{ ranges = [{ln,cs,ce}], code, level }]
function M.apply(bufnr, entries)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end

	local diags = {}
	for _, e in ipairs(entries) do
		local message  = mirror.CODES[e.code] or ('diagnostic ' .. tostring(e.code))
		local severity = mirror.SEVERITY[e.level] or vim.diagnostic.severity.ERROR

		for _, c in ipairs(e.ranges) do
			diags[#diags + 1] = {
				lnum     = c.ln,
				col      = c.cs,
				end_col  = math.max(c.ce, c.cs + 1),
				message  = message,
				severity = severity,
				source   = 'midx',
			}
		end
	end

	vim.diagnostic.set(ns_diag, bufnr, diags, {})
end

--- Clear diagnostics for a buffer.
function M.clear(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.diagnostic.set(ns_diag, bufnr, {}, {})
	end
end

return M
