local M = {}

M.telemetry = {}

M.opts = {
	auto_trigger = {
		on_edit = true,
		on_insert_enter = false,
		on_cursor_move = false,
	},
	agent_start_command = { "npx", "tabby-agent", "--stdio" },
}

local tabby_ls_name = "nvim-tabby"
local warned_ls_shutdown

local ns_id = vim.api.nvim_create_namespace("nvim-tabby")

---Try not to touch that from outside the plugin plz
---@private
M.internal = {}

M.internal.augroup = vim.api.nvim_create_augroup("nvim-tabby", {})
M.internal.in_partial_accept = false

---@param str string
local function iter_lines(str)
	local i = 0
	return function()
		if i > #str or #str == 0 then
			return nil
		end
		local j = str:find("\n", i + 1) or #str + 1
		local line = str:sub(i + 1, j - 1)
		i = j
		return line, j
	end
end

function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
	if not vim.lsp.config[tabby_ls_name] then
		---@type vim.lsp.Config
		local tabby_conf = {
			cmd = M.opts.agent_start_command,
			filetypes = nil, -- attach on all filetypes
			capabilities = {
				textDocument = {
					inlineCompletion = {},
					-- disables completion in blink/nvim-cmp by default
					completion = { dynamicRegistration = false },
				},
			},
			root_dir = function(bufnr, on_dir)
				on_dir(vim.fs.root(bufnr, { ".git" }) or vim.uv.cwd())
			end,
			on_attach = function(client, bufnr)
				warned_ls_shutdown = false
				-- disables completion in blink/nvim-cmp by default
				client.server_capabilities.completionProvider = nil
			end,
		}
		vim.lsp.config(tabby_ls_name, tabby_conf)
	end
	vim.lsp.enable(tabby_ls_name)

	local new_autocmd = vim.api.nvim_create_autocmd

	-- TODO: add toggle functions for these autocmds,
	-- keep track of their id to disable and re-enable them when needed
	for _, k in ipairs({ "on_edit", "on_insert_enter", "on_cursor_move" }) do
		if M.opts.auto_trigger[k] ~= false then
			require("nvim-tabby.auto-trigger").enable(k)
		end
	end

	new_autocmd("ModeChanged", {
		group = M.internal.augroup,
		pattern = "i:*",
		callback = M.cancel_request,
	})
	new_autocmd("BufLeave", {
		group = M.internal.augroup,
		callback = M.cancel_request,
	})

	local new_cmd = vim.api.nvim_create_user_command
	new_cmd("NvimTabbyAccept", M.accept, {})
	new_cmd("NvimTabbyAcceptWord", M.accept_word, {})
	new_cmd("NvimTabbyAcceptLine", M.accept_line, {})
	new_cmd("NvimTabbyTrigger", function()
		M.trigger(true)
	end, {})
end

---@return vim.lsp.Client?
function M.get_client()
	return vim.lsp.get_clients({
		name = tabby_ls_name,
	})[1]
end

---@param params table?
function M.telemetry.notify_event(params)
	local client = M.get_client()
	if client ~= nil then
		client:notify("tabby/telemetry/event", params)
	end
end

---@class NvimTabby.RequestParams
---@field buf integer
---@field offset integer
---@field pos { row: integer, col: integer }
---@field modification 0|1
---@field trigger_kind 1|2

---@param is_manually boolean
---@return NvimTabby.RequestParams
local function create_params(is_manually)
	local bufnr = vim.api.nvim_get_current_buf()
	local pos = vim.api.nvim_win_get_cursor(0)
	return {
		buf = bufnr,
		pos = { row = pos[1], col = pos[2] },
		offset = vim.fn.line2byte(pos[1]) + pos[2],
		modification = vim.fn.getbufvar("%", "&modified"),
		trigger_kind = is_manually and 1 or 2,
	}
end

---@class NvimTabby.RequestResultItem
---@field insertText string?
---@field data { eventId: { completionId: string?, choiceIndex: any }? }?
---@field range { start: { character: number, line: number }, end: { character: number, line: number } }

---@class NvimTabby.RequestResult
---@field isIncomplete boolean
---@field items NvimTabby.RequestResultItem[]

---Main request object
---@class NvimTabby.Request
---@field id integer?
---@field params NvimTabby.RequestParams?
---@field result NvimTabby.RequestResult?
---@field displayExtmarkId integer?
---@field displayTime number?
---@field displayEventId string?
local request = {
	id = nil,
	params = nil,
	result = nil,
	displayExtmarkId = nil,
	displayTime = nil,
	displayEventId = nil,
}

function M.is_active()
	return request.id ~= nil
end

function M.clear_request()
	request = {}
end

function M.cancel_request()
	if request.id ~= nil then
		if request.displayExtmarkId ~= nil then
			vim.api.nvim_buf_del_extmark(request.params.buf, ns_id, request.displayExtmarkId)
			request.displayExtmarkId = nil
		end
		local client = M.get_client()
		if client ~= nil then
			client:cancel_request(request.id)
			M.clear_request()
		end
	end
	M.internal.in_partial_accept = false
end

