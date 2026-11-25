-- Account pin's window: says what its service did, in a toast. The work is
-- the service's (service.luau), which runs with no window open; this only
-- tells you while Naive is open.

local naive = require("./naive")("account-pin")

local service = naive.service()

service:on("pinned", function(e)
	naive.toast(`A new Claude Code chat is running on {e.to}.`)
end)

service:on("lost", function(e)
	naive.toast(`A saved account was removed; its chats run on the active account now.`)
end)
