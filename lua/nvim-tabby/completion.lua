---Some utilities for enabling/disabling completion support in cmp/blink.

local M = {}

local enabled = false

---@return boolean
function M.is_enabled()
	return enabled
end

---@param enable boolean? Default: true
---@param silent boolean? Default: false
---@param client vim.lsp.Client? Default: taken from `get_client`
function M.enable(enable, silent, client)
	if enable == false then
		return M.disable(silent, client)
	end
	local m = require("nvim-tabby")
	client = client or m.get_client()
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
---@param client vim.lsp.Client? Default: taken from `get_client`
function M.disable(silent, client)
	local m = require("nvim-tabby")
	client = client or m.get_client()
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

---@param silent boolean? Default: false
---@param client vim.lsp.Client? Default: taken from `get_client`
function M.toggle(silent, client)
	return M.enable(not M.is_enabled(), silent, client)
end

return M
