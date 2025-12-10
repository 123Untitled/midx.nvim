-- connection.lua
-- Unix socket connection management with automatic reconnection
-- Part of MIDX Neovim plugin refactored architecture (Layer 2: Services)

local events = require('midx.events')
local state = require('midx.state')

local M = {}

-- Connection configuration
local SOCK_PATH = '/tmp/midx.sock'
local RETRY_INTERVAL = 100 -- milliseconds

-- Internal connection state
local uv = vim.loop
local client = nil          -- uv pipe handle
local retry_timer = nil     -- uv timer handle
local is_connecting = false -- Guard against concurrent connects

--- Check if currently connected to server
-- @return boolean - true if connected
function M.is_connected()
	return client ~= nil
end

--- Start retry timer for auto-reconnection
local function start_retry_timer()
	if retry_timer then
		return -- Timer already running
	end

	retry_timer = uv.new_timer()
	retry_timer:start(RETRY_INTERVAL, RETRY_INTERVAL, function()
		vim.schedule(function()
			if not client and not is_connecting then
				M.connect()
			end
		end)
	end)
end

--- Stop retry timer
local function stop_retry_timer()
	if retry_timer then
		retry_timer:stop()
		retry_timer:close()
		retry_timer = nil
	end
end

--- Handle incoming data from server
local function on_read(err, data)
	if err then
		vim.schedule(function()
			vim.notify(
				string.format('[midx] Read error: %s', err),
				vim.log.levels.ERROR
			)
		end)
		return
	end

	if data then
		-- Forward raw data to protocol layer via event
		vim.schedule(function()
			events.emit('connection:data', data)
		end)
	else
		-- Server disconnected (EOF)
		vim.schedule(function()
			vim.notify('[midx] Server disconnected', vim.log.levels.INFO)
			M.disconnect()
			start_retry_timer()
		end)
	end
end

--- Connect to MIDX server
function M.connect()
	if client then
		-- Already connected
		events.emit('connection:established')
		return
	end

	if is_connecting then
		return -- Connection in progress
	end

	is_connecting = true
	state.increment_connection_attempts()

	local tmp = uv.new_pipe(false)

	tmp:connect(SOCK_PATH, function(err)
		vim.schedule(function()
			is_connecting = false

			if err then
				tmp:close()
				start_retry_timer()
				events.emit('connection:error', err)
				return
			end

			-- Connection successful
			client = tmp
			stop_retry_timer()
			state.reset_connection_attempts()
			state.set('is_connected', true)

			vim.notify('[midx] Connected to server', vim.log.levels.INFO)
			events.emit('connection:established')

			-- Start reading from server
			client:read_start(on_read)
		end)
	end)
end

--- Disconnect from server
function M.disconnect()
	if client then
		client:close()
		client = nil
	end

	stop_retry_timer()
	state.set('is_connected', false)
	state.set('is_playing', false) -- Server stopped, so not playing

	events.emit('connection:lost')
end

--- Send raw data to server
-- @param data string - Raw bytes to send
function M.send(data)
	if not client then
		-- Not connected, try to connect
		M.connect()
		return false
	end

	client:write(data, function(err)
		if err then
			vim.schedule(function()
				vim.notify(
					string.format('[midx] Send failed: %s', err),
					vim.log.levels.ERROR
				)
				state.set('last_error', err)
			end)
		end
	end)

	return true
end

return M
