local sessions = require("@account/sessions")
local SessionRow = require("@ds/session_row")
local terminal_agents = require("@app/screens/shell/terminal_agents")

local M = {}

export type Worktree = {
	key: string,
	project: string?,
	device: string,
	cwd: string?,
	branch: string?,
	main: boolean,
	lead: string,
	chats: { sessions.Chat },
	updated: number,
	created: number,
}

M.enabled = ui.persist("shell_sidebar_worktrees", true)
-- Only a layout with the header's tabs (Zeron v3) can reach a worktree's other chats.
M.capable = ui.shared("shell.session_tabs", false)
M.off = ui.shared("shell.worktrees_off", false)
M.on = ui.computed(function(): boolean
	return M.enabled:get() and M.capable:get() and not M.off:get()
end)
M.sort = ui.persist("shell_tabs_sort", "manual")
M.last = ui.persist("shell_worktree_last", {} :: { [string]: string })
M.titles = ui.persist("shell_worktree_titles", {} :: { [string]: string })

local function trimmed(path: string?): string?
	if not path or path == "" then
		return nil
	end
	return (string.gsub(path, "/+$", ""))
end

local function projects_by_id(): { [string]: sessions.Project }
	local out: { [string]: sessions.Project } = {}
	for _, p in sessions.projects:get() do
		out[p.id] = p
	end
	return out
end

local function is_linked(cwd: string?, project: sessions.Project?): boolean
	if not cwd then
		return false
	end
	if string.find(cwd, "/.zeron/worktrees/", 1, true) then
		return true
	end
	local root = if project then trimmed(project.path) else nil
	if not root then
		return false
	end
	return cwd ~= root and string.sub(cwd, 1, #root + 1) ~= root .. "/"
end

function M.key_of(c: sessions.Chat, by: { [string]: sessions.Project }?): string
	if not c.project then
		return `chat:{c.id}`
	end
	local p = (by or projects_by_id())[c.project]
	local cwd = trimmed(c.cwd)
	if is_linked(cwd, p) then
		return `{c.device}:{cwd}`
	end
	return `{c.device}:project:{c.project}`
end

M.all = ui.computed(function(): { [string]: Worktree }
	local by = projects_by_id()
	local out: { [string]: Worktree } = {}
	local all = table.clone(sessions.chats:get())
	for _, c in terminal_agents.chats:get() do
		table.insert(all, c)
	end
	for _, c in all do
		local key = M.key_of(c, by)
		local w = out[key]
		if not w then
			local p = if c.project then by[c.project] else nil
			local cwd = trimmed(c.cwd)
			w = {
				key = key,
				project = c.project,
				device = c.device,
				cwd = if is_linked(cwd, p) then cwd else (if p then trimmed(p.path) else cwd),
				branch = c.branch,
				main = not is_linked(cwd, p),
				lead = c.id,
				chats = {},
				updated = 0,
				created = c.created,
			}
			out[key] = w
		end
		table.insert(w.chats, c)
		if c.created < w.created then
			w.created = c.created
			w.lead = c.id
		end
		if c.updated > w.updated then
			w.updated = c.updated
			if c.branch then
				w.branch = c.branch
			end
		end
	end
	for _, w in out do
		table.sort(w.chats, function(a, b)
			if a.created ~= b.created then
				return a.created < b.created
			end
			return a.id < b.id
		end)
	end
	return out
end)

M.by_chat = ui.computed(function(): { [string]: string }
	local out: { [string]: string } = {}
	for key, w in M.all:get() do
		for _, c in w.chats do
			out[c.id] = key
		end
	end
	return out
end)

function M.of(id: string?, peek: boolean?): string?
	if not id then
		return nil
	end
	return (if peek then M.by_chat:peek() else M.by_chat:get())[id]
end

function M.get(key: string?): Worktree?
	if not key then
		return nil
	end
	return M.all:get()[key]
end

function M.title(w: Worktree, project_name: string?): string
	local own = M.titles:get()[w.key]
	if own and own ~= "" then
		return own
	end
	if w.main then
		return w.branch or project_name or ""
	end
	for _, c in w.chats do
		if c.id == w.lead then
			return if c.title ~= "" then c.title else (w.branch or "")
		end
	end
	return w.branch or ""
end

function M.rename(key: string, title: string?)
	local next = table.clone(M.titles:peek())
	next[key] = if title and title ~= "" then title else nil
	M.titles:set(next)
end

function M.pressing(w: Worktree, asked: { [string]: string }?): string?
	local list: { any } = {}
	for _, c in w.chats do
		local s = c.status
		local a = asked and asked[c.id]
		if a == "approval" then
			s = "approval"
		elseif a == "question" then
			s = "input"
		end
		table.insert(list, { status = s })
	end
	return SessionRow.pressing(list :: any)
end

function M.working(w: Worktree): number
	local n = 0
	for _, c in w.chats do
		if c.status == "working" or c.status == "waiting" then
			n += 1
		end
		n += (c.running_subagents or 0) + (c.working_side_chats or 0)
	end
	return n
end

function M.remember(id: string)
	local key = M.by_chat:peek()[id]
	if not key then
		return
	end
	local last = M.last:peek()
	if last[key] ~= id then
		local next = table.clone(last)
		next[key] = id
		M.last:set(next)
	end
end

function M.resume(key: string): string?
	local w = M.all:peek()[key]
	if not w then
		return nil
	end
	local id = M.last:peek()[key]
	for _, c in w.chats do
		if c.id == id then
			return id
		end
	end
	local best: sessions.Chat? = nil
	for _, c in w.chats do
		if not best or c.updated > best.updated then
			best = c
		end
	end
	return if best then best.id else w.lead
end

return M
