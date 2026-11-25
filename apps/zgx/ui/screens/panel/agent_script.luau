return [=[
(() => {
	if (window.__naiveAgent) return;
	const logs = [];
	const show = (v) => {
		if (typeof v === "string") return v;
		if (v instanceof Error) return v.stack || v.message;
		try { return JSON.stringify(v); } catch { try { return String(v); } catch { return "[unprintable]"; } }
	};
	const keep = (level, args) => {
		try {
			logs.push({ level, text: args.map(show).join(" ").slice(0, 2000), at: Date.now() });
			if (logs.length > 200) logs.shift();
		} catch {}
	};
	for (const level of ["log", "info", "warn", "error", "debug"]) {
		const was = console[level];
		console[level] = function (...args) { keep(level, args); return was.apply(this, args); };
	}
	addEventListener("error", (e) => keep("error", [e.message + (e.filename ? ` (${e.filename}:${e.lineno})` : "")]));
	addEventListener("unhandledrejection", (e) => keep("error", ["Unhandled rejection: " + show(e.reason && e.reason.message || e.reason)]));

	const refs = new Map();
	let seq = 0;
	const ROLES = {
		A: "link", BUTTON: "button", SELECT: "combobox", TEXTAREA: "textbox", SUMMARY: "button",
		NAV: "navigation", MAIN: "main", HEADER: "banner", FOOTER: "contentinfo", ASIDE: "complementary",
		FORM: "form", DIALOG: "dialog", IMG: "img", UL: "list", OL: "list", LI: "listitem", TABLE: "table",
		TR: "row", TH: "columnheader", TD: "cell", LABEL: "label", OPTION: "option",
		H1: "heading", H2: "heading", H3: "heading", H4: "heading", H5: "heading", H6: "heading",
	};
	const INPUTS = { checkbox: "checkbox", radio: "radio", button: "button", submit: "button", reset: "button", image: "button", range: "slider", search: "searchbox", number: "spinbutton" };
	const ACTS = new Set(["link", "button", "combobox", "textbox", "searchbox", "checkbox", "radio", "slider", "spinbutton", "switch", "tab", "menuitem", "option", "treeitem", "listbox", "menuitemcheckbox", "menuitemradio"]);
	const SHAPE = new Set(["navigation", "main", "banner", "contentinfo", "complementary", "form", "dialog", "heading", "img", "list", "table", "row", "region", "alert", "tablist", "menu", "tabpanel"]);

	const roleOf = (el) => {
		const named = el.getAttribute("role");
		if (named) return named.split(" ")[0];
		if (el.tagName === "INPUT") return el.type === "hidden" ? null : INPUTS[el.type] || "textbox";
		if (el.tagName === "A" && !el.hasAttribute("href")) return null;
		if (el.isContentEditable && el.getAttribute("contenteditable") !== null) return "textbox";
		const r = ROLES[el.tagName];
		if (r) return r;
		if (el.hasAttribute("onclick") || (el.hasAttribute("tabindex") && el.tabIndex >= 0)) return "generic-clickable";
		return null;
	};
	const clip = (s, n) => {
		s = (s || "").replace(/\s+/g, " ").trim();
		return s.length > n ? s.slice(0, n - 1) + "…" : s;
	};
	const nameOf = (el, role) => {
		const aria = el.getAttribute("aria-label");
		if (aria) return clip(aria, 100);
		const by = el.getAttribute("aria-labelledby");
		if (by) {
			const t = by.split(" ").map((id) => document.getElementById(id)?.innerText || "").join(" ");
			if (t.trim()) return clip(t, 100);
		}
		if (el.labels && el.labels.length) return clip(el.labels[0].innerText, 100);
		for (const a of ["alt", "title", "placeholder"]) if (el.getAttribute(a)) return clip(el.getAttribute(a), 100);
		if (el.tagName === "INPUT" && ["button", "submit", "reset"].includes(el.type)) return clip(el.value, 100);
		if (el.tagName === "SELECT" || el.tagName === "TEXTAREA" || el.tagName === "INPUT") return "";
		if (SHAPE.has(role) && role !== "heading") return "";
		return clip(el.innerText, 100);
	};
	const visible = (el) => {
		const s = getComputedStyle(el);
		if (s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
		const r = el.getBoundingClientRect();
		return r.width > 0 || r.height > 0 || s.display === "contents";
	};
	const refOf = (el) => {
		let ref = el.getAttribute("data-naive-ref");
		if (!ref || refs.get(ref)?.deref() !== el) {
			ref = "e" + ++seq;
			el.setAttribute("data-naive-ref", ref);
		}
		refs.set(ref, new WeakRef(el));
		return ref;
	};
	const stateOf = (el, role) => {
		const out = [];
		if (role === "heading") out.push("level=" + (el.tagName.match(/\d/) || [el.getAttribute("aria-level") || "2"])[0]);
		if (el.disabled || el.getAttribute("aria-disabled") === "true") out.push("disabled");
		if (el.checked || el.getAttribute("aria-checked") === "true") out.push("checked");
		if (el.getAttribute("aria-expanded")) out.push("expanded=" + el.getAttribute("aria-expanded"));
		if (el.selected || el.getAttribute("aria-selected") === "true") out.push("selected");
		if (el.required) out.push("required");
		if (document.activeElement === el) out.push("focused");
		if (el.tagName === "SELECT") out.push("value=" + JSON.stringify(clip(el.selectedOptions[0]?.text, 60)));
		else if ((el.tagName === "INPUT" || el.tagName === "TEXTAREA") && !["password", "checkbox", "radio", "button", "submit", "reset", "image"].includes(el.type) && el.value) out.push("value=" + JSON.stringify(clip(el.value, 80)));
		else if (el.type === "password" && el.value) out.push("value=•••");
		if (role === "link") {
			const h = el.getAttribute("href");
			if (h && !h.startsWith("javascript:")) out.push("href=" + clip(h, 100));
		}
		return out.length ? " [" + out.join(", ") + "]" : "";
	};
	const ownText = (el) => {
		let t = "";
		for (const n of el.childNodes) if (n.nodeType === 3) t += n.textContent;
		return clip(t, 160);
	};

	const LIMIT = 60000;
	const snapshot = () => {
		const lines = [];
		let size = 0;
		let cut = false;
		const add = (depth, line) => {
			if (cut) return;
			const l = "  ".repeat(depth) + line;
			size += l.length + 1;
			if (size > LIMIT) { cut = true; return; }
			lines.push(l);
		};
		const walk = (root, depth) => {
			for (const el of root.children) visit(el, depth);
		};
		const visit = (el, depth) => {
			if (cut || ["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "svg", "HEAD"].includes(el.tagName)) return;
			if (el.getAttribute("aria-hidden") === "true" || !visible(el)) return;
			const role = roleOf(el);
			let next = depth;
			if (role && (ACTS.has(role) || SHAPE.has(role) || role === "generic-clickable")) {
				const name = nameOf(el, role);
				const kind = role === "generic-clickable" ? "clickable" : role;
				const quiet = SHAPE.has(role) && !name && ["list", "row", "table"].includes(role);
				if (!quiet) {
					add(depth, `- ${kind}${name ? " " + JSON.stringify(name) : ""} [${refOf(el)}]${stateOf(el, role)}`);
					next = depth + 1;
				}
				if (ACTS.has(role) && role !== "listbox") return;
			} else {
				const t = ownText(el);
				if (t) add(depth, "- text " + JSON.stringify(t));
			}
			if (el.shadowRoot) walk(el.shadowRoot, next);
			if (el.tagName === "IFRAME") {
				try { if (el.contentDocument?.body) walk(el.contentDocument.body, next); } catch {}
			}
			walk(el, next);
		};
		if (document.body) walk(document.body, 0);
		if (cut) lines.push("… (cut: the page is longer; scroll or act on what's here)");
		return { url: location.href, title: document.title, tree: lines.join("\n") };
	};

	const find = (ref) => {
		let el = refs.get(ref)?.deref();
		if (!el || !el.isConnected) el = document.querySelector(`[data-naive-ref="${CSS.escape(ref)}"]`);
		if (!el) throw new Error(`No element ${ref} on the page now: take a new browser_snapshot`);
		return el;
	};
	const center = (el) => {
		el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
		const r = el.getBoundingClientRect();
		return { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
	};
	const mouse = (el, type, at, extra) => {
		const init = { bubbles: true, cancelable: true, composed: true, view: window, button: 0, ...at, ...extra };
		const E = type.startsWith("pointer") ? PointerEvent : MouseEvent;
		el.dispatchEvent(new E(type, type.startsWith("pointer") ? { pointerId: 1, pointerType: "mouse", isPrimary: true, ...init } : init));
	};
	const page = () => ({ url: location.href, title: document.title });

	const click = ({ ref, double }) => {
		const el = find(ref);
		const at = center(el);
		const doc = el.ownerDocument;
		const top = doc.elementFromPoint(at.clientX, at.clientY);
		const target = top && (el === top || el.contains(top)) ? top : el;
		for (const t of ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove", "pointerdown", "mousedown"]) mouse(target, t, at, { buttons: 1 });
		if (typeof el.focus === "function") el.focus({ preventScroll: true });
		for (const t of ["pointerup", "mouseup"]) mouse(target, t, at, {});
		target.click();
		if (double) { target.click(); mouse(target, "dblclick", at, { detail: 2 }); }
		const covered = top && !(el === top || el.contains(top) || top.contains(el));
		return { ...page(), covered: covered ? "Another element was over it; the click went to the element itself" : undefined };
	};

	const setValue = (el, value) => {
		const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : el.tagName === "SELECT" ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
		Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
	};
	const type = ({ ref, text, append, submit }) => {
		const el = find(ref);
		center(el);
		el.focus({ preventScroll: true });
		if (el.tagName === "SELECT") {
			const option = [...el.options].find((o) => o.text.trim() === text || o.value === text);
			if (!option) throw new Error(`No option "${text}" in ${ref}: its options are ${[...el.options].map((o) => JSON.stringify(o.text.trim())).join(", ")}`);
			setValue(el, option.value);
			el.dispatchEvent(new Event("input", { bubbles: true }));
			el.dispatchEvent(new Event("change", { bubbles: true }));
		} else if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") {
			el.dispatchEvent(new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType: "insertText", data: text }));
			setValue(el, append ? el.value + text : text);
			el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
			el.dispatchEvent(new Event("change", { bubbles: true }));
		} else if (el.isContentEditable) {
			if (!append) document.execCommand("selectAll");
			document.execCommand("insertText", false, text);
		} else {
			throw new Error(`${ref} isn't something to type into`);
		}
		if (submit) key({ key: "Enter", ref });
		return page();
	};

	const NEXT = 'a[href],button,input,select,textarea,[tabindex]:not([tabindex="-1"]),[contenteditable="true"]';
	const CODES = { " ": "Space", Enter: "Enter", Tab: "Tab", Escape: "Escape", Backspace: "Backspace", Delete: "Delete" };
	const codeOf = (name) => {
		if (CODES[name]) return CODES[name];
		if (/^[a-z]$/i.test(name)) return "Key" + name.toUpperCase();
		if (/^[0-9]$/.test(name)) return "Digit" + name;
		return name.length === 1 ? "" : name;
	};
	const TOGGLES = new Set(["checkbox", "radio", "button", "submit", "reset", "image"]);
	const key = ({ key: spec, ref }) => {
		const plus = spec.length > 1 && spec.endsWith("+");
		const parts = (plus ? spec.slice(0, -1) : spec).split("+");
		const name = plus ? "+" : parts.pop();
		if (plus) parts.pop();
		const mods = new Set(parts.map((p) => p.toLowerCase()));
		const el = ref ? find(ref) : document.activeElement || document.body;
		if (ref) el.focus({ preventScroll: true });
		const init = {
			key: name === "Space" ? " " : name, code: codeOf(name === "Space" ? " " : name), bubbles: true, cancelable: true, composed: true,
			ctrlKey: mods.has("control") || mods.has("ctrl"), shiftKey: mods.has("shift"), altKey: mods.has("alt"), metaKey: mods.has("meta") || mods.has("cmd"),
		};
		const k = init.key;
		const go = el.dispatchEvent(new KeyboardEvent("keydown", init));
		if (k.length === 1 || k === "Enter") el.dispatchEvent(new KeyboardEvent("keypress", init));
		if (go) {
			const toggle = el.tagName === "BUTTON" || (el.tagName === "INPUT" && TOGGLES.has(el.type)) || el.getAttribute("role") === "button" || el.getAttribute("role") === "checkbox";
			const field = !toggle && (el.tagName === "INPUT" || el.tagName === "TEXTAREA");
			if (toggle && (k === " " || k === "Enter")) {
				el.click();
			} else if (k === "Enter") {
				if (el.tagName === "INPUT" && el.form) el.form.requestSubmit();
				else if (el.tagName === "TEXTAREA") type({ ref: refOf(el), text: "\n", append: true });
				else if (el.tagName === "A") el.click();
			} else if (k === "Tab") {
				const all = [...document.querySelectorAll(NEXT)].filter((e) => !e.disabled && visible(e));
				const i = all.indexOf(el);
				const to = i < 0 ? all[init.shiftKey ? all.length - 1 : 0] : all[(i + (init.shiftKey ? -1 : 1) + all.length) % all.length];
				to?.focus();
			} else if (field && k === "Backspace") {
				setValue(el, el.value.slice(0, -1));
				el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "deleteContentBackward" }));
			} else if (field && k.length === 1 && !init.ctrlKey && !init.metaKey) {
				type({ ref: refOf(el), text: k, append: true });
			} else if (k === "Escape" && el.blur) {
				el.blur();
			}
		}
		el.dispatchEvent(new KeyboardEvent("keyup", init));
		return page();
	};

	const scrollable = (el) => {
		for (let e = el; e && e !== document.body && e !== document.documentElement; e = e.parentElement) {
			const o = getComputedStyle(e).overflowY;
			if ((o === "auto" || o === "scroll" || o === "overlay") && e.scrollHeight > e.clientHeight + 4) return e;
		}
		return null;
	};
	const scroll = ({ direction, amount, ref }) => {
		if (ref) {
			center(find(ref));
			return { ...page(), scrollY: Math.round(scrollY) };
		}
		const root = document.scrollingElement || document.documentElement;
		const pageScrolls = root.scrollHeight > innerHeight + 4;
		const box = pageScrolls ? null : scrollable(document.activeElement !== document.body && document.activeElement || document.elementFromPoint(innerWidth / 2, innerHeight / 2));
		const target = box || root;
		const view = box ? box.clientHeight : innerHeight;
		const by = amount || view * 0.85;
		const dir = direction || "down";
		if (dir === "up" || dir === "down") target.scrollBy({ top: dir === "up" ? -by : by, behavior: "instant" });
		else target.scrollTo({ top: dir === "top" ? 0 : target.scrollHeight, behavior: "instant" });
		return { ...page(), scrolled: box ? "an inner pane" : "the page", scrollY: Math.round(target.scrollTop), height: target.scrollHeight, viewport: view };
	};

	const found = ({ text, selector }) => {
		if (selector) return !!document.querySelector(selector);
		if (text) return (document.body?.innerText || "").includes(text);
		return document.readyState === "complete";
	};

	const read = ({ clear }) => {
		const out = logs.slice();
		if (clear) logs.length = 0;
		return { messages: out };
	};

	window.__naiveAgent = { snapshot, click, type, key, scroll, found, console: read, page };
})();
]=]
