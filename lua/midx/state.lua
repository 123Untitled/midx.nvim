-- state.lua
-- Per-buffer state management
-- Part of MIDX Neovim plugin refactored architecture (Layer 1: Core)

local events = require('midx.events')
local M = {}

-- Per-buffer state storage: bufnr → { is_connected, is_playing, last_error }
local buffers = {}

local function ensure(bufnr)
	if not buffers[bufnr] then
		buffers[bufnr] = {
			is_connected = false,
			is_playing = false,
			last_error = nil,
		}
	end
	return buffers[bufnr]
end

--- Get a state value for a buffer
-- @param bufnr number - Buffer number
-- @param key string - State key
-- @return any
function M.get(bufnr, key)
	local s = buffers[bufnr]
	if not s then
		return nil
	end
	return s[key]
end

--- Set a state value for a buffer and emit change event
-- @param bufnr number - Buffer number
-- @param key string - State key
-- @param value any - New value
function M.set(bufnr, key, value)
	local s = ensure(bufnr)

	if s[key] == value then
		return
	end

	s[key] = value
	events.emit('state:changed', bufnr, key, value)
end

--- Remove all state for a buffer
-- @param bufnr number - Buffer number
function M.remove(bufnr)
	buffers[bufnr] = nil
end

--- Check if a buffer has state
-- @param bufnr number - Buffer number
-- @return boolean
function M.has(bufnr)
	return buffers[bufnr] ~= nil
end

return M
