local host = require("@app/screens/settings/host")
local ds = require("@ds")
local toast = require("@ds/toast")
local locale = require("@ds/locale")
local skeleton = require("@ds/skeleton")
local search = require("@app/screens/settings/search")
local visits = require("@app/screens/settings/visits")
local add_agent = require("@app/screens/settings/add_agent")
local devices_page = require("@app/screens/settings/devices")
local sessions = require("@account/sessions")
local look = require("@app/screens/shell/project_look")

local M = {}

M.ID = "storage"
M.TITLE = "Storage"

search.index(M.ID, ui.t("settings.storage.title"), ui.t("settings.storage.terms"), {
	{ key = "usage", title = ui.t("settings.storage.usage.label"), terms = ui.t("settings.storage.usage.terms") },
	{ key = "worktrees", title = ui.t("settings.storage.worktrees_row.label"), terms = ui.t("settings.storage.worktrees_row.terms") },
	{ key = "cleanup", title = ui.t("settings.storage.cleanup.label"), terms = ui.t("settings.storage.cleanup.terms") },
})

export type AppUsage = { updates: number, templates: number, plugins: number, logs: number, uploads: number, other: number }
export type ProjectUsage = { name: string, repoPath: string?, worktrees: number, worktreeCount: number, journals: number, total: number }
export type Usage = { computedAt: number, total: number, root: string, app: AppUsage, projects: { ProjectUsage } }
export type Worktree = ds.StorageWorktree

local usage = ui.state("settings_storage_usage", nil :: Usage?)
local sizing = ui.state("settings_storage_sizing", false)
local worktrees = ui.state("settings_storage_worktrees", nil :: { Worktree }?)
local failed = ui.state("settings_storage_failed", {} :: { [string]: string })
local view = ui.state("settings_storage_view", "main")

local removing_open = ui.state("settings_storage_removing_open", false)
local removing_busy = ui.state("settings_storage_removing_busy", false)
local removing_error = ui.state("settings_storage_removing_error", "")
local removing_anyway = ui.state("settings_storage_removing_anyway", false)
local removing_said = ui.state("settings_storage_removing_said", nil :: Worktree?)

local free_open = ui.state("settings_storage_free_open", false)
local free_busy = ui.state("settings_storage_free_busy", false)
local free_error = ui.state("settings_storage_free_error", "")
local pick_stale = ui.state("settings_storage_pick_stale", true)
local pick_deleted = ui.state("settings_storage_pick_deleted", true)
local pick_archived = ui.state("settings_storage_pick_archived", false)
local pick_updates = ui.state("settings_storage_pick_updates", true)
M.days = ui.state("settings_storage_days", 30)

local DAYS = { 7, 14, 30, 60, 90 }
local APP_KEYS = { "updates", "templates", "plugins", "logs", "uploads", "other" }

M.bytes = ds.Storage.bytes

local function engine(method: string, params: { [string]: any }?): any
	return host.call("settings.engine", { method = method, params = params or {} })
end

local function word_of(err: any): string?
	if type(err) == "string" then
		return err
	elseif type(err) == "table" or type(err) == "userdata" then
		local m = err.message
		return if type(m) == "string" then m else nil
	end
	return nil
end

function M.why(err: any): string
	local word = word_of(err)
	if word == "offline" then
		return ui.t("settings.engine.offline"):get()
	elseif word == "outdated" then
		return ui.t("settings.engine.outdated"):get()
	elseif word and string.find(string.lower(word), "uncommitted", 1, true) then
		return ui.t("settings.storage.remove.dirty_error"):get()
	elseif word and word ~= "" and word ~= "failed" and word ~= "refused" and #word <= 160 then
		return word
	end
	return ui.t("common.something_went_wrong"):get()
end

local function load_usage(refresh: boolean)
	if sizing:peek() then
		return
	end
	sizing:set(true)
	engine("GetStorageUsage", { refresh = refresh }):after(function(v: any)
		ui.batch(function()
			sizing:set(false)
			usage:set(v)
			failed:set_key("usage", nil)
		end)
	end, function(err: any)
		ui.batch(function()
			sizing:set(false)
			failed:set_key("usage", M.why(err))
		end)
	end)
end

