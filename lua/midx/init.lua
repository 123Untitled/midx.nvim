-- init.lua
-- Main orchestrator for MIDX Neovim plugin
-- Part of MIDX Neovim plugin refactored architecture (Layer 4: Integration)

local events = require('midx.events')
local state = require('midx.state')
local connection = require('midx.connection')
local protocol = require('midx.protocol')
local buffer = require('midx.buffer')
local statusline = require('midx.statusline')
local indent = require('midx.indent')

local M = {}

-- Namespaces for highlights
local ns_highlight = vim.api.nvim_create_namespace('midx')
local ns_animation = vim.api.nvim_create_namespace('midx_animation')


local animation_marks = {}

--- Handle incoming messages from server
-- @param msg table - Parsed JSON message
local function on_message(msg)
	if not msg or type(msg) ~= 'table' then
		return
	end

	-- Get the active .midx buffer (not the current buffer!)
	local bufnr = state.get('active_buffer')

	-- State update message (doesn't need a buffer)
	if msg.type == "state" then
		if msg.playing ~= nil then
			state.set('is_playing', msg.playing)
		end
		return
	end

	-- All other messages require a valid buffer
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- Syntax highlight message
	if msg.type == "highlight" and msg.highlights then
		vim.api.nvim_buf_clear_namespace(bufnr, ns_highlight, 0, -1)
		for _, h in ipairs(msg.highlights) do
			vim.api.nvim_buf_add_highlight(
				bufnr,
				ns_highlight,
				h.g or 'Normal',
				(h.l or 0),
				(h.s or 0),
				(h.e or -1)
			)
		end
		return
	end

	-- Animation highlight message (OLD IMPL)
	--if msg.type == "animation" and msg.highlights then
	--	vim.api.nvim_buf_clear_namespace(bufnr, ns_animation, 0, -1)
	--	for _, h in ipairs(msg.highlights) do
	--		vim.api.nvim_buf_add_highlight(
	--			bufnr,
	--			ns_animation,
	--			h.g or 'Normal',
	--			(h.l or 0),
	--			(h.s or 0),
	--			(h.e or -1)
	--		)
	--	end
	--	return
	--end


	-- Animation highlight message (NEW IMPL with extmarks)
	if msg.type == "animation" then


		if msg.clear then
			vim.api.nvim_buf_clear_namespace(bufnr, ns_animation, 0, -1)
			animation_marks = {}
		end


		-- remove expired highlights
		if msg.off then
			for _, id in ipairs(msg.off) do
				local mark = animation_marks[id]
				if mark then
					vim.api.nvim_buf_del_extmark(bufnr, ns_animation, mark)
					animation_marks[id] = nil
				end
			end
		end

		-- add new highlights
		if msg.on then
			for _, h in ipairs(msg.on) do
				-- supprime l'ancien extmark si il existe déjà
				local old = animation_marks[h.id]
				if old then
					vim.api.nvim_buf_del_extmark(bufnr, ns_animation,
					old)
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
				animation_marks[h.id] = mark
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
				end_col  = (d.e or d.cs or 0),
				message  = d.m or 'unknown error',
				severity = vim.diagnostic.severity.ERROR,
				source   = 'midx'
			})
		end
		vim.diagnostic.set(ns_highlight, bufnr, diags, {})
		return
	end

	-- Unknown message type
	vim.notify(
		string.format('[midx] Unhandled message type: %s', tostring(msg.type)),
		vim.log.levels.WARN
	)
end

--- Handle state changes
-- @param key string - State key that changed
-- @param value any - New value
local function on_state_changed(key, value)
	-- Refresh statusline when any state changes
	statusline.refresh()
end

--- Handle buffer attachment
-- @param bufnr number - Buffer that was attached
local function on_buffer_attached(bufnr)
	-- Enable custom statusline
	statusline.enable(bufnr)

	-- Setup indentation
	indent.setup()

	-- Connect to server if not already connected
	if not connection.is_connected() then
		connection.connect()
	else
		-- Already connected, send buffer content immediately
		local content = buffer.get_content()
		if content then
			local msg = protocol.encode_update(content)
			connection.send(msg)
		end
	end
end

--- Handle successful connection
local function on_connection_established()
	-- Send current buffer content when connected
	local content = buffer.get_content()
	if content then
		local msg = protocol.encode_update(content)
		connection.send(msg)
	end
end

--- Clear animation highlights
local function clear_animation_highlights()
	local bufnr = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_clear_namespace(bufnr, ns_animation, 0, -1)
	animation_marks = {}
end

--- Setup autocommands for Neovim events
local function setup_autocommands()
	local augroup = vim.api.nvim_create_augroup('MidxAutocmds', {clear = true})

	-- FileType event: attach when opening .midx file
	vim.api.nvim_create_autocmd('FileType', {
		group    = augroup,
		pattern  = 'midx',
		callback = function(args)
			buffer.attach(args.buf)
			vim.bo[args.buf].commentstring = '~ %s'
		end
	})

	-- BufUnload event: detach when closing buffer
	vim.api.nvim_create_autocmd('BufUnload', {
		group    = augroup,
		pattern  = '*.midx',
		callback = function(args)
			if args.buf == state.get('active_buffer') then
				buffer.detach()
			end
		end
	})

	-- TextChanged events: send updates to server
	vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
		group    = augroup,
		pattern  = '*.midx',
		callback = function(args)
			-- Only send if this is the active buffer
			if args.buf ~= state.get('active_buffer') then
				return
			end

			local content = buffer.get_content()
			if content then
				local msg = protocol.encode_update(content)
				connection.send(msg)
			end

			--clear_animation_highlights()
		end
	})
end

--- Setup user commands
local function setup_commands()
	-- Toggle play/pause
	vim.api.nvim_create_user_command('MidxTogglePlay', function()
		connection.send(protocol.encode_toggle())
		clear_animation_highlights()
	end, {
		desc = 'Toggle midx play/pause',
	})

	-- Switch active buffer
	vim.api.nvim_create_user_command('MidxSwitch', function()
		local bufnr = vim.api.nvim_get_current_buf()
		buffer.switch(bufnr)
	end, {
		desc = 'Switch active midx buffer',
	})

	-- Display status
	vim.api.nvim_create_user_command('MidxStatus', function()
		buffer.status()
	end, {
		desc = 'Display midx status',
	})
end

--- Setup keybindings
local function setup_keybindings()
	-- Spacebar to toggle play/pause
	vim.api.nvim_set_keymap('n', '<space>', ':MidxTogglePlay<CR>',
		{noremap = true, silent = true, desc = 'Toggle midx play/pause'})
end

--- Setup event listeners
local function setup_event_listeners()
	-- Listen to message events
	events.on('message:received', on_message)

	-- Listen to state changes
	events.on('state:changed', on_state_changed)

	-- Listen to buffer events
	events.on('buffer:attached', on_buffer_attached)

	-- Listen to connection events
	events.on('connection:established', on_connection_established)
end

--- Main setup function
function M.setup()
	-- NOTE: Filetype registration moved to plugin/midx.lua
	-- This ensures filetype is detected before lazy-loading
	-- vim.filetype.add({
	-- 	extension = {midx = 'midx'}
	-- })

	-- Initialize protocol layer
	protocol.setup()

	-- Initialize statusline
	statusline.setup()

	-- Setup event listeners
	setup_event_listeners()

	-- Setup Neovim integration
	setup_autocommands()
	setup_commands()
	setup_keybindings()
end

return M
