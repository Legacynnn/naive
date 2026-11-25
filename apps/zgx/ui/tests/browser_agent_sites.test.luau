local function said(app: any): string
	return app:tree("#policy")
end

local function has(app: any, text: string): boolean
	return said(app):find(text, 1, true) ~= nil
end

test("agents on sites: decisions cover the site and its subdomains, per profile", function()
	local app = mount("browser_policy_fixture.luau")
	app:frames(2)
	expect(has(app, "naive-a example.com=ask;")).to_be(true)
	app:set_state("browser_agent_sites", {
		["naive-a"] = { ["example.com"] = "allow", ["accounts.google.com"] = "block", ["google.com"] = "allow" },
	})
	app:frames(2)
	for _, line in {
		"naive-a example.com=allow;",
		"naive-a www.example.com=allow;",
		"naive-a docs.example.com=allow;",
		"naive-a a.b.example.com=allow;",
		"naive-a notexample.com=ask;",
		"naive-a mail.google.com=allow;",
		"naive-a accounts.google.com=block;",
		"naive-a com=ask;",
		"naive-a localhost=ask;",
		"naive-b example.com=ask;",
		"naive-b docs.example.com=ask;",
		"naive-a list=accounts.google.com:block,example.com:allow,goo",
		"site=example.com",
	} do
		expect(if has(app, line) then line else said(app)).to_be(line)
	end
end)

test("agents on sites: the default, a block over it, set and forget", function()
	local app = mount("browser_policy_fixture.luau")
	app:frames(2)
	app:set_state("browser_agent_default", { ["naive-b"] = "allow" })
	app:set_state("browser_agent_sites", { ["naive-b"] = { ["docs.example.com"] = "block" } })
	app:frames(2)
	expect(has(app, "naive-b example.com=allow;")).to_be(true)
	expect(has(app, "naive-b docs.example.com=block;")).to_be(true)
	expect(has(app, "naive-a example.com=ask;")).to_be(true)
	app:command("policy_fixture.set")
	app:frames(2)
	expect(has(app, "naive-b list=docs.example.com:block,github.com:block")).to_be(true)
	app:command("policy_fixture.forget")
	app:frames(2)
	expect(has(app, "naive-b list=docs.example.com:block")).to_be(true)
	expect(has(app, "github.com")).to_be(false)
end)

local function panel(): any
	local app = mount("panel_fixture.luau")
	app:resize(900, 640)
	app:frames(10)
	expect(app:wait("#panel-empty", { timeout_ms = 15000 })).to_be(true)
	app:click("#panel-open-browser")
	expect(app:wait('role:combobox "Address"', { timeout_ms = 15000 })).to_be(true)
	return app
end

local function ask(id: string, key: string, chat: string, host: string, title: string?): any
	return { id = id, key = key, chat = chat, host = host, profile = "naive-local", title = title, at = 0 }
end

test("agents on sites: the browser tab asks, one chat's question at a time, and the answer is kept", function()
	local app = panel()
	app:set_state("browser_agent_asks", {
		ask("ask-1", "chat:chat-1", "chat-1", "example.com", "Fix the login"),
		ask("ask-2", "chat:chat-2", "chat-2", "other.com", "Elsewhere"),
		ask("ask-3", "chat:chat-1", "chat-1", "github.com", nil),
	})
	app:frames(10)
	expect(app:has('"An agent in Fix the login wants to use example.com"')).to_be(true)
	expect(app:has('"An agent in Elsewhere wants to use other.com"')).to_be(false)
	expect(app:has('role:button "Allow once"')).to_be(true)
	app:click('role:button "Always allow"')
	app:frames(10)
	local sites = app:state("browser_agent_sites") :: any
	expect(sites["naive-local"]["example.com"]).to_be("allow")
	expect(app:has('"An agent in this chat wants to use github.com"')).to_be(true)
	app:click('role:button "Allow once"')
	app:frames(10)
	local once = app:state("browser_agent_once") :: any
	expect(once["chat-1\ngithub.com"]).to_be(true)
	expect(sites["naive-local"]["github.com"]).to_be_nil()
	local left = app:state("browser_agent_asks") :: any
	expect(#left).to_be(1)
	expect(left[1].id).to_be("ask-2")
	expect(app:has("role:button \"Block\"")).to_be(false)
	expect(app:error()).to_be_nil()
end)

test("agents on sites: Settings → Browser lists the decided sites, each changed or forgotten in place", function()
	local app = mount("shell_fixture.luau")
	app:resize(1200, 900)
	app:frames(30)
	app:command("settings_stub.sign_in")
	app:command("shell.settings")
	app:frames(20)
	app:click('#settings-nav >> role:tab "Browsing"')
	app:frames(30)
	local page = "#settings-page"
	expect(app:has(`{page} >> "Agents on sites"`)).to_be(true)
	expect(app:has(`{page} >> "Agents on a new site"`)).to_be(true)
	expect(app:has("#settings-browser-agent-sites")).to_be(false)
	app:set_state("browser_agent_sites", { ["naive-user_ada"] = { ["example.com"] = "allow", ["bank.com"] = "block" } })
	app:frames(20)
	expect(app:has(`{page} >> "2 sites decided"`)).to_be(true)
	expect(app:has(`{page} >> "example.com"`)).to_be(true)
	app:click(`{page} >> role:button "Block agents on example.com"`)
	app:frames(10)
	local sites = app:state("browser_agent_sites") :: any
	expect(sites["naive-user_ada"]["example.com"]).to_be("block")
	app:click(`{page} >> role:button "Forget bank.com"`)
	app:frames(10)
	sites = app:state("browser_agent_sites") :: any
	expect(sites["naive-user_ada"]["bank.com"]).to_be_nil()
	expect(app:has(`{page} >> "1 site decided"`)).to_be(true)
	app:set_state("browser_agent_default", { ["naive-user_ada"] = "allow" })
	app:frames(10)
	expect(app:state("settings_browser_agent_default")).to_be("allow")
	expect(app:error()).to_be_nil()
end)
