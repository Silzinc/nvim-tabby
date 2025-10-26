local M = {}

---@alias NvimTabby.AutoTriggerType "on_edit"|"on_insert_enter"|"on_cursor_move"

local auto_trigger_config = {
	on_edit = { events = { "TextChangedP", "TextChangedI" } },
	on_insert_enter = { events = "ModeChanged", pattern = "*:i" },
	on_cursor_move = { events = "CursorMovedI" },
}

---Template for auto-trigger callbacks
---@param trigger_type NvimTabby.AutoTriggerType
local function get_callback(trigger_type)
	return function()
		local m = require("nvim-tabby")
		if
			type(m.opts.auto_trigger.condition) == "function"
			and m.opts.auto_trigger.condition(trigger_type) == false
		then
			return
		end
		if m.internal.in_partial_accept then
			m.internal.in_partial_accept = false
			return
		end
		return m.trigger(false)
	end
end

---@param trigger_type NvimTabby.AutoTriggerType? Default: on_edit
function M.enable(trigger_type)
	trigger_type = trigger_type or "on_edit"
	local conf = auto_trigger_config[trigger_type]
	if conf.id ~= nil then
		return
	end
	if conf.callback == nil then
		conf.callback = get_callback(trigger_type)
	end
	conf.id = vim.api.nvim_create_autocmd(conf.events, {
		group = require("nvim-tabby").internal.augroup,
		pattern = conf.pattern,
		callback = conf.callback,
	})
	require("nvim-tabby").cancel_request()
end

---@param trigger_type NvimTabby.AutoTriggerType? Default: on_edit
function M.disable(trigger_type)
	trigger_type = trigger_type or "on_edit"
	local conf = auto_trigger_config[trigger_type]
	if conf.id == nil then
		return
	end
	vim.api.nvim_del_autocmd(conf.id)
	conf.id = nil
	require("nvim-tabby").cancel_request()
end

---@param trigger_type NvimTabby.AutoTriggerType? Default: on_edit
---@return boolean
function M.is_enabled(trigger_type)
	trigger_type = trigger_type or "on_edit"
	return auto_trigger_config[trigger_type].id ~= nil
end

---@param trigger_type NvimTabby.AutoTriggerType? Default: on_edit
function M.toggle(trigger_type)
	trigger_type = trigger_type or "on_edit"
	if not M.is_enabled(trigger_type) then
		M.enable(trigger_type)
	else
		M.disable(trigger_type)
	end
end

return M
