local Settings = require("@self/settings")
local Icon = require("@self/icon")
local IconButton = require("@self/icon_button").IconButton
local Checkbox = require("@self/checkbox")
local ContextMenu = require("@self/context_menu")
local Hint = require("@self/hint")
local badge = require("@self/badge")
local banner = require("@self/banner")
local skeleton = require("@self/skeleton")
local control = require("@self/control")
local locale = require("@self/locale")
local motion = require("@self/motion")
local ink = require("@self/visual_ink")

local M = {}

export type Words = string | Message | () -> string
export type Part = { label: Words, bytes: control.Live<number?>, color: string? }
export type ChatState = "active" | "archived" | "deleted" | "none"
export type Worktree = {
	path: string,
	repoPath: string?,
	project: string,
	name: string,
	branch: string?,
	bytes: number?,
	modifiedAt: number?,
	chatId: string?,
	chatTitle: string?,
	chatState: string,
	dirty: boolean,
	unpushed: number?,
	missing: boolean,
}

local BAR_H = 8
local GAP = 2
local MIN_SEG = 3
local AMOUNT_W = 64
local TILE = 32
local TWEEN: any = { duration = 300, ease = "out(3)" }

M.bytes = locale.bytes
M.TILE = TILE

local function words(v: any): string
	return control.text(v) or ""
end

local function number_of(v: any): number?
	local n = control.value(v)
	return if type(n) == "number" then n else nil
end

local function color_of(part: Part, i: number): string
	return part.color or ink.series(i)
end

function M.split(sizes: { number }, width: number): ({ number }, { number })
	local xs, ws = {}, {}
	local total, k = 0, 0
	for i, s in sizes do
		xs[i], ws[i] = 0, 0
		if s > 0 then
			total += s
			k += 1
		end
	end
	if total <= 0 or width <= 0 then
		return xs, ws
	end
	local room = math.max(0, width - GAP * (k - 1))
	local sum, big = 0, 0
	for i, s in sizes do
		if s > 0 then
			ws[i] = math.max(MIN_SEG, s / total * room)
			sum += ws[i]
			if ws[i] > MIN_SEG then
				big += ws[i]
			end
		end
	end
	local over = sum - room
	if over > 0 and big > over then
		local f = (big - over) / big
		for i, w in ws do
			if w > MIN_SEG then
				ws[i] = w * f
			end
		end
	end
	local x = 0
	for i, s in sizes do
		if s > 0 then
			xs[i] = x
			x += ws[i] + GAP
		end
	end
	return xs, ws
end

local function swatch(color: () -> string): Node
	return ui.div { w = 8, h = 8, shrink = 0, rounded = "$radius.full", bg = color, aria_hidden = true }
end

export type BarProps = { parts: { Part }, h: number?, label: Words?, id: string? }

function M.Bar(props: BarProps): Node
	local h = props.h or BAR_H
	local track = ui.ref()
	local function sizes(): { number }
		local out = {}
		for i, p in props.parts do
			out[i] = number_of(p.bytes) or 0
		end
		return out
	end
	local layout = ui.computed(function(): any
		local xs, ws = M.split(sizes(), track.width or 0)
		return { xs = xs, ws = ws }
	end)
	local segs: { Node } = {}
	for i, part in props.parts do
		table.insert(segs, ui.div {
			class = "storage-segment",
			id = if props.id then `{props.id}-{i}` else nil,
			absolute = true,
			left = 0,
			top = 0,
			h = h,
			x = motion.tween(ui.computed(function(): number
				return layout:get().xs[i] or 0
			end), TWEEN),
			w = motion.tween(ui.computed(function(): number
				return layout:get().ws[i] or 0
			end), TWEEN),
			bg = function(): string
				return color_of(part, i)
			end,
		})
	end
	return ui.div {
		ref = track,
		id = props.id,
		class = "storage-bar",
		role = "img",
		label = function(): string
			local said = words(props.label)
			if said ~= "" then
				return said
			end
			local out = {}
			for _, p in props.parts do
				table.insert(out, `{words(p.label)} {M.bytes(number_of(p.bytes) or 0)}`)
			end
			return table.concat(out, ", ")
		end,
		relative = true,
		overflow = "hidden",
		w_full = true,
		h = h,
		rounded = "$radius.full",
		bg = "$naive.switch.track",
		table.unpack(segs),
	}
end

export type LegendProps = { parts: { Part } }

