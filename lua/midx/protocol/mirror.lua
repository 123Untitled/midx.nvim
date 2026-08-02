-- mirror.lua
-- Server-enum mirrors — these tables MUST MATCH the server, index for index.
-- They translate the numeric ids carried on the wire (sx::id, an::code,
-- an::level) into client-side rendering vocabulary. The decoder emits raw
-- ids; this is where they gain meaning.

local M = {}

-- sx::id → nvim highlight group.
-- MUST MATCH the enum AND the groups table in
-- ../midx.server/code/core/language/syntax/sense.h (0-based order).
M.GROUPS = {
	[0]  = 'Comment',                 -- none
	[1]  = 'Comment',                 -- comment
	[2]  = 'Define',                  -- define
	[3]  = 'Identifier',              -- symbol
	[4]  = 'Keyword',                 -- keyword
	[5]  = 'Type',                    -- type
	[6]  = 'Function',                -- function
	[7]  = 'Operator',                -- op
	[8]  = '@punctuation.bracket',    -- delimiter
	[9]  = 'Number',                  -- number
	[10] = 'String',                  -- string
}

-- an::code → generic diagnostic message (placeholders — refine as needed).
-- The trait id (pc::diagnostic.extra) is intentionally ignored for now.
-- MUST MATCH the enum in ../midx.server/code/core/language/diagnostic.h.
M.CODES = {
	[0] = nil,                            -- ok (never emitted)
	[1] = 'unclosed bracket',             -- unclosed_open
	[2] = 'undefined alias',              -- undefined_alias
	[3] = 'alias already defined',        -- alias_redefinition
	[4] = 'value out of range',           -- overflow
	[5] = 'integer value expected',       -- not_integral
	[6] = 'non-negative value expected',  -- not_positive
}

-- an::level → vim.diagnostic.severity.
-- MUST MATCH the enum in diagnostic.h (0 info · 1 warning · 2 error).
M.SEVERITY = {
	[0] = vim.diagnostic.severity.INFO,
	[1] = vim.diagnostic.severity.WARN,
	[2] = vim.diagnostic.severity.ERROR,
}

return M
