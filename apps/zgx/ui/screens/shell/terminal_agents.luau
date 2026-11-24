local sessions = require("@account/sessions")
local api = require("@app/screens/panel/terminal_api")

local M = {}

export type Entry = { id: string, name: string, bin: string, mark: string? }
export type Agent = {
	id: string,
	agent: string,
	project: string?,
	device: string,
	cwd: string?,
	branch: string?,
	anchor: string?,
	created: number,
	updated: number,
	terminal: string?,
	command: string?,
	claim: string?,
	launched: boolean?,
}

M.PREFIX = "term:"

M.CATALOG = {
	{ id = "claude", name = "Claude Code", bin = "claude", mark = "claude" },
	{ id = "codex", name = "Codex", bin = "codex", mark = "openai" },
	{ id = "pi", name = "Pi", bin = "pi", mark = "pi" },
	{ id = "amp", name = "Amp", bin = "amp" },
	{ id = "cline", name = "Cline", bin = "cline" },
	{ id = "devin", name = "Devin", bin = "devin", mark = "devin" },
	{ id = "deepseek", name = "DeepSeek", bin = "deepseek", mark = "provider-deepseek" },
	{ id = "cursor", name = "Cursor Agent", bin = "cursor-agent", mark = "cursor" },
	{ id = "gemini", name = "Gemini CLI", bin = "gemini", mark = "provider-gemini" },
	{ id = "opencode", name = "OpenCode", bin = "opencode", mark = "opencode" },
	{ id = "grok", name = "Grok CLI", bin = "grok", mark = "grok" },
	{ id = "copilot", name = "Copilot CLI", bin = "copilot" },
	{ id = "droid", name = "Droid", bin = "droid" },
	{ id = "qwen", name = "Qwen Code", bin = "qwen" },
	{ id = "kimi", name = "Kimi CLI", bin = "kimi" },
	{ id = "goose", name = "Goose", bin = "goose" },
	{ id = "crush", name = "Crush", bin = "crush" },
	{ id = "aider", name = "Aider", bin = "aider" },
	{ id = "auggie", name = "Auggie", bin = "auggie" },
	{ id = "kiro", name = "Kiro CLI", bin = "kiro-cli" },
	{ id = "hermes", name = "Hermes", bin = "hermes", mark = "hermes" },
} :: { Entry }

M.installed = ui.shared("terminal_agents.installed", nil :: { [string]: string }?)
M.hidden = ui.persist("terminal_agents_hidden", {} :: { [string]: boolean })
M.open = ui.persist("terminal_agents_open", {} :: { Agent })
M.status = ui.state("terminal_agents_status", {} :: { [string]: string })
M.titles = ui.state("terminal_agents_titles", {} :: { [string]: string })
local unseen = ui.state("terminal_agents_unseen", {} :: { [string]: boolean })
local detecting = false