function M.Legend(props: LegendProps): Node
	local items: { Node } = {}
	for i, part in props.parts do
		table.insert(items, ui.row {
			gap = "$space.2",
			items = "center",
			shrink = 0,
			swatch(function(): string
				return color_of(part, i)
			end),
			ui.text { part.label, text_size = "$font.size.sm", line_height = "$font.line.sm", color = "$text.secondary" },
			ui.text {
				function(): string
					return M.bytes(number_of(part.bytes) or 0)
				end,
				text_size = "$font.size.sm",
				line_height = "$font.line.sm",
				color = "$text.tertiary",
				tabular = true,
			},
		})
	end
	return ui.row { w_full = true, gap_x = "$space.4", gap_y = "$space.1", flex_wrap = true, items = "center", table.unpack(items) }
end

export type MeterProps = {
	total: control.Live<number?>,
	caption: Words?,
	parts: { Part },
	trail: (() -> Node)?,
	foot: Node?,
	error: control.Live<string?>?,
	loading: Words?,
	id: string?,
}

local function meter_loading(props: MeterProps): Node
	return ui.column {
		w_full = true,
		gap = "$space.3",
		label = props.loading,
		live = "polite",
		ui.div { h = "$font.line.xl", justify = "center", skeleton.Bar { w = 132, h = 18, rounded = "$radius.md" } },
		skeleton.Bar { w_full = true, h = BAR_H, rounded = "$radius.full" },
		ui.row {
			gap = "$space.4",
			ui.div { h = "$font.line.sm", justify = "center", skeleton.Bar { w = 112, h = 8 } },
			ui.div { h = "$font.line.sm", justify = "center", skeleton.Bar { w = 128, h = 8 } },
			ui.div { h = "$font.line.sm", justify = "center", skeleton.Bar { w = 96, h = 8 } },
		},
	}
end

local function meter_ready(props: MeterProps): Node
	return ui.column {
		w_full = true,
		gap = "$space.3",
		ui.row {
			w_full = true,
			gap = "$space.3",
			items = "center",
			ui.row {
				grow = 1,
				min_w = 0,
				gap = "$space.2",
				items = "baseline",
				ui.text {
					function(): string
						return M.bytes(number_of(props.total) or 0)
					end,
					text_size = "$font.size.xl",
					line_height = "$font.line.xl",
					weight = "$font.weight.semibold",
					color = "$text.primary",
					tabular = true,
				},
				if props.caption
					then ui.text { props.caption, text_size = "$font.size.md", line_height = "$font.line.md", color = "$text.secondary" }
					else nil,
			},
			if props.trail then props.trail() else nil,
		},
		M.Bar { parts = props.parts, id = if props.id then `{props.id}-bar` else nil },
		M.Legend { parts = props.parts },
	}
end

function M.Meter(props: MeterProps): Node
	local function kind(): string
		return if number_of(props.total) == nil then "loading" else "ready"
	end
	local function err(): string?
		local e = control.value(props.error)
		return if type(e) == "string" and e ~= "" then e else nil
	end
	local top = ui.column {
		id = props.id,
		class = "storage-meter",
		w_full = true,
		px = "$space.4",
		pt = "$space.4",
		pb = "$space.4",
		gap = "$space.3",
		ui.presence(kind, function(k: string): Node
			return if k == "loading" then meter_loading(props) else meter_ready(props)
		end, {
			w_full = true,
			enter = { opacity = { 0, 1 }, duration = 120 },
			exit = { opacity = 0, duration = 60 },
			mode = "wait",
		}),
		ui.show(
			function(): boolean
				return err() ~= nil
			end,
			Hint {
				function(): string
					return err() or ""
				end,
				tone = "danger",
			}
		),
	}
	if props.foot then
		return Settings.Group { top, props.foot }
	end
	return Settings.Group { top }
end

function M.Amount(text: () -> string, quiet: (() -> boolean)?): Node
	return ui.text {
		text,
		min_w = AMOUNT_W,
		shrink = 0,
		align = "right",
		text_size = "$font.size.md",
		line_height = "$font.line.md",
		color = function(): string
			return if quiet and quiet() then "$text.tertiary" else "$text.secondary"
		end,
		tabular = true,
	}
end

function M.glyph(name: Icon.Name | () -> Icon.Name, tone: (() -> string?)?): Node
	return ui.row {
		w = TILE,
		h = TILE,
		shrink = 0,
		items = "center",
		justify = "center",
		rounded = "$radius.md",
		bg = function(): string
			local t = if tone then tone() else nil
			return if t then `$naive.tone.{t}.wash` else "$naive.secondary.bg"
		end,
		color = function(): string
			local t = if tone then tone() else nil
			return if t then `$naive.tone.{t}.ink` else "$text.secondary"
		end,
		aria_hidden = true,
		Icon { name = name, size = 16 },
	}
