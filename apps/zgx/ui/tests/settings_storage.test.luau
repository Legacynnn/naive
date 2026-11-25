local PAGE = "#settings-page"
local NAV = "#settings-nav"

local function open(): any
	local app = mount("shell_fixture.luau")
	app:resize(1200, 2400)
	app:frames(30)
	app:command("settings_stub.sign_in")
	app:command("shell.settings")
	app:frames(20)
	app:click(`{NAV} >> role:tab "Storage"`)
	app:frames(30)
	return app
end

local function shows(app: any, text: string): boolean
	return app:tree(PAGE):find(text, 1, true) ~= nil
end

local function asked(app: any, entry: string): number
	local n = 0
	for _, c in (app:state("settings_stub_calls") :: any) or {} do
		if c == entry then
			n += 1
		end
	end
	return n
end

local function into(app: any, row: string): any
	app:click(`{PAGE} >> role:button "{row}"`)
	app:frames(30)
	return app
end

test("shows the total, what frees space, and each project largest first with app data", function()
	local app = open()
	expect(asked(app, "settings.engine:GetStorageUsage")).to_be(1)
	expect(asked(app, "settings.engine:ListStorageWorktrees")).to_be(1)
	expect(shows(app, "Computed 5 minutes ago")).to_be(true)
	expect(app:has(`{PAGE} >> role:img "Worktrees 7.7 GB, Chat history 264 MB, App data 605 MB"`)).to_be(true)
	expect(app:has(`{PAGE} >> role:button "Free up 4.7 GB"`)).to_be(true)
	local tree = app:tree(PAGE)
	local naive = tree:find('"naive"', 1, true)
	local engine = tree:find('"analytical-engine"', 1, true)
	expect(naive ~= nil and engine ~= nil and naive < engine).to_be(true)
	expect(shows(app, "3 worktrees")).to_be(true)
	expect(shows(app, "No worktrees")).to_be(true)
	expect(app:has(`{PAGE} >> role:button "App data"`)).to_be(true)
	expect(shows(app, "storage-cleanup")).to_be(false)
	expect(shows(app, "Downloaded updates")).to_be(false)
end)

test("a project opens on its worktrees, each with the one flag that matters most", function()
	local app = into(open(), "naive")
	expect(shows(app, "~/www/naive")).to_be(true)
	expect(shows(app, "storage-cleanup")).to_be(true)
	expect(shows(app, "Uncommitted changes")).to_be(true)
	expect(shows(app, "2 unpushed commits")).to_be(false)
	expect(shows(app, "In use")).to_be(true)
	expect(shows(app, "Chat archived")).to_be(true)
	expect(shows(app, "Worktree rows in the sidebar")).to_be(true)
	expect(shows(app, "Chat history")).to_be(true)
	expect(shows(app, "analytical-engine")).to_be(false)
	app:click(`{PAGE} >> role:button "Back to Storage"`)
	app:frames(30)
	expect(app:has(`{PAGE} >> role:button "App data"`)).to_be(true)
end)

test("a missing folder outranks every other flag", function()
	local app = into(open(), "analytical-engine")
	expect(shows(app, "Folder missing")).to_be(true)
	expect(shows(app, "1 unpushed commit")).to_be(true)
	expect(shows(app, "Not measured")).to_be(true)
end)

test("app data opens on its parts", function()
	local app = into(open(), "App data")
	expect(shows(app, "~/.naive")).to_be(true)
	expect(shows(app, "Downloaded updates")).to_be(true)
	expect(shows(app, "412 MB")).to_be(true)
	expect(shows(app, "Logs")).to_be(true)
end)

test("a dirty worktree's removal asks to lose its work before it goes", function()
	local app = into(open(), "naive")
	app:hover(`{PAGE} >> "storage-cleanup"`)
	app:frames(5)
	app:click(`{PAGE} >> role:button "Remove storage-cleanup"`)
	app:frames(20)
	expect(app:tree("role:dialog"):find("It has uncommitted changes. They're lost with it.", 1, true) ~= nil).to_be(true)
	local confirm = 'role:dialog >> role:button "Remove worktree"'
	expect(app:tree(confirm)).to_contain("disabled")
	app:click('role:dialog >> role:checkbox "Remove it anyway, losing this work"')
	app:frames(5)
	expect(app:tree(confirm)).never.to_contain("disabled")
	app:click(confirm)
	app:frames(30)
	expect(asked(app, "settings.engine:RemoveWorktree")).to_be(1)
	expect(app:has(`{PAGE} >> role:button "Remove storage-cleanup"`)).to_be(false)
	expect(asked(app, "settings.engine:ListStorageWorktrees")).to_be(2)
end)

test("a refused removal says why inside the dialog", function()
	local app = into(open(), "naive")
	app:hover(`{PAGE} >> "sidebar-rows"`)
	app:frames(5)
	app:click(`{PAGE} >> role:button "Remove sidebar-rows"`)
	app:frames(20)
	app:command("settings_stub.refuse_next")
	app:click('role:dialog >> role:button "Remove worktree"')
	app:frames(20)
	expect(app:has('role:dialog >> "Something went wrong."')).to_be(true)
	expect(shows(app, "sidebar-rows")).to_be(true)
end)

test("freeing space runs each chosen clean-up in turn, then says what it freed", function()
	local app = open()
	app:click(`{PAGE} >> role:button "Free up 4.7 GB"`)
	app:frames(20)
	expect(app:has('role:dialog >> "Free up space"')).to_be(true)
	expect(app:has('role:dialog >> "3 stale worktrees"')).to_be(true)
	expect(app:tree("role:dialog")).to_contain("This can't be undo")
	app:click('role:dialog >> role:button "Free up 4.7 GB"')
	expect(app:wait('"4.7 GB freed"', { timeout_ms = 3000 })).to_be(true)
	expect(app:has('"11 items removed"')).to_be(true)
	expect(asked(app, "settings.engine:CleanStorage")).to_be(3)
	app:frames(30)
	expect(app:has(`{PAGE} >> role:button "Nothing to free up"`)).to_be(true)
end)

test("a failed clean-up says why inside the dialog and keeps it open", function()
	local app = open()
	app:click(`{PAGE} >> role:button "Free up 4.7 GB"`)
	app:frames(20)
	app:command("settings_stub.refuse_next")
	app:click('role:dialog >> role:button "Free up 4.7 GB"')
	app:frames(30)
	expect(app:has('role:dialog >> "Something went wrong."')).to_be(true)
	expect(asked(app, "settings.engine:CleanStorage")).to_be(1)
end)
