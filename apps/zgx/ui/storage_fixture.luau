ui.theme.strict("warn")
local ds = require("@ds")
ds.setup()

return ui.scroll {
	id = "storage-fixture",
	w_full = true,
	h_full = true,
	bg = "$background",
	ui.column { p = "$space.5", require("@demos/storage").demo() },
}
