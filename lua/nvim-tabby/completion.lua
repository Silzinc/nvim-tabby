---Some utilities for enabling/disabling completion support in cmp/blink.

local M = {}

local enabled = false

---@return boolean
function M.is_enabled()
	return enabled
end

---@param enable boolean? Default: true
---@param silent boolean? Default: false
function M.enable(enable, silent)
	if enable == false then
		return M.disable()
	end
	local m = require("nvim-tabby")
	local client = m.get_client()
	if client ~= nil then
		client.server_capabilities.completionProvider = m.internal.ls_completionProvider
	elseif not silent then
		vim.notify(
			"Could not enable completion support:\nTabby server client was not found.",
			vim.log.levels.WARN,
			{ title = "nvim-tabby" }
		)
	end
	enabled = true
end

---@param silent boolean? Default: false
function M.disable(silent)
	local m = require("nvim-tabby")
	local client = m.get_client()
	if client ~= nil then
		client.server_capabilities.completionProvider = nil
	elseif not silent then
		vim.notify(
			"Could not disable completion support:\nTabby server client was not found.",
			vim.log.levels.WARN,
			{ title = "nvim-tabby" }
		)
	end
	enabled = false
end

function M.toggle()
	return M.enable(not M.is_enabled())
end

return M
