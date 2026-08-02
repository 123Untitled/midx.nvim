
local event      = require('midx.event')
local session    = require('midx.session')
local buffer     = require('midx.buffer')
local syntax     = require('midx.syntax')
local animation  = require('midx.animation')
local background = require('midx.background')

local M = {}

--- Handle state changes
local function on_state_changed(bufnr, key, value)
	-- on stop (or disconnect): kill the dynamic highlights (fades)
	if key == 'is_playing' and not value then
		animation.clear(bufnr)
	end
	-- on disconnect: clear the syntax layer → back to the "Comment" base
	if key == 'is_connected' and not value then
		syntax.clear(bufnr)
	end
end

--- Setup autocommands for Neovim events
local function setup_auto_commands()
	local augroup = vim.api.nvim_create_augroup('MidxAutocmds', {clear = true})

	-- Last b:changedtick sent, per buffer (see TextChanged below)
	local last_tick = {}

	-- FileType event: attach a .midx buffer's session
	vim.api.nvim_create_autocmd('FileType', {
		group    = augroup,
		pattern  = 'midx',
		callback = function(args)
			buffer.attach(args.buf)
		end
	})

	-- BufUnload event: detach the buffer's session
	vim.api.nvim_create_autocmd('BufUnload', {
		group    = augroup,
		pattern  = '*.midx',
		callback = function(args)
			buffer.detach(args.buf)
			last_tick[args.buf] = nil
		end
	})

	-- TextChanged events: send buffer to server.
	-- <Esc> leaving insert mode re-triggers a redundant TextChanged;
	-- dedup via b:changedtick (only bumps on a real change).
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
			syntax.cover(args.buf)                -- re-cover new content as "Comment"
		end
	})
end

--- Setup user commands
local function setup_user_commands()

	-- Toggle play/pause for current buffer
	vim.api.nvim_create_user_command('MidxTogglePlay', function()
		local bufnr = vim.api.nvim_get_current_buf()
		session.send_toggle(bufnr)
		animation.clear(bufnr)
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
	event.on('state:changed', on_state_changed)
end

--- Main setup function
function M.setup()
	-- Initialize rendering: background resolution, syntax dim cache, fade engine
	background.setup()
	syntax.setup()
	animation.setup()

	setup_event_listeners()

	setup_auto_commands()
	setup_user_commands()
	setup_keybindings()
end

--- Tear down the plugin's shared resources (the animation engine's timer +
--- decoration provider). Call this BEFORE a hot reload that clears
--- package.loaded, otherwise the old fade timer leaks (see animation.lua).
--- Normal setup() re-runs are already idempotent and don't need this.
function M.shutdown()
	animation.shutdown()
end

return M
