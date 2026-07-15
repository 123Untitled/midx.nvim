
local events     = require('midx.events')
local session    = require('midx.session')
local statusline = require('midx.statusline')
local highlights = require('midx.highlights')

local M = {}

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
			session.set_state(bufnr, 'is_playing', msg.playing)
		end
		return
	end

	-- All other messages require a valid buffer
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	if msg.type == "highlight" and msg.highlights then
		highlights.syntax(bufnr, msg.highlights)
	elseif msg.type == "animation" then
		highlights.animate(bufnr, msg)
	elseif msg.type == "diagnostic" and msg.diagnostics then
		highlights.diagnostics(bufnr, msg.diagnostics)
	else
		vim.notify(
			string.format('[midx] Unhandled message type: %s', tostring(msg.type)),
			vim.log.levels.WARN
		)
	end
end

--- Handle state changes
local function on_state_changed(bufnr, key, value)
	statusline.refresh()
end

--- Setup autocommands for Neovim events
local function setup_auto_commands()
	local augroup = vim.api.nvim_create_augroup('MidxAutocmds', {clear = true})

	-- Dernière b:changedtick envoyée, par buffer (voir TextChanged plus bas)
	local last_tick = {}

	-- FileType event: attach when opening .midx file
	vim.api.nvim_create_autocmd('FileType', {
		group    = augroup,
		pattern  = 'midx',
		callback = function(args)
			local bufnr = args.buf
			session.attach(bufnr, apply_message)
			statusline.enable(bufnr)
			vim.bo[bufnr].commentstring = '\\\\ %s'
		end
	})

	-- BufUnload event: detach buffer
	vim.api.nvim_create_autocmd('BufUnload', {
		group    = augroup,
		pattern  = '*.midx',
		callback = function(args)
			session.detach(args.buf)
			highlights.detach(args.buf)
			last_tick[args.buf] = nil
		end
	})

	-- TextChanged events: send buffer to server
	-- <Esc> quittant le mode insertion redéclenche un TextChanged redondant ;
	-- on déduplique via b:changedtick (n'incrémente que sur un vrai changement).
	vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
		group    = augroup,
		pattern  = '*.midx',
		callback = function(args)
			local tick = vim.b[args.buf].changedtick
			if last_tick[args.buf] == tick then
				return
			end
			last_tick[args.buf] = tick
			session.send_buffer(args.buf)
		end
	})
end

--- Setup user commands
local function setup_user_commands()

	-- Toggle play/pause for current buffer
	vim.api.nvim_create_user_command('MidxTogglePlay', function()
		local bufnr = vim.api.nvim_get_current_buf()
		session.send_toggle(bufnr)
		highlights.clear(bufnr)
	end, {
		desc = 'Toggle midx play/pause',
	})

	-- Display status
	vim.api.nvim_create_user_command('MidxStatus', function()
		local bufnr = vim.api.nvim_get_current_buf()
		local connected = session.get_state(bufnr, 'is_connected')
		local playing = session.get_state(bufnr, 'is_playing')
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
