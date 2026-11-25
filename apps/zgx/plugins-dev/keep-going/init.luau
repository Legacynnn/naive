-- Keep going's window: says what its service did, in a toast. The work is
-- the service's (service.luau), which runs with no window open.

local naive = require("./naive")("keep-going")

naive.service():on("continued", function(e)
	local title = e.chat
	local session = naive.sessions()[e.chat]
	if session and session.title then
		title = session.title
	end
	naive.toast(`Sent "continue" to {title}.`)
end)