local function load_worktrees()
	engine("ListStorageWorktrees"):after(function(v: any)
		ui.batch(function()
			worktrees:set(v or {})
			failed:set_key("worktrees", nil)
		end)
	end, function(err: any)
		failed:set_key("worktrees", M.why(err))
	end)
end

local function refresh()
	load_usage(true)
	load_worktrees()
end

local function sum(list: { ProjectUsage }, key: string): number
	local n = 0
	for _, p in list do
		n += (p :: any)[key] or 0
	end
	return n
end

local function app_total(a: AppUsage): number
	return (a.updates or 0) + (a.templates or 0) + (a.plugins or 0) + (a.logs or 0) + (a.uploads or 0) + (a.other or 0)
end

local function app_of(): AppUsage
	local u = usage:get()
	return if u and u.app then u.app else {} :: any
end

local projects = ui.computed(function(): { ProjectUsage }
	local u = usage:get()
	local out = if u then table.clone(u.projects or {}) else {}
	table.sort(out, function(a: ProjectUsage, b: ProjectUsage): boolean
		if a.total ~= b.total then
			return a.total > b.total
		end
		return a.name < b.name
	end)
	return out
end)

local function project_named(name: string): ProjectUsage?
	for _, p in projects:get() do
		if p.name == name then
			return p
		end
	end
	return nil
end

function M.stale(list: { Worktree }): (number, number)
	local n, size = 0, 0
	for _, w in list do
		if not w.dirty and not w.missing and w.chatState ~= "active" then
			n += 1
			size += w.bytes or 0
		end
	end
	return n, size
end

function M.reclaimable(list: { Worktree }?, app: AppUsage?): number
	local _, size = M.stale(list or {})
	return size + (if app then app.updates or 0 else 0)
end

local function go(v: string)
	view:set(v)
end
local nav = {
	go = go,
	device = function(): string
		return ""
	end,
}

local function here(): sessions.Device?
	for _, d in sessions.devices:get() or {} do
		if d.here then
			return d
		end
	end
	return nil
end

local function device_picker(): Node
	return ui.component(function(): Node
		local chosen = ui.use_state("here")
		return ds.Select {
			value = chosen,
			name = ui.t("settings.providers.device"),
			size = "sm",
			w = 200,
			options = function(): { any }
				local d = here()
				return {
					{
						value = "here",
						label = if d then d.name else ui.t("settings.storage.this_computer"):get(),
						icon = devices_page.icon(if d then d.platform else "macos"),
					},
				}
			end,
		}
	end)({})
end

local function project_of(p: ProjectUsage): sessions.Project?
	local d = here()
	local list = sessions.now:get().projects or {}
	local by_name: sessions.Project? = nil
	for _, x in list do
		local mine = d == nil or x.device == d.id
		if mine and p.repoPath and x.path == p.repoPath then
			return x
		end
		if mine and by_name == nil and string.lower(x.name) == string.lower(p.name) then
			by_name = x
		end
	end
	return by_name
end

local function project_tile(p: () -> ProjectUsage, size: number): Node
	return ui.presence(function(): string
		local x = project_of(p())
		return if x then x.id else ""
	end, function(id: string): Node
		local name = p().name
		if id == "" then
			return ds.Tile { label = name, hue = look.hue(name), size = size }
		end
		local l: look.Look = look.by_id(id) or { hue = look.hue(id) }
		return ds.Tile { label = name, hue = l.hue, src = l.src, emoji = l.emoji, size = size, project = id }
	end)
end

local function error_line(said: State<string>): Node
	return ui.show(function(): boolean
		return said:get() ~= ""
	end, ds.Hint {
		function(): string
			return said:get()
		end,
		tone = "danger",
	})
end

local function ask_free()
	local list = worktrees:peek() or {}
	local u = usage:peek()
	ui.batch(function()
		pick_stale:set((M.stale(list)) > 0)
		pick_deleted:set(true)
		pick_archived:set(false)
		pick_updates:set(u ~= nil and u.app ~= nil and (u.app.updates or 0) > 0)
		free_error:set("")
		free_open:set(true)
	end)
end

local function stale_now(): (number, number)
	return M.stale(worktrees:get() or {})
end

local function updates_now(): number
	return app_of().updates or 0
