-- Greeter: a greeting in the title bar ("ui.add", at #titlebar-actions),
-- set up on its own page in Settings (naive-plugin.json's "settings":
-- Naive draws the page and keeps what you set, for this plugin alone).
-- It reads its settings as they change (`naive.setting(id):get()`), and
-- hears each change (`naive.on_setting`), here said in a toast.

local naive = require("./naive")("settings-demo")

local show = naive.setting("show")
local words = naive.setting("words")
local tone = naive.setting("tone")

naive.on_setting(function(id: string, value: any, _was: any)
	naive.toast(`Greeter: {id} is now {tostring(value)}`)
end)

-- What Naive says beside the Greeting: a warning while it says nothing.
local function check_words()
	local said = words:peek() or ""
	if string.match(said, "^%s*$") then
		naive.set_status("words", { badge = "Empty", tone = "warning", text = "Say something, or it greets with nothing." })
	else
		naive.set_status("words", nil)
	end
end
check_words()
naive.on_setting(function(id: string)
	if id == "words" then
		check_words()
	end
end)

naive.place {
	at = "#titlebar-actions",
	after = function(): Node
		return ui.text {
			id = "greeter",
			function(): string
				if not show:get() then
					return ""
				end
				local said = words:get() or ""
				return if tone:get() == "excited" then `{said}!` else said
			end,
			text_size = "$font.size.sm",
			color = "$text.secondary",
		}
	end,
}