end

export type Flag = { key: string, tone: badge.Tone, n: number? }

local CHAT_FLAG: { [string]: string } = { archived = "archived", deleted = "deleted", none = "no_chat" }

function M.flag(w: Worktree): Flag?
	if w.missing then
		return { key = "missing", tone = "danger" }
	elseif w.dirty then
		return { key = "dirty", tone = "warning" }
	elseif (w.unpushed or 0) > 0 then
		return { key = "unpushed", tone = "warning", n = w.unpushed }
	end
	local chat = CHAT_FLAG[w.chatState]
	return if chat then { key = chat, tone = "neutral" } else nil
end

local function flag_key(w: Worktree): string
	local f = M.flag(w)
	return if f then `{f.key}:{f.n or 0}` else ""
end

function M.Flag(props: { worktree: control.Live<Worktree> }): Node
	local function w(): Worktree
		return control.value(props.worktree) :: Worktree
	end
	return ui.row {
		class = "storage-flag",
		gap = "$space.2",
		items = "center",
		shrink = 0,
		ui.show(function(): boolean
			return w().chatState == "active"
		end, ui.row {
			gap = "$space.1",
			items = "center",
			ui.div { w = 6, h = 6, rounded = "$radius.full", bg = "$naive.tone.success.ink", aria_hidden = true },
			ui.text { locale.t("ds.storage.active"), text_size = "$font.size.sm", line_height = "$font.line.sm", color = "$text.tertiary" },
		}),
		ui.presence(function(): string
			return flag_key(w())
		end, function(k: string): Node
			local f = if k ~= "" then M.flag(w()) else nil
			if not f then
				return ui.div {}
			end
			return badge.Badge {
				if f.n then locale.s(`ds.storage.{f.key}`, { n = f.n }) else locale.t(`ds.storage.{f.key}`) :: any,
				size = "sm",
				tone = f.tone,
			}
		end),
	}
end

local function seconds_since(ms: number?, now: (() -> number)?): number
	local t = if now then now() else os.time()
	return if ms then t - ms / 1000 else 0
end

function M.line(w: Worktree, now: (() -> number)?): string
	local parts: { string } = {}
	if not w.branch then
		table.insert(parts, locale.s("ds.storage.no_branch"))
	elseif w.branch ~= w.name then
		table.insert(parts, w.branch)
	end
	if w.modifiedAt then
		table.insert(parts, locale.s("ds.storage.modified", { ago = locale.ago(seconds_since(w.modifiedAt, now)) }))
	end
	if w.chatTitle and w.chatTitle ~= "" then
		table.insert(parts, w.chatTitle)
	elseif w.chatState ~= "none" then
		table.insert(parts, locale.s("ds.storage.untitled"))
	end
	return table.concat(parts, " · ")
end

export type WorktreeRowProps = {
	worktree: control.Live<Worktree>,
	on_remove: ((w: Worktree) -> ())?,
	now: (() -> number)?,
}

M.WorktreeRow = ui.component(function(props: WorktreeRowProps): Node
	local function w(): Worktree
		return control.value(props.worktree) :: Worktree
	end
	local on_remove = props.on_remove
	local over = ui.use_state(false)
	local focused = ui.use_state(false)
	local function lit(): boolean
		return on_remove ~= nil and (over:get() or focused:get())
	end
	local size = M.Amount(function(): string
		local b = w().bytes
		return if b == nil then locale.s("ds.storage.not_sized") else M.bytes(b)
	end, function(): boolean
		return w().bytes == nil
	end)
	local corner = ui.row {
		relative = true,
		items = "center",
		justify = "end",
		ui.div {
			opacity = function(): number
				return if lit() then 0 else 1
			end,
			pointer_events = "none",
			size,
		},
		if on_remove
			then ui.row {
				absolute = true,
				right = 0,
				top = 0,
				bottom = 0,
				items = "center",
				opacity = function(): number
					return if lit() then 1 else 0
				end,
				IconButton {
					icon = "trash-bin-minimalistic",
					label = function(): string
						return locale.s("ds.storage.remove_for", { name = w().name })
					end,
					tooltip = false,
					size = "md",
					tone = "quiet",
					on_focus = function()
						focused:set(true)
					end,
					on_blur = function()
						focused:set(false)
					end,
					on_click = function()
						on_remove(w())
					end,
				},
			}
			else nil,
	}
	local row = Settings.Row {
		label = function(): string
			return w().name
		end,
		badge = M.Flag { worktree = w },
		lead = M.glyph(function(): Icon.Name
			return if w().missing then "danger-triangle" else "worktree"
		end, function(): string?
			return if w().missing then "danger" else nil
		end),
		description = function(): string
			return M.line(w(), props.now)
		end,
		truncate = true,
		control = corner,
	}
	return ContextMenu {
		label = function(): string
			return w().name
		end,
		w_full = true,
		items = function(): { any }?
			if not on_remove then
				return nil
			end
			return {
				{ label = locale.s("ds.storage.remove_menu"), icon = "trash-bin-minimalistic", danger = true, on_select = function()
					(on_remove :: (w: Worktree) -> ())(w())
				end },
			}
		end,
		Settings.CatalogRow {
			over = over,
			row = ui.div { class = "storage-worktree", role = "group", label = function(): string
				return w().name
			end, w_full = true, row },
		},
	}
end)

