-- connection.lua
-- Unix socket connection factory — one instance per buffer
-- Part of MIDX Neovim plugin refactored architecture (Layer 2: Services)

local M = {}

-- Connection configuration
local SOCK_PATH = '/tmp/midx.sock'
local RETRY_INTERVAL = 100 -- milliseconds

local uv = vim.loop

--- Create a new connection instance
-- @return table - Connection instance with connect/disconnect/send methods
function M.new()
	local self = {
		client = nil,
		retry_timer = nil,
		is_connecting = false,

		-- Callbacks (set by owner)
		on_data = nil,          -- function(data)
		on_connected = nil,     -- function()
		on_disconnected = nil,  -- function()
	}

	local function start_retry_timer()
		if self.retry_timer then
			return
		end

		self.retry_timer = uv.new_timer()
		self.retry_timer:start(RETRY_INTERVAL, RETRY_INTERVAL, function()
			vim.schedule(function()
				if not self.client and not self.is_connecting then
					self:connect()
				end
			end)
		end)
	end

	local function stop_retry_timer()
		if self.retry_timer then
			self.retry_timer:stop()
			self.retry_timer:close()
			self.retry_timer = nil
		end
	end

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
			vim.schedule(function()
				if self.on_data then
					self.on_data(data)
				end
			end)
		else
			-- Server disconnected (EOF)
			vim.schedule(function()
				self:disconnect()
				start_retry_timer()
			end)
		end
	end

	function self:connect()
		if self.client then
			if self.on_connected then
				self.on_connected()
			end
			return
		end

		if self.is_connecting then
			return
		end

		self.is_connecting = true

		local tmp = uv.new_pipe(false)

		tmp:connect(SOCK_PATH, function(err)
			vim.schedule(function()
				self.is_connecting = false

				if err then
					tmp:close()
					start_retry_timer()
					return
				end

				-- Connection successful
				self.client = tmp
				stop_retry_timer()

				if self.on_connected then
					self.on_connected()
				end

				-- Start reading from server
				self.client:read_start(on_read)
			end)
		end)
	end

	function self:disconnect()
		if self.client then
			self.client:close()
			self.client = nil
		end

		stop_retry_timer()

		if self.on_disconnected then
			self.on_disconnected()
		end
	end

	function self:send(data)
		if not self.client then
			return false
		end

		self.client:write(data, function(err)
			if err then
				vim.schedule(function()
					vim.notify(
						string.format('[midx] Send failed: %s', err),
						vim.log.levels.ERROR
					)
				end)
			end
		end)

		return true
	end

	function self:is_connected()
		return self.client ~= nil
	end

	return self
end

return M
