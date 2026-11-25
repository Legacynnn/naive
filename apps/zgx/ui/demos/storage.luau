local ds = require("@ds")
local storage = require("@ds/storage")
local kit = require("@demos/kit")

local GB = 1024 * 1024 * 1024
local MB = 1024 * 1024

type Worktree = storage.Worktree

local function ago(seconds: number): number
	return (os.time() - seconds) * 1000
end

local WORKTREES: { Worktree } = {
	{ path = "~/.naive/worktrees/naive/storage-cleanup", repoPath = "~/www/naive", project = "naive", name = "storage-cleanup", branch = "storage-cleanup", bytes = math.floor(3.4 * GB), modifiedAt = ago(1200), chatId = "c1", chatTitle = "Storage settings page", chatState = "active", dirty = true, unpushed = 2, missing = false },
	{ path = "~/.naive/worktrees/naive/sidebar-rows", repoPath = "~/www/naive", project = "naive", name = "sidebar-rows", branch = "sidebar-rows", bytes = math.floor(2.1 * GB), modifiedAt = ago(9 * 86400), chatId = "c2", chatTitle = "Worktree rows in the sidebar", chatState = "archived", dirty = false, unpushed = 0, missing = false },
	{ path = "~/.naive/worktrees/naive/fix-paste", repoPath = "~/www/naive", project = "naive", name = "fix-paste", branch = "fix-paste", bytes = math.floor(1.8 * GB), modifiedAt = ago(21 * 86400), chatId = "c3", chatTitle = "", chatState = "deleted", dirty = false, unpushed = 0, missing = false },
	{ path = "~/.naive/worktrees/analytical-engine/notes", repoPath = "~/code/analytical-engine", project = "analytical-engine", name = "notes", branch = "notes", bytes = 412 * MB, modifiedAt = ago(3 * 86400), chatState = "none", dirty = false, unpushed = 1, missing = false },
	{ path = "~/.naive/worktrees/analytical-engine/old-parser", repoPath = "~/code/analytical-engine", project = "analytical-engine", name = "old-parser", chatState = "none", dirty = false, missing = true },
}

local list = ui.state("sto_list", table.clone(WORKTREES) :: { Worktree }?)
local loading = ui.state("sto_loading", nil :: { Worktree }?)
local empty = ui.state("sto_empty", {} :: { Worktree }?)
local stale = ui.state("sto_stale", { WORKTREES[2] } :: { Worktree }?)
local days = ui.state("sto_days", 30)
local pick_stale = ui.state("sto_pick_stale", true)
local pick_archived = ui.state("sto_pick_archived", false)
local pick_updates = ui.state("sto_pick_updates", true)

local function parts(worktrees: number, journals: number, app: number): { storage.Part }
	return {
		{ label = "Worktrees", bytes = worktrees },
		{ label = "Chat history", bytes = journals },
		{ label = "App data", bytes = app, color = "$text.tertiary" },
	}
end

local function remove(w: Worktree)
	local now = list:peek() or {}
	local out = {}
	for _, x in now do
		if x.path ~= w.path then
			table.insert(out, x)
		end
	end
	list:set(out)
end

return {
	id = "storage",
	title = "Storage",
	about = "What Naive keeps on disk: a total and its split as one stacked bar with its legend and the one way to free space under it, rows that drill into a project or app data, worktrees with the one flag that matters most, and the choices freeing space offers.",
	demo = function(): Node
		local total = math.floor(7.3 * GB) + 264 * MB + 605 * MB
		return ui.column {
			w = 640,
			gap = "$space.6",
			kit.block(
				"METER",
				storage.Meter {
					id = "storage-meter-full",
					total = total,
					caption = "used",
					parts = parts(math.floor(7.3 * GB), 264 * MB, 605 * MB),
					trail = function(): Node
						return ui.row {
							gap = "$space.1",
							items = "center",
							ui.text { "Computed 5 minutes ago", text_size = "$font.size.sm", color = "$text.tertiary" },
							ds.IconButton { icon = "refresh", label = "Refresh", size = "md", tone = "quiet" },
						}
					end,
					foot = ds.Settings.Row {
						label = "Free up 4.7 GB",
						description = "Stale worktrees, leftover chat data and update files",
						lead = ds.ProviderCard.disc(ds.Icon { name = "magic-stick", size = 16 }, "accent"),
						on_click = function() end,
					},
				},
				storage.Meter {
					id = "storage-meter-lopsided",
					total = 2 * GB,
					caption = "used",
					parts = parts(0, 2 * MB, 2 * GB - 2 * MB),
					error = "Couldn't reach the engine. These are the last sizes measured.",
				},
				storage.Meter {
					total = function(): number?
						return nil
					end,
					parts = parts(0, 0, 0),
					loading = "Measuring Naive's folders. This can take a few seconds.",
				}
			),
			kit.block(
				"ROWS",
				ds.Settings.Group {
					ds.Settings.Row {
						label = "naive",
						description = "3 worktrees",
						value = "7.5 GB",
						lead = ds.Tile { label = "naive", hue = "violet", size = storage.TILE },
						truncate = true,
						on_click = function() end,
					},
					ds.Settings.Row {
						label = "App data",
						description = "Updates, plugins, logs and uploads",
						value = "605 MB",
						lead = storage.glyph("settings-minimalistic"),
						truncate = true,
						on_click = function() end,
					},
					ds.Settings.Row {
						label = "Logs",
						description = "What Naive and its engine wrote down as they ran",
						truncate = true,
						control = storage.Amount(function(): string
							return "96 MB"
						end),
					},
				}
			),
			kit.block(
				"WORKTREES",
				storage.Worktrees {
					list = list,
					on_remove = remove,
					empty = "No worktrees on this computer.",
					failed = "Couldn't list the worktrees",
				},
				kit.row(ds.Button {
					"Bring them back",
					size = "sm",
					tone = "secondary",
					on_click = function()
						list:set(table.clone(WORKTREES))
					end,
				})
			),
			kit.block(
				"WORKTREES: LOADING, EMPTY, FAILED, STALE",
				storage.Worktrees { list = loading, empty = "No worktrees on this computer.", failed = "Couldn't list the worktrees" },
				storage.Worktrees { list = empty, empty = "No worktrees on this computer.", failed = "Couldn't list the worktrees" },
				storage.Worktrees {
					list = loading,
					error = "Naive's engine isn't running.",
					on_retry = function() end,
					empty = "No worktrees on this computer.",
					failed = "Couldn't list the worktrees",
				},
				storage.Worktrees {
					list = stale,
					error = "Couldn't refresh. These may be out of date.",
					on_remove = function() end,
					empty = "No worktrees on this computer.",
					failed = "Couldn't list the worktrees",
				}
			),
			kit.block(
				"FREE UP CHOICES",
				ds.Settings.Group {
					storage.Choice {
						value = pick_stale,
						label = "3 stale worktrees",
						description = "No chat, or its chat archived or deleted. Uncommitted work is kept.",
						size = function(): string?
							return "4.3 GB"
						end,
					},
					storage.Choice {
						value = pick_archived,
						label = "Chats archived more than",
						description = "Deleted for good with their history, on every device.",
						extra = ds.Select {
							value = days,
							name = "Archived more than",
							size = "sm",
							w = 104,
							options = { { value = 7, label = "7 days" }, { value = 30, label = "30 days" }, { value = 90, label = "90 days" } },
						},
					},
					storage.Choice {
						value = pick_updates,
						label = "Downloaded update files",
						description = "Installed or no longer needed. One waiting to install is kept.",
						disabled = function(): boolean
							return true
						end,
					},
				}
			),
		}
	end,
}