end

type Step = { action: string, olderThanDays: number? }

local function picked(): { Step }
	local out: { Step } = {}
	if pick_stale:get() and (stale_now()) > 0 then
		table.insert(out, { action = "staleWorktrees" })
	end
	if pick_deleted:get() then
		table.insert(out, { action = "deletedChatData" })
	end
	if pick_archived:get() then
		table.insert(out, { action = "archivedChats", olderThanDays = M.days:get() })
	end
	if pick_updates:get() and updates_now() > 0 then
		table.insert(out, { action = "stagedUpdate" })
	end
	return out
end

local function picked_bytes(): number
	local n = 0
	if pick_stale:get() then
		local _, size = stale_now()
		n += size
	end
	if pick_updates:get() then
		n += updates_now()
	end
	return n
end

local function free_up()
	if free_busy:peek() then
		return
	end
	local steps = picked()
	if #steps == 0 then
		return
	end
	free_busy:set(true)
	free_error:set("")
	local removed, freed = 0, 0
	local function reload()
		load_worktrees()
		load_usage(true)
	end
	local function step(i: number)
		local s = steps[i]
		if not s then
			ui.batch(function()
				free_busy:set(false)
				free_open:set(false)
			end)
			toast.show {
				title = if freed > 0
					then ui.t("settings.storage.clean.freed", { size = M.bytes(freed) }):get()
					else ui.t("settings.storage.free.cleared"):get(),
				body = ui.t("settings.storage.free.removed", { n = removed }):get(),
				tone = "success",
			}
			reload()
			return
		end
		engine("CleanStorage", s :: any):after(function(v: any)
			if type(v) == "table" then
				removed += v.removed or 0
				freed += v.freedBytes or 0
			end
			step(i + 1)
		end, function(err: any)
			ui.batch(function()
				free_busy:set(false)
				free_error:set(M.why(err))
			end)
			if i > 1 then
				reload()
			end
		end)
	end
	step(1)
end

local function day_options(): { any }
	local out = {}
	for _, n in DAYS do
		table.insert(out, { value = n, label = ui.t("settings.storage.clean.archived.option", { n = n }):get() })
	end
	return out
end

local function free_dialog(): Node
	return ds.Dialog {
		open = free_open,
		title = ui.t("settings.storage.free.title"),
		body = ui.t("settings.storage.free.body"),
		tone = "danger",
		size = "md",
		hold = function(): boolean
			return free_busy:get()
		end,
		confirm = {
			label = function(): string
				local n = picked_bytes()
				return if n > 0
					then ui.t("settings.storage.free.label", { size = M.bytes(n) }):get()
					else ui.t("settings.storage.free.confirm_any"):get()
			end,
			keep_open = true,
			busy = function(): boolean
				return free_busy:get()
			end,
			disabled = function(): boolean
				return #picked() == 0
			end,
			on_click = free_up,
		},
		ds.Settings.Group {
			ds.Storage.Choice {
				value = pick_stale,
				label = function(): string
					return ui.t("settings.storage.free.stale", { n = (stale_now()) }):get()
				end,
				description = ui.t("settings.storage.free.stale_hint"),
				size = function(): string?
					local n, size = stale_now()
					return if n > 0 then M.bytes(size) else nil
				end,
				disabled = function(): boolean
					return (stale_now()) == 0
				end,
			},
			ds.Storage.Choice {
				value = pick_deleted,
				label = ui.t("settings.storage.free.deleted"),
				description = ui.t("settings.storage.free.deleted_hint"),
			},
			ds.Storage.Choice {
				value = pick_archived,
				label = ui.t("settings.storage.free.archived"),
				description = ui.t("settings.storage.free.archived_hint"),
				extra = ds.Select {
					value = M.days,
					name = ui.t("settings.storage.clean.archived.days"),
					size = "sm",
					w = 104,
					options = day_options,
				},
			},
			ds.Storage.Choice {
				value = pick_updates,
				label = ui.t("settings.storage.free.updates"),
				description = ui.t("settings.storage.free.updates_hint"),
				size = function(): string?
					local n = updates_now()
					return if n > 0 then M.bytes(n) else nil
				end,
				disabled = function(): boolean
					return updates_now() == 0
				end,
			},
		},
		error_line(free_error),
	}
