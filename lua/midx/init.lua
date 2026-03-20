
local events     = require('midx.events')
local state      = require('midx.state')
local buffer     = require('midx.buffer')
local protocol   = require('midx.protocol')
local statusline = require('midx.statusline')

local M = {}

-- Namespaces for highlights
local ns_highlight = vim.api.nvim_create_namespace('midx')
local ns_animation = vim.api.nvim_create_namespace('midx_animation')

-- Animation marks per buffer: bufnr → { id → extmark_id }
local animation_marks = {}

--- Handle incoming messages from server for a specific buffer
-- @param bufnr number - Buffer this message belongs to
-- @param msg table - Parsed JSON message
local function apply_message(bufnr, msg)
	if not msg or type(msg) ~= 'table' then
		return
	end

	-- State update message
	if msg.type == "state" then
		if msg.playing ~= nil then
			state.set(bufnr, 'is_playing', msg.playing)
		end
		return
	end

	-- All other messages require a valid buffer
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- Syntax highlight message
	if msg.type == "highlight" and msg.highlights then
		vim.api.nvim_buf_clear_namespace(bufnr, ns_highlight, 0, -1)
		for _, h in ipairs(msg.highlights) do
			vim.api.nvim_buf_set_extmark(
				bufnr,
				ns_highlight,
				(h.ls or 0),
				(h.cs or 0),
				{
					end_row = (h.le or h.ls or 0),
					end_col = (h.ce or -1),
					hl_group = h.g or 'Normal',
				}
			)
		end
		return
	end

	-- Animation highlight message
	if msg.type == "animation" then
		if not animation_marks[bufnr] then
			animation_marks[bufnr] = {}
		end
		local marks = animation_marks[bufnr]

		if msg.clear then
			vim.api.nvim_buf_clear_namespace(bufnr, ns_animation, 0, -1)
			animation_marks[bufnr] = {}
			marks = animation_marks[bufnr]
		end

		if msg.off then
			for _, id in ipairs(msg.off) do
				local mark = marks[id]
				if mark then
					vim.api.nvim_buf_del_extmark(bufnr, ns_animation, mark)
					marks[id] = nil
				end
			end
		end

		if msg.on then
			for _, h in ipairs(msg.on) do
				local old = marks[h.id]
				if old then
					vim.api.nvim_buf_del_extmark(bufnr, ns_animation, old)
				end

				local mark = vim.api.nvim_buf_set_extmark(
					bufnr,
					ns_animation,
					(h.l or 0),
					(h.s or 0),
					{
						end_col = (h.e or -1),
						hl_group = h.g or 'Normal',
					}
				)
				marks[h.id] = mark
			end
		end

		return
	end

	-- Diagnostic message
	if msg.type == "diagnostic" and msg.diagnostics then
		local diags = {}
		for _, d in ipairs(msg.diagnostics) do
			table.insert(diags, {
				lnum     = (d.l or 0),
				col      = (d.s or 0),
				end_col  = math.max((d.e or 0), (d.s or 0) + 1),
				message  = d.m or 'unknown error',
				severity = vim.diagnostic.severity.ERROR,
				source   = 'midx'
			})
		end
		vim.diagnostic.set(ns_highlight, bufnr, diags, {})
		return
	end

	vim.notify(
		string.format('[midx] Unhandled message type: %s', tostring(msg.type)),
		vim.log.levels.WARN
	)
end

--- Handle state changes
local function on_state_changed(bufnr, key, value)
	statusline.refresh()
end

--- Clear animation highlights for a buffer
local function clear_animation_highlights(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns_animation, 0, -1)
	end
	animation_marks[bufnr] = {}
end

--- Setup autocommands for Neovim events
local function setup_auto_commands()
	local augroup = vim.api.nvim_create_augroup('MidxAutocmds', {clear = true})

	-- FileType event: attach when opening .midx file
	vim.api.nvim_create_autocmd('FileType', {
		group    = augroup,
		pattern  = 'midx',
		callback = function(args)
			local bufnr = args.buf
			buffer.attach(bufnr, apply_message)
			statusline.enable(bufnr)
			vim.bo[bufnr].commentstring = '~~ %s'
		end
	})

	-- BufUnload event: detach buffer
	vim.api.nvim_create_autocmd('BufUnload', {
		group    = augroup,
		pattern  = '*.midx',
		callback = function(args)
			buffer.detach(args.buf)
			animation_marks[args.buf] = nil
		end
	})

	-- TextChanged events: send updates to server
	vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
		group    = augroup,
		pattern  = '*.midx',
		callback = function(args)
			buffer.send_update(args.buf)
		end
	})
end

--- Setup user commands
local function setup_user_commands()

	-- Toggle play/pause for current buffer
	vim.api.nvim_create_user_command('MidxTogglePlay', function()
		local bufnr = vim.api.nvim_get_current_buf()
		buffer.send_toggle(bufnr)
		clear_animation_highlights(bufnr)
	end, {
		desc = 'Toggle midx play/pause',
	})

	-- Display status
	vim.api.nvim_create_user_command('MidxStatus', function()
		local bufnr = vim.api.nvim_get_current_buf()
		local connected = state.get(bufnr, 'is_connected')
		local playing = state.get(bufnr, 'is_playing')
		vim.notify(
			string.format('[midx] Buffer #%d — connected: %s, playing: %s',
				bufnr,
				tostring(connected or false),
				tostring(playing or false)),
			vim.log.levels.INFO
		)
	end, {
		desc = 'Display midx status',
	})
end

--- Setup keybindings
local function setup_keybindings()
	vim.api.nvim_set_keymap('n', '<space>', ':MidxTogglePlay<CR>',
		{noremap = true, silent = true, desc = 'Toggle midx play/pause'})
end

--- Setup event listeners
local function setup_event_listeners()
	events.on('state:changed', on_state_changed)
end

--- Main setup function
function M.setup()
	-- Initialize statusline
	statusline.setup()

	-- Setup event listeners
	setup_event_listeners()

	-- Setup Neovim integration
	setup_auto_commands()
	setup_user_commands()
	setup_keybindings()
end

return M
