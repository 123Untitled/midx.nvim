-- diff.lua
-- Translates nvim on_bytes events into universal byte-splice records
-- { offset, removed, added, text } — the wire representation of pc::diff.

local M = {}

--- Build a byte-splice record from an on_bytes event.
-- on_bytes reports the edit AFTER it was applied: start_row/start_col locate
-- the splice, byte_offset is its absolute byte position, old_end_byte_len the
-- removed span, new_end_* the inserted span RELATIVE to start. The inserted
-- text is not provided by the event — it is read back from the buffer.
-- Reading is legal inside the callback (only mutations are forbidden).
-- @param buf number - Buffer handle
-- @param start_row number - Edit start row (0-based)
-- @param start_col number - Edit start col (0-based, bytes)
-- @param byte_offset number - Absolute byte offset of the edit start
-- @param old_len number - Byte length of the removed span
-- @param new_end_row number - Inserted span end row, relative to start
-- @param new_end_col number - Inserted span end col (bytes, relative if same row)
-- @param new_len number - Byte length of the inserted span
-- @return table|nil - { offset, removed, added, text }, nil on read failure
function M.from_bytes(buf, start_row, start_col, byte_offset,
                      old_len, new_end_row, new_end_col, new_len)

	-- pure deletion: nothing was inserted, so there is no text to read.
	-- Reading it anyway would go out of bounds when the deleted span was the
	-- buffer's last line (start_row no longer exists post-deletion).
	if new_len == 0 then
		return { offset = byte_offset, removed = old_len, added = 0, text = '' }
	end

	-- relative → absolute end position: same-row inserts offset from
	-- start_col, multi-line inserts end at new_end_col of the last line
	local end_row = start_row + new_end_row
	local end_col = new_end_col
	if new_end_row == 0 then
		end_col = start_col + new_end_col
	end

	-- a span ending at (line_count, 0) reaches THROUGH the buffer's final
	-- newline ('o' on the last line, paste ending in \n at EOF): get_text
	-- cannot address that row (end_row is inclusive) — clamp to the end of
	-- the last line and restore the trailing newline by hand
	local trailing = false
	local line_count = vim.api.nvim_buf_line_count(buf)
	if end_row >= line_count then
		trailing = true
		end_row  = line_count - 1
		local last = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ''
		end_col  = #last
	end

	local ok, lines = pcall(vim.api.nvim_buf_get_text,
		buf, start_row, start_col, end_row, end_col, {})
	if not ok then
		vim.notify(
			string.format('[midx] diff: text read failed (%s)', tostring(lines)),
			vim.log.levels.ERROR
		)
		return nil
	end

	local text = table.concat(lines, '\n')
	if trailing then
		text = text .. '\n'
	end

	-- cross-check: the read-back text must span exactly new_end_byte_len,
	-- otherwise the relative → absolute conversion is wrong — drop the diff
	-- (the parallel full-buffer send keeps the server coherent)
	if #text ~= new_len then
		vim.notify(
			string.format('[midx] diff: length mismatch (read %d, expected %d)',
				#text, new_len),
			vim.log.levels.ERROR
		)
		return nil
	end

	return {
		offset  = byte_offset,
		removed = old_len,
		added   = new_len,
		text    = text,
	}
end

--- Current cursor position for a buffer, 0-based.
-- Only meaningful when the buffer is displayed in the current window;
-- falls back to 0,0 otherwise (cursor only modulates diagnostic severity).
-- @param buf number - Buffer handle
-- @return number, number - row, col (0-based)
function M.cursor(buf)
	if vim.api.nvim_get_current_buf() ~= buf then
		return 0, 0
	end
	local cur = vim.api.nvim_win_get_cursor(0)
	return cur[1] - 1, cur[2]
end

return M
