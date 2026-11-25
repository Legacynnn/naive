local state = require("@app/screens/panel/state")
local api = require("@app/screens/panel/browser_api")
local Browser = require("@app/screens/panel/browser")
local data = require("@app/screens/panel/browser_data")
local view = require("@app/screens/shell/view")
local route = require("@app/screens/shell/route")
local worktree = require("@app/screens/shell/worktree")

local calls = ui.shared("browser_agent_calls", {} :: { any })
local seen = ui.state("browser_agent_seen", {} :: { [string]: boolean })

local LOAD_MS = 30000
local START_MS = 5000
local SETTLE_MS = 400
local EVAL_MS = 15000
local CALL_MS = 55000

-- A name a page can't guess, so it can't stand in for the agent's script.
local AGENT = string.format("__naiveAgent_%x%x", math.random(0, 0x7fffffff), math.floor(ui.now()) % 0x7fffffff)
local SCRIPT = (string.gsub(require("@app/screens/panel/agent_script"), "__naiveAgent", AGENT))

type Ctx = { chat: string, key: string }
type Done = (ok: boolean, value: any) -> ()

local function answer(id: string, ok: boolean, value: any)
	if ok then
		ui.invoke("browser_agent.answer", { id = id, ok = true, value = value })
	else
		ui.invoke("browser_agent.answer", { id = id, ok = false, error = tostring(value) })
	end
end

local function browser_tabs(key: string): { any }
	local out = {}
	for _, t in state.of(key).tabs do
		if t.kind == "browser" then
			table.insert(out, t)
		end
	end
	return out
end

