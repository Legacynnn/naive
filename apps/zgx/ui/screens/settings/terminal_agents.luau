local ds = require("@ds")
local search = require("@app/screens/settings/search")
local agents = require("@app/screens/shell/terminal_agents")
local SessionRow = require("@ds/session_row")

local M = {}

M.ID = "terminal_agents"
M.TITLE = "Terminal agents"

search.index(M.ID, ui.t("settings.terminal_agents.title"), ui.t("settings.terminal_agents.terms"), {})

local Item = ui.component(function(props: { entry: agents.Entry, path: string }): Node
	local e = props.entry
	local on = ui.use_state(not agents.hidden:peek()[e.id])
	return ds.Settings.Row {
		label = e.name,
		description = props.path,
		lead = SessionRow.mark(function(): any
			return { id = e.id, title = e.name, agent = e.mark, harness = if e.mark then "terminal" else `acp.{e.id}` }
		end, function(): boolean
			return true
		end),
		control = ds.Switch {
			value = on,
			label = e.name,
			on_change = function(v: boolean)
				agents.set_shown(e.id, v)
			end,
		},
	}
end)

function M.view(): Node
	agents.detect()
	return ds.Settings.Page {
		title = ui.t("settings.terminal_agents.title"),
		description = ui.t("settings.terminal_agents.description"),
		ds.Settings.Section {
			title = ui.t("settings.terminal_agents.installed"),
			ui.presence(function(): string
				local found = agents.installed:get()
				if found == nil then
					return "loading"
				end
				local ids: { string } = {}
				for _, e in agents.available:get() do
					table.insert(ids, e.id)
				end
				return if #ids == 0 then "none" else table.concat(ids, ",")
			end, function(key: string): Node
				if key == "loading" then
					return ds.Settings.Group {
						ds.Settings.Row { label = ui.t("settings.terminal_agents.looking") },
					}
				elseif key == "none" then
					return ds.Settings.Group {
						ds.Settings.Row { label = ui.t("settings.terminal_agents.none") },
					}
				end
				local rows: { Node } = {}
				local found = agents.installed:peek() or {}
				for i, e in agents.available:peek() do
					if i > 1 then
						table.insert(rows, ds.Settings.Rule())
					end
					table.insert(rows, Item { entry = e, path = found[e.id] or "" })
				end
				return ds.Settings.Group(rows)
			end, { w_full = true }),
		},
	}
end

return M