-- function M.dismiss()
-- 	if request.result == nil then
-- 		return
-- 	end
-- 	-- FIXME(@icycodes): Only support single choice completion for now
-- 	local item = request.result.items[1]
-- 	if item.data and item.data.eventId and item.data.eventId.completionId then
-- 		M.telemetry.notify_event({
-- 			type = "dismiss",
-- 			eventId = {
-- 				completionId = item.data.eventId.completionId,
-- 				choiceIndex = item.data.eventId.choiceIndex,
-- 			},
-- 			viewId = request.displayEventId,
-- 			elapsed = math.floor(os.clock() * 1000 - request.displayTime),
-- 		})
-- 	end
-- end

local function display()
	if request.id == nil then
		return
	end
	-- refresh previous virtual text
	if request.displayExtmarkId ~= nil then
		vim.api.nvim_buf_del_extmark(request.params.buf, ns_id, request.displayExtmarkId)
		request.displayExtmarkId = nil
	end

	-- FIXME(@icycodes): Only support single choice completion for now
	local item, pos, ls = request.result.items[1], request.params.pos, {}
	local text = item.insertText
	if text == nil or #text == 0 then
		return M.cancel_request()
	end

	local _, first_line_end = text:find("^[^\n]*")
	local first_line = text:sub(1, first_line_end)
	text = text:sub(first_line_end + 2)
	for l in iter_lines(text) do
		ls[#ls + 1] = { { l, "Comment" } }
	end

	request.displayExtmarkId = vim.api.nvim_buf_set_extmark(request.params.buf, ns_id, pos.row - 1, pos.col, {
		hl_group = "Comment",
		virt_text = { { first_line, "Comment" } },
		virt_lines = #ls > 0 and ls or nil,
		virt_text_pos = "inline",
	})

	request.displayTime = os.clock() * 1000

	local cmpl_id = assert(item.data.eventId.completionId)
	local choice_index = item.data.eventId.choiceIndex
	local raw_cmpl_id = cmpl_id:gsub("cmpl%-", "")
	request.displayEventId = ("view-%s-%d"):format(raw_cmpl_id, request.displayTime)

	M.telemetry.notify_event({
		type = "view",
		eventId = {
			completionId = cmpl_id,
			choiceIndex = choice_index,
		},
		viewId = request.displayEventId,
	})
end

---@param pattern string
local function accept_match(pattern)
	if request.result == nil then
		return
	end

	-- FIXME(@icycodes): Only support single choice completion for now
	local item = request.result.items[1]
	local text = (item.insertText or "")
	local start, stop, capture = text:find(pattern)
	if start == nil or stop == nil or capture == nil then
		return M.cancel_request()
	end
	item.insertText = text:sub(stop + 1)

	local ls = {}
	for l in iter_lines(capture) do
		ls[#ls + 1] = l
	end

	vim.api.nvim_put(ls, "c", true, true)

	M.telemetry.notify_event({
		type = "select",
		eventId = {
			completionId = item.data.eventId.completionId,
			choiceIndex = item.data.eventId.choiceIndex,
		},
		viewId = request.displayEventId,
		elapsed = math.floor(os.clock() * 1000 - request.displayTime),
	})

	local pos = vim.api.nvim_win_get_cursor(0)
	request.params.pos = { row = pos[1], col = pos[2] }

	if #item.insertText ~= 0 then
		M.internal.in_partial_accept = true
	end

	return display()
end

function M.accept_word()
	return accept_match("(%s*%S+)")
end

function M.accept_line()
	return accept_match("([^\n]*\n?)")
end

function M.accept()
	if request.result == nil then
		return
	end

	-- FIXME(@icycodes): Only support single choice completion for now
	local item = request.result.items[1]

	local ls = {}
	for l in iter_lines(item.insertText or "") do
		ls[#ls + 1] = l
	end

	vim.api.nvim_put(ls, "c", true, true)

	M.telemetry.notify_event({
		type = "select",
		eventId = {
			completionId = item.data.eventId.completionId,
			choiceIndex = item.data.eventId.choiceIndex,
		},
		viewId = request.displayEventId,
		elapsed = math.floor(os.clock() * 1000 - request.displayTime),
	})

	return M.cancel_request()
end

---@param is_manually boolean
function M.trigger(is_manually)
	M.cancel_request()
	local params = create_params(is_manually)
	request.params = params

	---@class InlineCompletionParams: lsp.TextDocumentPositionParams
	local inline_completion_params = vim.lsp.util.make_position_params(nil, "utf-16")
	inline_completion_params.context = {
		triggerKind = params.trigger_kind,
	}

	local client = M.get_client()
	if client == nil then
		return
	end

	local status
	status, request.id = client:request("textDocument/inlineCompletion", inline_completion_params, function(_, result)
		if request.params ~= params then
			-- the request has been overridden, just forget this callback
			return
		end
		if not (type(result) == "table" and type(result.items) == "table") or #result.items == 0 then
			-- nothing to display in the request
			return M.cancel_request()
		end
		request.result = result
		return display()
	end)

	if not status and not warned_ls_shutdown then
		vim.notify(
			"Server " .. tabby_ls_name .. " was shutdown, giving suggestions is impossible.",
			vim.log.levels.ERROR
		)
		warned_ls_shutdown = true
	end
end

return M
