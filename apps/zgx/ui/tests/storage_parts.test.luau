local function open(): any
	local app = mount("storage_fixture.luau")
	app:resize(900, 3000)
	app:frames(60)
	return app
end

local function box(app: any, id: string): (number, number)
	for line in app:tree(`#{id}`):gmatch("[^\n]+") do
		if line:find(`#{id} `, 1, true) then
			local x, w = line:match(" (%-?[%d.]+),%-?[%d.]+ ([%d.]+)x[%d.]+")
			if x then
				return tonumber(x) :: number, tonumber(w) :: number
			end
		end
	end
	error(`no #{id} in the tree:\n{app:tree()}`)
end

local function node(app: any, kind: string, label: string): string?
	for line in app:tree():gmatch("[^\n]+") do
		if line:find(` {kind} "{label}"`, 1, true) then
			return line:match("@(%d+)")
		end
	end
	return nil
end

test("the meter's bar splits its track by size, a hairline gap between parts", function()
	local app = open()
	local tx, tw = box(app, "storage-meter-full-bar")
	local x1, w1 = box(app, "storage-meter-full-bar-1")
	local x2, w2 = box(app, "storage-meter-full-bar-2")
	local x3, w3 = box(app, "storage-meter-full-bar-3")
	expect(math.abs(x1 - tx) <= 0.5).to_be(true)
	expect(math.abs((x2 - (x1 + w1)) - 2) <= 0.5).to_be(true)
	expect(math.abs((x3 - (x2 + w2)) - 2) <= 0.5).to_be(true)
	expect(math.abs((x3 + w3) - (tx + tw)) <= 0.5).to_be(true)
	expect(w1 > w3 and w3 > w2).to_be(true)
	expect(app:has('role:img "Worktrees 7.3 GB, Chat history 264 MB, App data 605 MB"')).to_be(true)
end)

test("an empty part takes no room and a sliver still shows", function()
	local app = open()
	local _, empty = box(app, "storage-meter-lopsided-bar-1")
	local _, sliver = box(app, "storage-meter-lopsided-bar-2")
	expect(empty).to_be(0)
	expect(sliver >= 3).to_be(true)
	expect(app:has('"Couldn\'t reach the engine. These are the last sizes measured."')).to_be(true)
end)

test("a worktree row wears only its most important flag and one line", function()
	local app = open()
	expect(app:has('"Uncommitted changes"')).to_be(true)
	expect(app:has('"2 unpushed commits"')).to_be(false)
	expect(app:has('"1 unpushed commit"')).to_be(true)
	expect(app:has('"Folder missing"')).to_be(true)
	expect(app:has('"no branch"')).to_be(true)
	expect(app:has('"Not measured"')).to_be(true)
	expect(app:has('"Chat deleted"')).to_be(true)
end)

test("a worktree removed leaves the other rows as they were", function()
	local app = open()
	local notes = node(app, "button", "Remove notes")
	local sidebar = node(app, "text", "sidebar-rows")
	expect(notes).never.to_be_nil()
	app:hover('"fix-paste"')
	app:frames(5)
	app:click('role:button "Remove fix-paste"')
	app:frames(30)
	expect(node(app, "button", "Remove fix-paste")).to_be_nil()
	expect(node(app, "button", "Remove notes")).to_be(notes)
	expect(node(app, "text", "sidebar-rows")).to_be(sidebar)
end)

test("the list says when it's loading, empty, failed or out of date", function()
	local app = open()
	expect(app:has('"No worktrees on this computer."')).to_be(true)
	expect(app:has('role:alert >> "Couldn\'t list the worktrees"')).to_be(true)
	expect(app:has('role:alert >> role:button "Try again"')).to_be(true)
	expect(app:has('"Couldn\'t refresh. These may be out of date."')).to_be(true)
	expect(app:has('"Loading…"')).to_be(true)
end)

test("a choice out of reach can't be ticked", function()
	local app = open()
	expect(app:tree('role:checkbox "Downloaded update files"')).to_contain("disabled")
	expect(app:tree('role:checkbox "3 stale worktrees"')).never.to_contain("disabled")
end)