end

local function free_row(): Node
	local function bytes(): number
		return M.reclaimable(worktrees:get(), app_of())
	end
	return search.anchor(
		"cleanup",
		ds.Settings.Row {
			label = function(): string
				local n = bytes()
				return if n > 0
					then ui.t("settings.storage.free.label", { size = M.bytes(n) }):get()
					else ui.t("settings.storage.free.nothing"):get()
			end,
			description = ui.t("settings.storage.free.description"),
			lead = ui.presence(function(): string
				return if bytes() > 0 then "some" else "none"
			end, function(k: string): Node
				return ds.ProviderCard.disc(ds.Icon { name = "magic-stick", size = 16 }, if k == "some" then "accent" else nil)
			end),
			on_click = ask_free,
		}
	)
end

local function meter(): Node
	local function projects_of(): { ProjectUsage }
		local u = usage:get()
		return if u then u.projects or {} else {}
	end
	return ds.Storage.Meter {
		id = "storage-meter",
		total = function(): number?
			local u = usage:get()
			return if u then u.total else nil
		end,
		caption = ui.t("settings.storage.used"),
		loading = ui.t("settings.storage.measuring"),
		parts = {
			{
				label = ui.t("settings.storage.parts.worktrees"),
				bytes = function(): number
					return sum(projects_of(), "worktrees")
				end,
			},
			{
				label = ui.t("settings.storage.parts.journals"),
				bytes = function(): number
					return sum(projects_of(), "journals")
				end,
			},
			{
				label = ui.t("settings.storage.parts.app"),
				bytes = function(): number
					return app_total(app_of())
				end,
				color = "$text.tertiary",
			},
		},
		trail = function(): Node
			return ui.row {
				gap = "$space.1",
				items = "center",
				ui.text {
					function(): string
						if sizing:get() then
							return ui.t("settings.storage.measuring_short"):get()
						end
						local u = usage:get()
						if not u then
							return ""
						end
						return ui.t("settings.storage.computed", { ago = locale.ago(os.time() - u.computedAt / 1000) }):get()
					end,
					text_size = "$font.size.sm",
					line_height = "$font.line.sm",
					color = "$text.tertiary",
				},
				ds.IconButton {
					id = "storage-refresh",
					icon = "refresh",
					label = ui.t("settings.storage.refresh"),
					size = "md",
					tone = "quiet",
					disabled = function(): boolean
						return sizing:get()
					end,
					on_click = refresh,
				},
			}
		end,
		foot = free_row(),
		error = function(): string?
			return if usage:get() then failed:get().usage else nil
		end,
	}
end

local function project_row(_p: ProjectUsage, _i: number, p: State<ProjectUsage>): Node
	return ds.Settings.Row {
		label = function(): string
			return p:get().name
		end,
		description = function(): string
			return ui.t("settings.storage.projects.count", { n = p:get().worktreeCount or 0 }):get()
		end,
		value = function(): string
			return M.bytes(p:get().total)
		end,
		lead = project_tile(function(): ProjectUsage
			return p:get()
		end, ds.Storage.TILE),
		truncate = true,
		on_click = function()
			go(`project:{p:peek().name}`)
		end,
	}
end

local function app_row(): Node
	return ds.Settings.Row {
		label = ui.t("settings.storage.app.title"),
		description = ui.t("settings.storage.app.row"),
		value = function(): string
			return M.bytes(app_total(app_of()))
		end,
		lead = ds.Storage.glyph("settings-minimalistic"),
		truncate = true,
		on_click = function()
			go("app")
		end,
	}
end