local function find_tab(key: string, id: string?): any?
	local tabs = browser_tabs(key)
	if id then
		for _, t in tabs do
			if t.id == id then
				return t
			end
		end
		error(`No browser tab {id} in this chat: browser_tabs lists them`)
	end
	local s = state.of(key)
	for _, t in tabs do
		if t.id == s.active then
			return t
		end
	end
	for _, visited in s.visited do
		for _, t in tabs do
			if t.id == visited then
				return t
			end
		end
	end
	return tabs[#tabs]
end

local function reveal(ctx: Ctx, tab: any)
	state.activate(ctx.key, tab.id)
	local here = route.chat:peek()
	if here and here.name == "session" and here.session == ctx.chat then
		if not view.files:peek() then
			view.set_files(true)
		end
		return
	end
	local tree = if worktree.on:peek() then worktree.of(ctx.chat, true) else nil
	local owner = if tree then `worktree:{tree}` else ctx.chat
	if not view.panels:peek()[owner] then
		view.panels:set_key(owner, true)
	end
end

local function page_of(ctx: Ctx, tab: any): any
	local web = Browser.page(tab.id)
	if not web then
		error("The browser isn't ready yet: try again in a moment")
	end
	reveal(ctx, tab)
	return web
end

local function describe(key: string, tab: any): { [string]: any }
	local web = Browser.page(tab.id)
	local url = if web and type(web.url) == "string" and web.url ~= "" then web.url else tab.url
	return {
		id = tab.id,
		url = url,
		title = if web and type(web.title) == "string" and web.title ~= "" then web.title else Browser.title(tab),
		active = state.of(key).active == tab.id,
		loading = web ~= nil and web.loading == true,
	}
end

-- Waits for a load to begin (loading seen or the address moved), then to finish; none begun settles after `grace`.
local function settle(web: any, done: Done, from_url: any, delay: number?, grace: number?)
	local start = ui.now()
	local begun = false
	ui.after(delay or 50, function()
		ui.every(100, function()
			local now = ui.now() - start
			if web.loading == true or web.url ~= from_url then
				begun = true
			end
			if (begun or now > (grace or START_MS)) and web.loading ~= true then
				done(true, { url = web.url, title = web.title })
				return false
			end
			if now > LOAD_MS then
				done(false, `The page is still loading after {LOAD_MS // 1000} s`)
				return false
			end
			return true
		end)
	end)
end

local function safely(cb: Done): Done
	return function(ok: boolean, value: any)
		local fine, why = pcall(cb, ok, value)
		if not fine and ok then
			pcall(cb, false, why)
		end
	end
end

local function run(web: any, fn: string, args: any, given_done: Done)
	local done = safely(given_done)
	local js = `{SCRIPT}\n;window.{AGENT}.{fn}({ui.json.encode(args or {})})`
	local over = false
	ui.after(EVAL_MS, function()
		if not over then
			over = true
			done(false, "The page isn't showing in Naive, so it can't run: open this chat in Naive's window and try again")
		end
	end)
	web:eval(js, function(value: any, err: string?)
		if over then
			return
		end
		over = true
		if err then
			done(false, err)
		else
			done(true, value)
		end
	end)
end

local function open(ctx: Ctx, url: string?): any
	if not data.profile() then
		error("The browser isn't ready yet: try again in a moment")
	end
	local id = state.open(ctx.key, "browser", if url then { url = url } else nil)
	return state.find(ctx.key, id)
end

local function normalized(text: string): string
	local url, why = api.normalize(text)
	if not url then
		error(if why then ui.t(why):get() else `Not an address: {text}`)
	end
	if not api.allowed(url) then
		error(`Only http(s) addresses: {text}`)
	end
	return url
end

local function with_tab(value: any, tab: any): any
	local out = if type(value) == "table" then table.clone(value) else { value = value }
	out.tab = tab.id
	return out
end

local tools: { [string]: (ctx: Ctx, args: any, done: Done) -> () } = {}

tools.browser_tabs = function(ctx, args, done)
	local action = args.action or "list"
	if action == "open" then
		local url = if type(args.url) == "string" and args.url ~= "" then normalized(args.url) else nil
		local tab = open(ctx, url)
		local web = page_of(ctx, tab)
		if url then
			local from = web.url
			web:load(url)
			settle(web, function()
				done(true, describe(ctx.key, tab))
			end, from)
		else
			done(true, describe(ctx.key, tab))
		end
		return
	end
	if action == "select" or action == "close" then
		local tab = find_tab(ctx.key, args.tab)
		if not tab then
			error("This chat has no browser tab")
		end
		if action == "select" then
			page_of(ctx, tab)
		else
			Browser.close(tab)
			state.close(ctx.key, tab.id)
		end
	end
	local out = {}
	for _, t in browser_tabs(ctx.key) do
		table.insert(out, describe(ctx.key, t))
	end
	done(true, { tabs = out })
end

tools.browser_navigate = function(ctx, args, done)
	local target = tostring(args.url or "")
	local moves = target == "back" or target == "forward" or target == "reload"
	local url = if moves then nil else normalized(target)
	local tab = find_tab(ctx.key, args.tab)
	if not tab then
		if moves then
			error("This chat has no browser tab")
		end
		tab = open(ctx, nil)
	end
	local web = page_of(ctx, tab)
	local from = web.url
	if target == "back" then
		web:back()
	elseif target == "forward" then
		web:forward()
	elseif target == "reload" then
		from = nil
		web:reload()
	elseif url then
		state.set_url(ctx.key, tab.id, url)
		web:load(url)
	end
	settle(web, function(ok, value)
		if not ok then
			done(false, value)
			return
		end
		-- Hooks the page's console as early as the agent can.
		run(web, "page", {}, function() end)
		done(true, with_tab(value, tab))
	end, from)
end

local function on_page(fn: string, after_ms: number?)
	return function(ctx, args, done)
		local tab = find_tab(ctx.key, args.tab)
		if not tab then
			error("This chat has no browser tab: browser_navigate opens one")
		end
		local web = page_of(ctx, tab)
		local given = table.clone(args)
		given.tab = nil
		local from = web.url
		run(web, fn, given, function(ok, raw)
			if not ok then
				done(false, raw)
				return
			end
			local value = with_tab(raw, tab)
			if not after_ms then
				done(true, value)
				return
			end
			settle(web, function(settled, now)
				if settled and type(now) == "table" then
					value.url, value.title = now.url, now.title
				end
				done(true, value)
			end, from, after_ms, after_ms)
		end)
	end
end

tools.browser_snapshot = on_page("snapshot")
tools.browser_click = on_page("click", SETTLE_MS)
tools.browser_type = on_page("type", SETTLE_MS)
tools.browser_key = on_page("key", SETTLE_MS)
tools.browser_scroll = on_page("scroll")
tools.browser_console = on_page("console")

tools.browser_screenshot = function(ctx, args, done)
	local tab = find_tab(ctx.key, args.tab)
	if not tab then
		error("This chat has no browser tab: browser_navigate opens one")
	end
	local web = page_of(ctx, tab)
	if type((web :: any).snapshot) ~= "function" then
		error("This Naive's zgx can't take a page's picture")
	end
	local start = ui.now()
	local function try()
		web:snapshot(function(jpeg: string?, err: string?)
			if jpeg then
				done(true, { jpeg = jpeg, url = web.url, title = web.title, tab = tab.id })
			elseif ui.now() - start < EVAL_MS then
				ui.after(250, try)
			else
				done(false, `No picture of the page: {err or "it isn't showing"}. Open this chat in Naive's window and try again`)
			end
		end)
	end
	ui.after(SETTLE_MS, try)
end

tools.browser_wait = function(ctx, args, done)
	local tab = find_tab(ctx.key, args.tab)
	if not tab then
		error("This chat has no browser tab")
	end
	local web = page_of(ctx, tab)
	local limit = math.clamp(tonumber(args.timeout) or 10000, 100, 30000)
	local start = ui.now()
	local asking = false
	local finished = false
	local last_error: string? = nil
	ui.every(200, function()
		if finished then
			return false
		end
		if asking then
			return true
		end
		if ui.now() - start > limit then
			finished = true
			done(false, if last_error then `Not there after {limit} ms: {last_error}` else `Not there after {limit} ms`)
			return false
		end
		if web.loading == true then
			return true
		end
		asking = true
		run(web, "found", { text = args.text, selector = args.selector }, function(ok, value)
			asking = false
			if not ok then
				last_error = tostring(value)
			elseif value == true and not finished then
				finished = true
				done(true, { url = web.url, title = web.title, tab = tab.id })
			end
		end)
		return true
	end)
end

tools.terminal_show = function(ctx, args, done)
	if type(args.terminal) ~= "string" or args.terminal == "" then
		error("No terminal to show")
	end
	local title = if type(args.title) == "string" and args.title ~= "" then args.title else nil
	local id = state.open(ctx.key, "terminal", { title = title })
	state.set_terminal(ctx.key, id, args.terminal, nil, nil)
	local tab = state.find(ctx.key, id)
	if tab then
		reveal(ctx, tab)
	end
	done(true, { tab = id })
end

local function handle(call: any)
	local id: string = call.id
	local fn = tools[call.tool]
	local answered = false
	local function done(ok: boolean, value: any)
		if answered then
			return
		end
		answered = true
		local sent, why = pcall(answer, id, ok, value)
		if not sent then
			pcall(answer, id, false, `The browser's answer couldn't be sent: {why}`)
		end
	end
	ui.after(CALL_MS, function()
		done(false, `The browser didn't finish {call.tool} in {CALL_MS // 1000} s`)
	end)
	if not fn then
		done(false, `Unknown browser tool {call.tool}`)
		return
	end
	if type(call.chat) ~= "string" or call.chat == "" then
		done(false, "Browser tools work from a Naive chat: this agent has no chat")
		return
	end
	local key = state.key(call.chat, nil)
	if not key then
		done(false, "No panel for this chat")
		return
	end
	local ctx: Ctx = { chat = call.chat, key = key }
	local ok, err = pcall(fn, ctx, if type(call.args) == "table" then call.args else {}, done)
	if not ok then
		done(false, (string.gsub(tostring(err), "^[^\n]-:%d+: ", "")))
	end
end

ui.every(150, function()
	local now = calls:peek() or {}
	local live: { [string]: boolean } = {}
	local was = seen:peek()
	for _, call in now do
		if type(call) == "table" and type(call.id) == "string" then
			live[call.id] = true
			if not was[call.id] then
				seen:set_key(call.id, true)
				handle(call)
			end
		end
	end
	for id in was do
		if not live[id] then
			seen:set_key(id, nil)
		end
	end
	return true
end)

return {}
