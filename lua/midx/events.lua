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

--- Unsubscribe from an event
-- @param event string - Event name
-- @param callback function - Callback to remove
function M.off(event, callback)
	if type(event) ~= 'string' then
		error('events.off: event must be a string')
	end

	if not listeners[event] then
		return -- Event has no listeners
	end

	-- Find and remove the callback
	for i, cb in ipairs(listeners[event]) do
		if cb == callback then
			table.remove(listeners[event], i)
			break
		end
	end

	-- Clean up empty listener arrays
	if #listeners[event] == 0 then
		listeners[event] = nil
	end
end

--- Remove all listeners for an event (or all events)
-- @param event string|nil - Event name, or nil to clear all events
function M.clear(event)
	if event then
		listeners[event] = nil
	else
		listeners = {}
	end
end

--- Get count of listeners for an event (debug utility)
-- @param event string - Event name
-- @return number - Count of registered listeners
function M.listener_count(event)
	if not listeners[event] then
		return 0
	end
	return #listeners[event]
end

return M