local function projects_card(): Node
	return search.anchor(
		"worktrees",
		ds.Settings.Section {
			title = ui.t("settings.storage.projects.title"),
			ui.presence(function(): string
				return if usage:get() then "ready" else "loading"
			end, function(k: string): Node
				if k == "loading" then
					return ds.Settings.Group {
						skeleton.Row { lead = ds.Storage.TILE, title = 140, line = 72, trail = 64 },
						skeleton.Row { lead = ds.Storage.TILE, title = 110, line = 72, trail = 64 },
						skeleton.Row { lead = ds.Storage.TILE, title = 90, line = 96, trail = 64 },
					}
				end
				return ds.Settings.Group {
					ui.column {
						w_full = true,
						ui.each(projects, function(item: ProjectUsage, i: number, now: State<ProjectUsage>): Node
							return ui.column {
								w_full = true,
								ui.show(function(): boolean
									local head = projects:get()[1]
									return head ~= nil and head.name ~= now:get().name
								end, ds.Settings.Rule),
								project_row(item, i, now),
							}
						end, {
							key = function(p: ProjectUsage): string
								return p.name
							end,
							w_full = true,
						}),
						ui.show(function(): boolean
							return #projects:get() == 0
						end, ds.Settings.Row { label = ui.t("settings.storage.projects.none"), lead = ds.Storage.glyph("folder") }),
					},
					app_row(),
				}
			end, { w_full = true, enter = { opacity = { 0, 1 }, duration = 120 }, exit = { opacity = 0, duration = 60 }, mode = "wait" }),
		}
	)
end

local function usage_kind(): string
	if not usage:get() and failed:get().usage then
		return "failed"
	end
	return "meter"
end

local function usage_body(kind: string): Node
	if kind == "failed" then
		return ds.Callout {
			tone = "danger",
			title = ui.t("settings.storage.couldnt_measure") :: any,
			body = function(): string
				return failed:get().usage or ""
			end,
			action = { label = ui.t("common.retry") :: any, on_click = function()
				load_usage(true)
			end },
		}
	end
	return ui.column {
		w_full = true,
		gap = "$space.6",
		search.anchor("usage", meter()),
		projects_card(),
	}
end

local function main_page(): Node
	return ds.Settings.Page {
		title = ui.t("settings.storage.title"),
		description = ui.t("settings.storage.description"),
		trail = device_picker(),
		trail_top = true,
		ui.presence(usage_kind, usage_body, {
			w_full = true,
			enter = { opacity = { 0, 1 }, duration = 120 },
			exit = { opacity = 0, duration = 60 },
			mode = "wait",
		}),
	}
end

local function ask_remove(w: Worktree)
	ui.batch(function()
		removing_said:set(w)
		removing_error:set("")
		removing_anyway:set(false)
		removing_open:set(true)
	end)
end

local function amount_row(props: { label: any, description: any, bytes: () -> number, lead: Node? }): Node
	return ds.Settings.Row {
		label = props.label,
		description = props.description,
		lead = props.lead,
		truncate = true,
		control = ds.Storage.Amount(function(): string
			return M.bytes(props.bytes())
		end),
	}
end

local function project_page(name: string): Node
	local function p(): ProjectUsage
		return project_named(name) or { name = name, worktrees = 0, worktreeCount = 0, journals = 0, total = 0 }
	end
	local list = ui.computed(function(): { Worktree }?
		local all = worktrees:get()
		if not all then
			return nil
		end
		local out = {}
		for _, w in all do
			if w.project == name then
				table.insert(out, w)
			end
		end
		return out
	end)
	return add_agent.sub_page(
		add_agent.back(ui.t("settings.storage.title"), "main", nav),
		ds.Settings.Page {
			title = name,
			description = function(): string
				local x = p()
				local size = M.bytes(x.total)
				return if x.repoPath then `{x.repoPath} · {size}` else size
			end,
			trail = project_tile(p, 48),
			trail_top = true,
			ds.Settings.Section {
				title = ui.t("settings.storage.worktrees.title"),
				ds.Storage.Worktrees {
					list = list :: any,
					error = function(): string?
						return failed:get().worktrees
					end,
					on_remove = ask_remove,
					on_retry = load_worktrees,
					empty = ui.t("settings.storage.project.none"),
					failed = ui.t("settings.storage.worktrees.couldnt"),
				},
			},
			ds.Settings.Group {
				amount_row {
					label = ui.t("settings.storage.parts.journals"),
					description = ui.t("settings.storage.project.journals_hint"),
					lead = ds.Storage.glyph("chat-round-line"),
					bytes = function(): number
						return p().journals or 0
					end,
				},
			},
		}
	)
end

