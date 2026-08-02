-- events.lua
-- Simple event emitter for inter-module communication
-- Part of MIDX Neovim plugin refactored architecture (Layer 1: Core)

local M = {}

-- Event listeners storage
-- Structure: { event_name = { callback1, callback2, ... } }
local listeners = {}

--- Subscribe to an event
-- @param event string - Event name (e.g., 'state:changed', 'connection:established')
-- @param callback function - Callback to execute when event is emitted
function M.on(event, callback)
	if type(event) ~= 'string' then
		error('events.on: event must be a string')
	end
	if type(callback) ~= 'function' then
		error('events.on: callback must be a function')
	end

	listeners[event] = listeners[event] or {}
	table.insert(listeners[event], callback)
end

--- Emit an event to all subscribers
-- @param event string - Event name
-- @param ... - Arguments to pass to callbacks
function M.emit(event, ...)
	if type(event) ~= 'string' then
		error('events.emit: event must be a string')
	end

	if not listeners[event] then
		return -- No listeners for this event
	end

	-- Call all listeners synchronously
	for _, callback in ipairs(listeners[event]) do
		-- Protect against callback errors
		local success, err = pcall(callback, ...)
		if not success then
			vim.schedule(function()
				vim.notify(
					string.format('[midx] Event callback error (%s): %s', event, err),
					vim.log.levels.ERROR
				)
			end)
		end
	end
end

return M
