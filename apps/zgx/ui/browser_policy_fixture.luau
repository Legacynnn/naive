ui.theme.strict("warn")
local ds = require("@ds")
ds.setup()
local data = require("@app/screens/panel/browser_data")

local CASES = {
	{ "naive-a", "example.com" },
	{ "naive-a", "www.example.com" },
	{ "naive-a", "docs.example.com" },
	{ "naive-a", "a.b.example.com" },
	{ "naive-a", "notexample.com" },
	{ "naive-a", "mail.google.com" },
	{ "naive-a", "accounts.google.com" },
	{ "naive-a", "com" },
	{ "naive-a", "localhost" },
	{ "naive-b", "example.com" },
	{ "naive-b", "docs.example.com" },
}

ui.command {
	id = "policy_fixture.set",
	title = "Block github.com for naive-b",
	run = function()
		data.agents.set("naive-b", "WWW.GitHub.com", "block")
	end,
}
ui.command {
	id = "policy_fixture.forget",
	title = "Forget github.com for naive-b",
	run = function()
		data.agents.forget("naive-b", "github.com")
	end,
}

local lines: { Node } = {}
for _, c in CASES do
	table.insert(lines, ui.text {
		function(): string
			return `{c[1]} {c[2]}={data.agents.policy(c[1], c[2])};`
		end,
		literal = true,
	})
end
for _, p in { "naive-a", "naive-b" } do
	table.insert(lines, ui.text {
		function(): string
			local sites = {}
			for _, s in data.agents.list(p) do
				table.insert(sites, `{s.host}:{s.decision}`)
			end
			return `{p} list={table.concat(sites, ",")};`
		end,
		literal = true,
	})
end
table.insert(lines, ui.text { `site={data.agents.site_of("https://WWW.Example.com:8443/path?q=1") or "nil"}`, literal = true })

return ui.column {
	id = "policy",
	table.unpack(lines),
}