function M.is(id: string?): boolean
	return type(id) == "string" and string.sub(id, 1, #M.PREFIX) == M.PREFIX
end

function M.entry(id: string): Entry?
	for _, e in M.CATALOG do
		if e.id == id then
			return e
		end
	end
	return nil
end

function M.detect()
	if detecting then
		return
	end
	detecting = true
	local bins: { string } = {}
	for _, e in M.CATALOG do
		table.insert(bins, e.bin)
	end
	local ok, pending = pcall(ui.call, "terminal_agents.detect", { bins = bins })
	if not ok then
		detecting = false
		if M.installed:peek() == nil then
			M.installed:set({})
		end
		return
	end
	pending:after(function(found: any)
		detecting = false
		local out: { [string]: string } = {}
		for _, e in M.CATALOG do
			local path = if type(found) == "table" then found[e.bin] else nil
			if type(path) == "string" and path ~= "" then
				out[e.id] = path
			end
		end
		M.installed:set(out)
	end, function()
		detecting = false
		if M.installed:peek() == nil then
			M.installed:set({})
		end
	end)
end

M.available = ui.computed(function(): { Entry }
	local found = M.installed:get() or {}
	local out: { Entry } = {}
	for _, e in M.CATALOG do
		if found[e.id] then
			table.insert(out, e)
		end
	end
	return out
end)

M.offered = ui.computed(function(): { Entry }
	local hidden = M.hidden:get()
	local out: { Entry } = {}
	for _, e in M.available:get() do
		if not hidden[e.id] then
			table.insert(out, e)
		end
	end
	return out
end)

function M.set_shown(id: string, on: boolean)
	local next = table.clone(M.hidden:peek())
	next[id] = if on then nil else true
	M.hidden:set(next)
end

function M.get(id: string?): Agent?
	if not M.is(id) then
		return nil
	end
	for _, a in M.open:peek() do
		if a.id == id then
			return a
		end
	end
	return nil
end

local function update(id: string, change: (Agent) -> ())
	local list = table.clone(M.open:peek())
	for i, a in list do
		if a.id == id then
			local next = table.clone(a)
			change(next)
			list[i] = next
			M.open:set(list)
			return
		end
	end
end

function M.set_terminal(id: string, terminal: string?, command: string?, claim: string?)
	update(id, function(a)
		a.terminal = terminal
		a.command = command
		a.claim = claim
	end)
end

function M.mark_launched(id: string)
	update(id, function(a)
		a.launched = true
	end)
end

function M.start(at: { agent: string, project: string?, device: string, cwd: string?, branch: string?, anchor: string? }): string
	local now = os.time()
	local id = `{M.PREFIX}{now}-{math.random(1, 1e6)}`
	local list = table.clone(M.open:peek())
	table.insert(list, {
		id = id,
		agent = at.agent,
		project = at.project,
		device = at.device,
		cwd = at.cwd,
		branch = at.branch,
		anchor = at.anchor,
		created = now,
		updated = now,
	})
	M.open:set(list)
	return id
end

function M.close(id: string)
	local a = M.get(id)
	if not a then
		return
	end
	local ok, t = pcall(api.term, id)
	if ok and t then
		pcall(function()
			t:close()
		end)
	end
	if a.terminal then
		api.close(a.terminal, a.device):after(function() end, function() end)
	end
	local list: { Agent } = {}
	for _, other in M.open:peek() do
		if other.id ~= id then
			table.insert(list, other)
		end
	end
	M.open:set(list)
end

function M.target(a: Agent): any
	if a.project then
		return { space = a.project, device = a.device, root = a.cwd }
	end
	if a.anchor then
		return { chat = a.anchor, device = a.device, root = a.cwd }
	end
	return nil
end

function M.seen(id: string)
	if unseen:peek()[id] then
		local next = table.clone(unseen:peek())
		next[id] = nil
		unseen:set(next)
	end
end

local function name_of(a: Agent): string
	local e = M.entry(a.agent)
	return if e then e.name else a.agent
end

M.chats = ui.computed(function(): { sessions.Chat }
	local status = M.status:get()
	local titles = M.titles:get()
	local fresh = unseen:get()
	local out: { sessions.Chat } = {}
	for _, a in M.open:get() do
		local e = M.entry(a.agent)
		local mark = if e then e.mark else nil
		local s = status[a.id]
		if not s and fresh[a.id] then
			s = "done"
		end
		table.insert(out, {
			id = a.id,
			title = titles[a.id] or name_of(a),
			project = a.project,
			device = a.device,
			branch = a.branch,
			cwd = a.cwd,
			status = s,
			updated = a.updated,
			created = a.created,
			harness = if mark then "terminal" else `acp.{a.agent}`,
			agent = mark,
			terminal_agent = a.agent,
		} :: any)
	end
	return out
end)

function M.chat(id: string?): sessions.Chat?
	if not M.is(id) then
		return nil
	end
	for _, c in M.chats:get() do
		if c.id == id then
			return c
		end
	end
	return nil
end

local GLYPHS = { [0x00B7] = true, [0x2722] = true, [0x2733] = true, [0x2736] = true, [0x273B] = true, [0x273D] = true }

local function title_of(id: string): string?
	local ok, t = pcall(api.term, id)
	if not ok or not t then
		return nil
	end
	local got, title = pcall(function()
		return t.title
	end)
	return if got and type(title) == "string" and title ~= "" then title else nil
end

local function first_of(title: string): number?
	local ok, first = pcall(utf8.codepoint, title, 1, 1)
	return if ok then first else nil
end

local function spinning(title: string?): boolean
	local first = if title then first_of(title) else nil
	return first ~= nil and ((first >= 0x2801 and first <= 0x28FF) or (first >= 0x25D0 and first <= 0x25D3))
end

local function clean(title: string?): string?
	if not title then
		return nil
	end
	local first = first_of(title)
	if first and (spinning(title) or GLYPHS[first]) then
		local after = utf8.offset(title, 2)
		title = if after then string.sub(title, after) else ""
	end
	local stripped = string.match(title :: string, "^%s*(.-)%s*$") or ""
	return if stripped ~= "" then stripped else nil
end

local function focused(): string?
	local route = require("@app/screens/shell/route")
	local c = route.chat:peek()
	return if c.name == "session" then c.session else nil
end

local function judge(id: string, s: any, title: string?): string?
	if type(s) ~= "table" or s.exited then
		return nil
	end
	if s.program == "blocked" then
		return if s.input == "permission" then "approval" else "input"
	elseif s.program == "working" then
		return "working"
	elseif s.program == "error" then
		return "failed"
	elseif s.program ~= nil then
		return nil
	end
	if spinning(title) then
		return "working"
	end
	if s.busy and type(s.quiet_ms) == "number" and s.quiet_ms < 1500 and focused() ~= id then
		return "working"
	end
	return nil
end

local function settle(id: string, kind: string?)
	local was = M.status:peek()[id]
	if was == kind then
		return
	end
	local next = table.clone(M.status:peek())
	next[id] = kind
	M.status:set(next)
	if was == "working" and kind == nil and focused() ~= id then
		local u = table.clone(unseen:peek())
		u[id] = true
		unseen:set(u)
	end
	if kind == "working" then
		update(id, function(a)
			a.updated = os.time()
		end)
	end
end

local function set_title(id: string, title: string?)
	local now = M.titles:peek()
	if now[id] == title then
		return
	end
	local next = table.clone(now)
	next[id] = title
	M.titles:set(next)
end

local function poll()
	local live: { [string]: boolean } = {}
	for _, a in M.open:peek() do
		live[a.id] = true
		if a.terminal then
			local id = a.id
			api.status(a.terminal, a.device):after(function(s: any)
				if not M.get(id) then
					return
				end
				local raw = title_of(id)
				settle(id, judge(id, s, raw))
				set_title(id, if type(s) == "table" and s.busy then clean(raw) else nil)
			end, function() end)
		end
	end
	for id in M.titles:peek() do
		if not live[id] then
			set_title(id, nil)
		end
	end
	for id in M.status:peek() do
		if not live[id] then
			settle(id, nil)
		end
	end
end

ui.every(1500, function()
	if #M.open:peek() > 0 then
		poll()
	end
end)

ui.after(0, function()
	local route = require("@app/screens/shell/route")
	ui.effect(function()
		local c = route.chat:get()
		if c.name == "session" and M.is(c.session) then
			M.seen(c.session)
		end
	end)
	M.detect()
end)

return M