export type WorktreesProps = {
	list: State<{ Worktree }?>,
	error: control.Live<string?>?,
	on_remove: ((w: Worktree) -> ())?,
	on_retry: (() -> ())?,
	empty: Words,
	failed: Words,
	loading: Words?,
	now: (() -> number)?,
}

function M.Worktrees(props: WorktreesProps): Node
	local rows = ui.computed(function(): { Worktree }
		return props.list:get() or {}
	end)
	local function err(): string?
		local e = control.value(props.error)
		return if type(e) == "string" and e ~= "" then e else nil
	end
	local function kind(): string
		local list = props.list:get()
		if list then
			return if #list > 0 then "list" else "none"
		elseif err() then
			return "failed"
		end
		return "loading"
	end
	local function body(k: string): Node
		if k == "loading" then
			return ui.column {
				w_full = true,
				label = props.loading or locale.t("common.loading"),
				live = "polite",
				Settings.Group {
					skeleton.Row { lead = TILE, title = 120, line = 240, trail = 56 },
					skeleton.Row { lead = TILE, title = 100, line = 200, trail = 56 },
				},
			}
		elseif k == "failed" then
			return banner.Callout {
				tone = "danger",
				title = props.failed :: any,
				body = function(): string
					return err() or ""
				end,
				action = if props.on_retry then { label = locale.t("common.retry") :: any, on_click = props.on_retry } else nil,
			}
		elseif k == "none" then
			return ui.row { w_full = true, px = Settings.inset(), Hint { props.empty } }
		end
		return Settings.Each(rows, function(_w: Worktree, _i: number, now: State<Worktree>): Node
			return M.WorktreeRow { worktree = now, on_remove = props.on_remove, now = props.now }
		end, {
			key = function(x: Worktree): string
				return x.path
			end,
		})
	end
	return ui.column {
		class = "storage-worktrees",
		w_full = true,
		gap = "$space.2",
		ui.presence(kind, body, {
			w_full = true,
			enter = { opacity = { 0, 1 }, duration = 120 },
			exit = { opacity = 0, duration = 60 },
			mode = "wait",
		}),
		ui.show(function(): boolean
			return props.list:get() ~= nil and err() ~= nil
		end, ui.row {
			w_full = true,
			px = Settings.inset(),
			Hint {
				function(): string
					return err() or ""
				end,
				tone = "danger",
			},
		}),
	}
end

export type ChoiceProps = {
	value: State<boolean>,
	label: Words,
	description: Words?,
	size: (() -> string?)?,
	extra: Node?,
	disabled: (() -> boolean)?,
}

function M.Choice(props: ChoiceProps): Node
	local function off(): boolean
		return props.disabled ~= nil and props.disabled()
	end
	return ui.row {
		class = "storage-choice",
		w_full = true,
		px = "$space.4",
		py = "$space.3",
		gap = "$space.3",
		items = "center",
		ui.presence(function(): string
			return if off() then "off" else "on"
		end, function(k: string): Node
			return ui.div {
				w_full = true,
				Checkbox {
					value = function(): boolean
						return props.value:get() and k == "on"
					end,
					on_change = function(on: boolean)
						props.value:set(on)
					end,
					label = props.label :: any,
					description = props.description :: any,
					disabled = k == "off",
				},
			}
		end, { grow = 1, min_w = 0 }),
		props.extra,
		if props.size
			then ui.show(function(): boolean
				local s = (props.size :: () -> string?)()
				return s ~= nil and s ~= ""
			end, function(): Node
				return M.Amount(function(): string
					return (props.size :: () -> string?)() or ""
				end)
			end)
			else nil,
	}
end

return M
