local data = require("@app/screens/panel/browser_data")

local M = {}

export type Ask = { id: string, key: string, chat: string, host: string, profile: string, title: string?, at: number }

local asks = ui.state("browser_agent_asks", {} :: { Ask })
local once = ui.state("browser_agent_once", {} :: { [string]: boolean })
local seq = 0

M.asks = asks

local function once_key(chat: string, site: string): string
	return `{chat}\n{site}`
end

function M.allowed_once(chat: string, site: string): boolean
	return once:peek()[once_key(chat, site)] == true
end

function M.find(id: string): Ask?
	for _, a in asks:peek() do
		if a.id == id then
			return a
		end
	end
	return nil
end

function M.add(key: string, chat: string, host: string, profile: string, title: string?): Ask
	for _, a in asks:peek() do
		if a.key == key and a.chat == chat and a.host == host then
			return a
		end
	end
	seq += 1
	local ask: Ask = { id = `ask-{math.floor(ui.now())}-{seq}`, key = key, chat = chat, host = host, profile = profile, title = title, at = ui.now() }
	asks:push(ask)
	return ask
end

function M.first(key: string): Ask?
	for _, a in asks:get() do
		if a.key == key then
			return a
		end
	end
	return nil
end

function M.waiting(key: string): number
	local n = 0
	for _, a in asks:get() do
		if a.key == key then
			n += 1
		end
	end
	return n
end

function M.drop(id: string)
	local now = {}
	for _, a in asks:peek() do
		if a.id ~= id then
			table.insert(now, a)
		end
	end
	asks:set(now)
end

function M.answer(id: string, choice: string)
	local a = M.find(id)
	if not a then
		return
	end
	if choice == "always" then
		data.agents.set(a.profile, a.host, "allow")
	elseif choice == "block" then
		data.agents.set(a.profile, a.host, "block")
	elseif choice == "once" then
		once:set_key(once_key(a.chat, a.host), true)
	end
	M.drop(id)
end

function M.expire(older_than_ms: number)
	local now = ui.now()
	for _, a in asks:peek() do
		if now - a.at > older_than_ms then
			M.drop(a.id)
		end
	end
end

return M
