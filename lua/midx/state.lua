-- state.lua
-- Single source of truth for all plugin state
-- Part of MIDX Neovim plugin refactored architecture (Layer 1: Core)

local events = require('midx.events')
local M = {}

-- Internal state storage
-- This is the ONLY place where plugin state should live
local state = {
	-- Buffer state
	active_buffer = nil,        -- number|nil - Currently active .midx buffer

	-- Connection state
	is_connected = false,       -- boolean - Socket connection status
	connection_attempts = 0,    -- number - Count of connection attempts

	-- Playback state
	is_playing = false,         -- boolean - Server playback status

	-- Error state
	last_error = nil,           -- string|nil - Last error message
}

-- Valid state keys (for validation)
local valid_keys = {
	active_buffer = true,
	is_connected = true,
	connection_attempts = true,
	is_playing = true,
	last_error = true,
}

--- Get a state value
-- @param key string - State key
-- @return any - State value, or nil if not found
function M.get(key)
	if not valid_keys[key] then
		vim.notify(
			string.format('[midx] state.get: unknown key "%s"', key),
			vim.log.levels.WARN
		)
		return nil
	end
	return state[key]
end

--- Set a state value and emit change event
-- @param key string - State key
-- @param value any - New value
function M.set(key, value)
	if not valid_keys[key] then
		vim.notify(
			string.format('[midx] state.set: unknown key "%s"', key),
			vim.log.levels.WARN
		)
		return
	end

	-- Skip if value hasn't changed (avoid unnecessary events)
	if state[key] == value then
		return
	end

	local old_value = state[key]
	state[key] = value

	-- Emit state change event
	events.emit('state:changed', key, value, old_value)
end

--- Get all state (for debugging)
-- @return table - Deep copy of entire state
function M.get_all()
	return vim.deepcopy(state)
end

--- Reset state to defaults
function M.reset()
	state.active_buffer = nil
	state.is_connected = false
	state.connection_attempts = 0
	state.is_playing = false
	state.last_error = nil

	-- Emit reset event
	events.emit('state:reset')
end

--- Increment connection attempts counter
-- @return number - New attempt count
function M.increment_connection_attempts()
	state.connection_attempts = state.connection_attempts + 1
	events.emit('state:changed', 'connection_attempts', state.connection_attempts, state.connection_attempts - 1)
	return state.connection_attempts
end

--- Reset connection attempts counter
function M.reset_connection_attempts()
	if state.connection_attempts > 0 then
		state.connection_attempts = 0
		events.emit('state:changed', 'connection_attempts', 0, state.connection_attempts)
	end
end

return M
