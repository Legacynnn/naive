local ds = require("@ds")
local api = require("@app/screens/panel/terminal_api")
local agents = require("@app/screens/shell/terminal_agents")

local M = {}

local starting: { [string]: boolean } = {}

local function message_of(err: any): { key: string?, text: string? }
	local m = if type(err) == "table" and err.message then tostring(err.message) else tostring(err)
	if m == "offline" then
		return { key = "panel.terminal.offline" }
	elseif string.find(string.lower(m), "unknown method", 1, true) then
		return { key = "panel.terminal.update" }
	end
	return { text = m }
end

local function launch(id: string, terminal: string, device: string)
	local a = agents.get(id)
	local e = if a then agents.entry(a.agent) else nil
	if not a or not e or a.launched then
		return
	end
	agents.mark_launched(id)
	api.write(terminal, device, `{e.bin}\r`):after(function() end, function() end)
end

local function open(id: string, failed: any)
	local a = agents.get(id)
	if not a or a.command or starting[id] then
		return
	end
	local target = agents.target(a)
	if not target then
		failed:set({ key = "panel.terminal.no_session" })
		return
	end
	local function fail(err: any)
		starting[id] = nil
		failed:set(message_of(err))
	end
	starting[id] = true
	if a.terminal then
		local known = a.terminal
		api.command(known, a.device):after(function(command: string)
			starting[id] = nil
			agents.set_terminal(id, known, command, nil)
		end, fail)
		return
	end
	api.start(target):after(function(r: any)
		agents.set_terminal(id, nil, r.command, r.claim)
		starting[id] = nil
		api.claimed(r.claim):after(function(terminal: string)
			local now = agents.get(id)
			if not now then
				api.close(terminal, a.device):after(function() end, function() end)
				return
			end
			agents.set_terminal(id, terminal, now.command, nil)
			launch(id, terminal, a.device)
			api.command(terminal, a.device):after(function(command: string)
				if agents.get(id) then
					agents.set_terminal(id, terminal, command, nil)
				end
			end, function() end)
		end, function() end)
	end, fail)
end

M.Pane = ui.component(function(props: { agent: string }): Node
	local id = props.agent
	local failed = ui.use_state(nil :: { key: string?, text: string? }?)
	ui.after(0, function()
		open(id, failed)
	end)
	local function kind(): string
		if failed:get() then
			return "failed"
		end
		agents.open:get()
		local a = agents.get(id)
		return if a and a.command then "ready" else "opening"
	end
	return ui.column {
		id = `terminal-agent-{id}`,
		w_full = true,
		h_full = true,
		min_h = 0,
		ui.presence(kind, function(which: string): Node
			if which == "failed" then
				local why = failed:peek()
				return ds.EmptyState {
					icon = "terminal",
					size = "sm",
					fill = true,
					title = ui.t("panel.terminal.failed") :: any,
					body = (if why and why.key then ui.t(why.key) else (if why then why.text else nil) or "") :: any,
				}
			elseif which == "opening" then
				return ui.column { w_full = true, grow = 1 }
			end
			local a = agents.get(id) :: agents.Agent
			local term = api.term(id, { command = a.command, cwd = "~" })
			ui.after(0, function()
				if term and term.focus then
					term:focus()
				end
			end)
			return ui.column {
				w_full = true,
				grow = 1,
				min_h = 0,
				px = "$space.3",
				pt = "$space.3",
				pb = "$space.3",
				api.view {
					term = term,
					label = ui.t("panel.terminal.label"),
					relative = true,
					w_full = true,
					grow = 1,
					min_h = 0,
				},
			}
		end, { w_full = true, grow = 1, min_h = 0 }),
	}
end)

return M