local function app_page(): Node
	local rows: { any } = {}
	for _, key in APP_KEYS do
		table.insert(rows, amount_row {
			label = ui.t(`settings.storage.app.{key}`),
			description = ui.t(`settings.storage.app.{key}_hint`),
			bytes = function(): number
				return (app_of() :: any)[key] or 0
			end,
		})
	end
	return add_agent.sub_page(
		add_agent.back(ui.t("settings.storage.title"), "main", nav),
		ds.Settings.Page {
			title = ui.t("settings.storage.app.title"),
			description = function(): string
				local u = usage:get()
				return ui.t("settings.storage.app.page", { path = if u then u.root else "~/.naive" }):get()
			end,
			ds.Settings.Group(rows :: any),
		}
	)
end

local function page_for(v: string): Node
	if v == "app" then
		return app_page()
	end
	local name = string.match(v, "^project:(.+)$")
	if name then
		return project_page(name)
	end
	return main_page()
end

local function remove()
	local w = removing_said:peek()
	if not w or removing_busy:peek() then
		return
	end
	local force = w.dirty and removing_anyway:peek()
	removing_busy:set(true)
	removing_error:set("")
	engine("RemoveWorktree", { path = w.path, force = force }):after(function(v: any)
		ui.batch(function()
			removing_busy:set(false)
			removing_open:set(false)
		end)
		local freed = if type(v) == "table" then v.freedBytes else nil
		toast.show {
			title = ui.t("settings.storage.remove.done"):get(),
			body = if freed then ui.t("settings.storage.clean.freed", { size = M.bytes(freed) }):get() else nil,
			tone = "success",
		}
		load_worktrees()
		load_usage(false)
	end, function(err: any)
		local said = if w.dirty and not force and word_of(err) == "failed" then ui.t("settings.storage.remove.dirty_error"):get() else M.why(err)
		ui.batch(function()
			removing_busy:set(false)
			removing_error:set(said)
		end)
	end)
end

local function removal_body(): string
	local w = removing_said:get()
	if not w then
		return ""
	end
	if w.branch then
		return ui.t("settings.storage.remove.body", { path = w.path, branch = w.branch }):get()
	end
	return ui.t("settings.storage.remove.body_no_branch", { path = w.path }):get()
end

local function risky(): boolean
	local w = removing_said:get()
	return w ~= nil and (w.dirty or (w.unpushed or 0) > 0)
end

local function removal_dialog(): Node
	return ds.Dialog {
		open = removing_open,
		title = (function(): string
			local w = removing_said:get()
			return ui.t("settings.storage.remove.title", { name = if w then w.name else "" }):get()
		end) :: any,
		body = removal_body :: any,
		tone = "danger",
		size = "sm",
		confirm = {
			label = ui.t("settings.storage.remove.confirm") :: any,
			keep_open = true,
			busy = function(): boolean
				return removing_busy:get()
			end,
			disabled = function(): boolean
				return risky() and not removing_anyway:get()
			end,
			on_click = remove,
		},
		ui.show(risky, ui.column {
			w_full = true,
			gap = "$space.2",
			ds.Callout {
				tone = "warning",
				title = function(): string
					local w = removing_said:get()
					if not w then
						return ""
					end
					local lines: { string } = {}
					if w.dirty then
						table.insert(lines, ui.t("settings.storage.remove.dirty"):get())
					end
					if (w.unpushed or 0) > 0 then
						table.insert(lines, ui.t("settings.storage.remove.unpushed", { n = w.unpushed }):get())
					end
					return table.concat(lines, " ")
				end,
			},
			ds.Checkbox { value = removing_anyway, label = ui.t("settings.storage.remove.anyway") },
		}),
		error_line(removing_error),
	}
end

function M.view(): Node
	visits.once("storage", function()
		if view:peek() ~= "main" then
			view:set("main")
		end
		load_usage(false)
		load_worktrees()
	end)
	return ui.column {
		w_full = true,
		items = "center",
		ui.presence(function(): string
			return view:get()
		end, function(v: string): Node
			return ui.column { w_full = true, items = "center", page_for(v) }
		end, { w_full = true, enter = { opacity = { 0, 1 }, y = { 6, 0 }, duration = 160 }, exit = { opacity = 0, duration = 80 }, mode = "wait" }),
		removal_dialog(),
		free_dialog(),
	}
end

return M
