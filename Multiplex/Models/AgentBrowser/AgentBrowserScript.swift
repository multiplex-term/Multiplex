import Foundation

/// The JavaScript an agent tab carries. Pure strings.
///
/// Two scripts, two worlds:
/// - `helper` runs in an isolated `WKContentWorld`: it shares the DOM with
///   the page but none of its globals, so the page can neither see nor call
///   it, and no message handler exists in any world — the viewport's "no
///   bridge into the app" rule holds for the page. Every agent action
///   (`snapshot`, `click`, `fill`, …) is a call into `__mpx.call`.
/// - `consoleHook` runs in the page world, because console calls happen
///   there. It only re-dispatches each message as a DOM event the helper
///   buffers; it gives the page nothing it did not already have.
///
/// Answers are JSON strings (`{"ok":…}` or `{"error":{"code","message"}}`)
/// so the driver never depends on WebKit's JS→ObjC value bridging and
/// exceptions keep their code.
enum AgentBrowserScript {
    /// The isolated world every agent helper call runs in.
    static let worldName = "multiplex-agent"

    static func helper(consoleEvent: String) -> String {
        helperSource.replacingOccurrences(of: "__MPX_EVENT__", with: consoleEvent)
    }

    static func consoleHook(consoleEvent: String) -> String {
        consoleHookSource.replacingOccurrences(of: "__MPX_EVENT__", with: consoleEvent)
    }

    /// The body `callAsyncJavaScript` runs in the helper world; `name` and
    /// `argsJSON` arrive as arguments.
    static let callBody = """
        if (!window.__mpx) { return null; }
        const out = JSON.stringify(window.__mpx.call(name, JSON.parse(argsJSON)));
        if (out.length > \(maxAnswerChars)) {
          return JSON.stringify({ error: { code: "too_large", message: `The answer was ${out.length} characters.` } });
        }
        return out;
        """

    /// Answers longer than this never leave the page: a page can make any
    /// value huge, and the app would hold it whole.
    static let maxAnswerChars = 4_000_000

    /// Bodies for the agent's own `eval`, in the PAGE world (where the app's
    /// globals live). Tried as an expression first, then as statements, so
    /// both `document.title` and `const a = 1; return a + 1` work.
    static func evalBodies(_ source: String) -> [String] {
        let finish = """
            if (__v === undefined) { return JSON.stringify({ undefined: true }); }
            let __s;
            try { __s = JSON.stringify({ value: __v }); } catch (e) { __s = JSON.stringify({ value: String(__v) }); }
            if (__s.length > \(maxAnswerChars)) { return JSON.stringify({ tooLarge: __s.length }); }
            return __s;
            """
        return [
            "const __v = await (\n\(source)\n);\n\(finish)",
            "const __v = await (async () => {\n\(source)\n})();\n\(finish)",
        ]
    }

    /// Removes the WebRTC constructors from the page world: peer
    /// connections send UDP from the device to any address the page names.
    static let noWebRTC = #"""
        (() => {
          for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel"]) {
            try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); }
            catch (_) { try { delete window[name]; } catch (_) {} }
          }
        })();
        """#

    private static let consoleHookSource = #"""
        (() => {
          const EVENT = "__MPX_EVENT__";
          for (const level of ["log", "info", "warn", "error", "debug"]) {
            const original = console[level];
            if (typeof original !== "function") continue;
            console[level] = function (...args) {
              try {
                const text = args.map((a) => {
                  if (typeof a === "string") return a;
                  if (a instanceof Error) return a.stack || String(a);
                  try { return JSON.stringify(a); } catch (_) { return String(a); }
                }).join(" ");
                document.dispatchEvent(new CustomEvent(EVENT, {
                  detail: JSON.stringify({ level, text: text.slice(0, 4000) }),
                }));
              } catch (_) {}
              return original.apply(this, args);
            };
          }
        })();
        """#

    private static let helperSource = #"""
        (() => {
          if (window.__mpx) return;
          const EVENT = "__MPX_EVENT__";
          // The page can forge these events (the name is not a secret), so
          // everything recorded is page-authored: levels are allowlisted,
          // text is cut, and the buffer has a character budget.
          const MAX_CONSOLE = 500;
          const MAX_CONSOLE_CHARS = 400000;
          const LEVELS = new Set(["log", "info", "warn", "error", "debug"]);
          const consoleBuffer = [];
          let consoleChars = 0;
          let refs = new Map();

          function record(level, text) {
            const entry = {
              level: LEVELS.has(level) ? level : "log",
              text: String(text).slice(0, 4000),
              ts: Date.now(),
            };
            consoleBuffer.push(entry);
            consoleChars += entry.text.length;
            while (consoleBuffer.length > MAX_CONSOLE || consoleChars > MAX_CONSOLE_CHARS) {
              consoleChars -= consoleBuffer.shift().text.length;
            }
          }
          document.addEventListener(EVENT, (e) => {
            if (typeof e.detail !== "string" || e.detail.length > 8192) return;
            try {
              const d = JSON.parse(e.detail);
              if (d && typeof d.level === "string" && typeof d.text === "string") record(d.level, d.text);
            } catch (_) {}
          }, true);
          window.addEventListener("error", (e) => {
            const t = e.target;
            if (t && t !== window && (t.src || t.href)) {
              record("error", `Failed to load ${t.tagName.toLowerCase()} ${t.src || t.href}`);
            } else {
              record("error", (e.message || "Uncaught error") + (e.filename ? ` (${e.filename}:${e.lineno})` : ""));
            }
          }, true);
          window.addEventListener("unhandledrejection", (e) => {
            const r = e.reason;
            record("error", "Unhandled rejection: " + (r && r.stack ? r.stack : String(r)));
          });

          function fail(code, message) { const e = new Error(message); e.mpxCode = code; return e; }
          function clean(s, max = 100) {
            s = String(s == null ? "" : s).replace(/\s+/g, " ").trim();
            return s.length > max ? s.slice(0, max - 1) + "…" : s;
          }
          const q = (s) => JSON.stringify(s);

          function isHidden(el) {
            if (el.hidden || el.getAttribute("aria-hidden") === "true") return true;
            if (typeof el.checkVisibility === "function") {
              return !el.checkVisibility({ visibilityProperty: true });
            }
            const s = getComputedStyle(el);
            return s.display === "none" || s.visibility === "hidden";
          }

          function roleOf(el) {
            const explicit = el.getAttribute("role");
            if (explicit) return explicit.trim().split(/\s+/)[0];
            switch (el.tagName) {
              case "A": return el.hasAttribute("href") ? "link" : null;
              case "BUTTON": case "SUMMARY": return "button";
              case "SELECT": return el.multiple || el.size > 1 ? "listbox" : "combobox";
              case "TEXTAREA": return "textbox";
              case "INPUT": {
                const t = (el.type || "text").toLowerCase();
                if (t === "hidden") return null;
                if (["button", "submit", "reset", "image"].includes(t)) return "button";
                if (t === "checkbox" || t === "radio") return t;
                if (t === "range") return "slider";
                if (t === "file") return "file";
                if (t === "search") return "searchbox";
                return "textbox";
              }
              case "H1": case "H2": case "H3": case "H4": case "H5": case "H6": return "heading";
              case "IMG": return el.getAttribute("alt") ? "img" : null;
              case "NAV": return "navigation";
              case "MAIN": return "main";
              case "ASIDE": return "complementary";
              case "FORM": return "form";
              case "DIALOG": return "dialog";
              case "UL": case "OL": return "list";
              case "TABLE": return "table";
              case "FIELDSET": return "group";
              case "IFRAME": return "iframe";
            }
            if (el.isContentEditable && el.hasAttribute("contenteditable")) return "textbox";
            return null;
          }

          const INTERACTIVE = new Set([
            "link", "button", "combobox", "listbox", "textbox", "searchbox", "checkbox", "radio",
            "slider", "file", "switch", "tab", "menuitem", "menuitemcheckbox", "menuitemradio",
            "option", "treeitem", "spinbutton",
          ]);
          const CONTAINERS = new Set([
            "navigation", "main", "complementary", "form", "dialog", "alertdialog", "list", "table",
            "group", "menu", "menubar", "tablist", "tree", "region", "banner", "contentinfo", "toolbar",
          ]);
          const DESCEND = "a[href],button,input,select,textarea,summary,img[alt],iframe,nav,main,aside,"
            + "form,dialog,ul,ol,table,fieldset,h1,h2,h3,h4,h5,h6,[role],[contenteditable],[tabindex],[onclick]";
          const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "META", "LINK"]);

          function nameOf(el) {
            const aria = el.getAttribute("aria-label");
            if (aria && aria.trim()) return clean(aria);
            const by = el.getAttribute("aria-labelledby");
            if (by) {
              const t = by.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean)
                .map((n) => n.innerText || n.textContent).join(" ");
              if (t.trim()) return clean(t);
            }
            const tag = el.tagName;
            if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") {
              if (el.labels && el.labels.length) {
                const t = Array.from(el.labels).map((l) => l.innerText).join(" ");
                if (t.trim()) return clean(t);
              }
              if (["button", "submit", "reset"].includes(el.type)) return clean(el.value || el.type);
              if (el.type === "image") return clean(el.alt);
              return clean(el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("name"));
            }
            if (tag === "IMG") return clean(el.getAttribute("alt"));
            const text = el.innerText;
            if (text && text.trim()) return clean(text);
            const img = el.querySelector("img[alt]");
            if (img) return clean(img.alt);
            const svgTitle = el.querySelector("svg title");
            if (svgTitle) return clean(svgTitle.textContent);
            return clean(el.getAttribute("title"));
          }

          function describe(el) {
            const role = roleOf(el) || el.tagName.toLowerCase();
            const name = nameOf(el);
            return name ? `${role} ${q(name)}` : role;
          }

          function isPointer(el) {
            if (getComputedStyle(el).cursor !== "pointer") return false;
            const parent = el.parentElement;
            return !parent || getComputedStyle(parent).cursor !== "pointer";
          }

          function states(el, role) {
            const out = [];
            if (el.disabled || el.getAttribute("aria-disabled") === "true") out.push("disabled");
            if (el.checked || el.getAttribute("aria-checked") === "true") out.push("checked");
            if (el.getAttribute("aria-selected") === "true") out.push("selected");
            const expanded = el.getAttribute("aria-expanded");
            if (expanded) out.push(expanded === "true" ? "expanded" : "collapsed");
            if (el.required) out.push("required");
            if (document.activeElement === el) out.push("focused");
            return out;
          }

          function valueOf(el, role) {
            if (el.tagName === "SELECT") {
              const o = el.options[el.selectedIndex];
              return o ? clean(o.text, 60) : "";
            }
            if (role === "textbox" || role === "searchbox" || role === "spinbutton" || role === "slider") {
              if (el.isContentEditable) return clean(el.innerText, 80);
              if (el.type === "password") return el.value ? "••••" : "";
              return "value" in el ? clean(el.value, 80) : null;
            }
            return null;
          }

          function hrefOf(el) {
            const raw = el.getAttribute("href");
            if (!raw || raw.startsWith("javascript:")) return null;
            try {
              const u = new URL(raw, location.href);
              const s = u.origin === location.origin ? u.pathname + u.search + u.hash : u.href;
              return clean(s, 80);
            } catch (_) { return null; }
          }

          function snapshot(full) {
            refs = new Map();
            let next = 1;
            const lines = [];
            const limit = full ? 20000 : 600;
            let truncated = false;
            const emit = (depth, text) => {
              if (lines.length >= limit) { truncated = true; return; }
              lines.push("  ".repeat(depth) + "- " + text);
            };
            const ref = (el) => { const id = "e" + next++; refs.set(id, el); return id; };

            function interactive(el, role, depth) {
              const name = nameOf(el);
              let line = role + (name ? " " + q(name) : "") + ` [ref=${ref(el)}]`;
              const st = states(el, role);
              if (st.length) line += " [" + st.join(", ") + "]";
              const value = valueOf(el, role);
              if (value) line += " = " + q(value);
              if (role === "link") { const h = hrefOf(el); if (h) line += " → " + h; }
              emit(depth, line);
            }

            function visitNodes(nodes, depth) {
              for (const node of nodes) {
                if (truncated) return;
                if (node.nodeType === 3) {
                  const t = clean(node.textContent, 300);
                  if (t) emit(depth, "text: " + t);
                } else if (node.nodeType === 1) {
                  visit(node, depth);
                }
              }
            }

            function children(el) {
              return el.shadowRoot ? el.shadowRoot.childNodes : el.childNodes;
            }

            function visit(el, depth) {
              if (SKIP.has(el.tagName)) return;
              if (el.tagName === "SLOT") { visitNodes(el.assignedNodes({ flatten: true }), depth); return; }
              if (isHidden(el)) return;
              const role = roleOf(el);
              if (role && INTERACTIVE.has(role)) { interactive(el, role, depth); return; }
              if (role === "heading") {
                const level = Number(el.getAttribute("aria-level") || el.tagName.slice(1)) || 2;
                emit(depth, `heading ${q(nameOf(el))} [level=${level}]`);
                return;
              }
              if (role === "img") { emit(depth, "img " + q(nameOf(el))); return; }
              if (role === "iframe") { emit(depth, "iframe " + q(clean(el.title || el.src, 80))); return; }
              if (role && CONTAINERS.has(role)) {
                const label = clean(el.getAttribute("aria-label"));
                emit(depth, role + (label ? " " + q(label) : "") + ":");
                visitNodes(children(el), depth + 1);
                return;
              }
              if (!el.shadowRoot && !el.querySelector(DESCEND)) {
                if (isPointer(el)) { interactive(el, "clickable", depth); return; }
                const t = clean(el.innerText, 300);
                if (t) emit(depth, "text: " + t);
                return;
              }
              if (role === null && isPointer(el) && !el.querySelector("a[href],button,input,select,textarea")) {
                interactive(el, "clickable", depth);
                return;
              }
              visitNodes(children(el), depth);
            }

            if (document.body) visit(document.body, 0);
            return { text: lines.join("\n"), truncated, refs: next - 1 };
          }

          function findByText(text) {
            const needle = text.toLowerCase();
            const candidates = document.querySelectorAll(
              "a[href],button,input,select,textarea,summary,label,[role],[tabindex],[onclick]");
            for (const el of candidates) {
              if (!isHidden(el) && nameOf(el).toLowerCase().includes(needle)) return el;
            }
            if (!document.body) return null;
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
              const parent = walker.currentNode.parentElement;
              if (parent && walker.currentNode.textContent.toLowerCase().includes(needle) && !isHidden(parent)) {
                return parent;
              }
            }
            return null;
          }

          function resolve(target) {
            target = String(target || "").trim();
            if (/^e\d+$/.test(target)) {
              const el = refs.get(target);
              if (!el) throw fail("stale_ref", `No ${target} in the last snapshot — take a new snapshot.`);
              if (!el.isConnected) throw fail("stale_ref", `${target} is gone from the page — take a new snapshot.`);
              return el;
            }
            if (target.startsWith("text=")) {
              const el = findByText(target.slice(5));
              if (!el) throw fail("not_found", `No visible element with text ${q(target.slice(5))}.`);
              return el;
            }
            let el;
            try { el = document.querySelector(target); } catch (_) {
              throw fail("bad_request", `${q(target)} is not a ref (e12), text=…, or a CSS selector.`);
            }
            if (!el) throw fail("not_found", `Nothing matches ${q(target)}.`);
            return el;
          }

          function center(el) {
            el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
            const r = el.getBoundingClientRect();
            return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
          }

          function click(target) {
            const el = resolve(target);
            const { x, y } = center(el);
            const top = document.elementFromPoint(x, y);
            const opts = {
              bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, view: window, button: 0,
            };
            const pointer = (type) => {
              const init = { ...opts, pointerId: 1, pointerType: "mouse", isPrimary: true };
              try { el.dispatchEvent(new PointerEvent(type, init)); } catch (_) {}
            };
            pointer("pointerover");
            el.dispatchEvent(new MouseEvent("mouseover", opts));
            pointer("pointerdown");
            el.dispatchEvent(new MouseEvent("mousedown", opts));
            if (typeof el.focus === "function") el.focus({ preventScroll: true });
            pointer("pointerup");
            el.dispatchEvent(new MouseEvent("mouseup", opts));
            el.click();
            const out = { clicked: describe(el) };
            if (top && top !== el && !el.contains(top) && !top.contains(el)) out.coveredBy = describe(top);
            return out;
          }

          function inputEvent(text) {
            return new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: text });
          }

          function isEditable(el) {
            return el && (el.isContentEditable || el.tagName === "TEXTAREA"
              || (el.tagName === "INPUT" && roleOf(el) !== null && ["textbox", "searchbox"].includes(roleOf(el))));
          }

          function insert(el, text) {
            let ok = false;
            try {
              ok = text === "" ? document.execCommand("delete") : document.execCommand("insertText", false, text);
            } catch (_) {}
            return ok;
          }

          function selectOption(el, value) {
            if (el.tagName !== "SELECT") {
              throw fail("bad_request", `${describe(el)} is not a <select> — click it and pick from the snapshot.`);
            }
            const options = Array.from(el.options);
            const lower = String(value).toLowerCase();
            const opt = options.find((o) => o.value === value)
              || options.find((o) => o.text.trim().toLowerCase() === lower)
              || options.find((o) => o.text.toLowerCase().includes(lower));
            if (!opt) {
              const have = options.slice(0, 20).map((o) => o.text.trim()).join(", ");
              throw fail("not_found", `No option ${q(value)} (have: ${have}).`);
            }
            el.value = opt.value;
            opt.selected = true;
            el.dispatchEvent(new Event("input", { bubbles: true }));
            el.dispatchEvent(new Event("change", { bubbles: true }));
            return { selected: opt.text.trim(), value: opt.value };
          }

          function fill(target, text) {
            const el = resolve(target);
            center(el);
            if (el.tagName === "SELECT") return selectOption(el, text);
            if (typeof el.focus === "function") el.focus({ preventScroll: true });
            if (el.isContentEditable) {
              const range = document.createRange();
              range.selectNodeContents(el);
              const sel = getSelection();
              sel.removeAllRanges();
              sel.addRange(range);
              if (!insert(el, text)) {
                el.textContent = text;
                el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
              }
              return { filled: describe(el) };
            }
            if (!("value" in el)) throw fail("bad_request", `${describe(el)} is not a text field.`);
            if (typeof el.select === "function") el.select();
            if (!(insert(el, text) && el.value === text)) {
              // Set from this world: a framework's value tracker (React's)
              // lives on the page world's wrapper, so it still sees a change.
              el.value = text;
              el.dispatchEvent(inputEvent(text));
            }
            el.dispatchEvent(new Event("change", { bubbles: true }));
            return { filled: describe(el), value: el.type === "password" ? "••••" : el.value };
          }

          function focused() {
            const el = document.activeElement;
            return el && el !== document.body && el !== document.documentElement ? el : null;
          }

          function type(text) {
            const el = focused();
            if (!el) throw fail("bad_request", "Nothing is focused — click or fill a field first.");
            if (!insert(el, text)) {
              if (!("value" in el)) throw fail("bad_request", `${describe(el)} does not take text.`);
              el.value += text;
              el.dispatchEvent(inputEvent(text));
            }
            return { typed: describe(el) };
          }

          const KEYS = {
            Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, Space: 32,
            ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39,
            Home: 36, End: 35, PageUp: 33, PageDown: 34,
          };

          function focusables() {
            return Array.from(document.querySelectorAll(
              "a[href],button,input,select,textarea,summary,[tabindex]:not([tabindex='-1']),[contenteditable]"))
              .filter((el) => !el.disabled && !isHidden(el));
          }

          function press(key) {
            const el = focused() || document.body;
            const single = key.length === 1;
            const keyCode = KEYS[key] || (single ? key.toUpperCase().charCodeAt(0) : 0);
            if (!keyCode) {
              throw fail("bad_request",
                `Unknown key ${q(key)} (try Enter, Tab, Escape, Backspace, ArrowDown, or one character).`);
            }
            const keyValue = key === "Space" ? " " : key;
            const code = single ? (/[a-z]/i.test(key) ? "Key" + key.toUpperCase() : key) : key;
            const init = {
              key: keyValue, code, keyCode, which: keyCode, bubbles: true, cancelable: true, composed: true,
            };
            const proceed = el.dispatchEvent(new KeyboardEvent("keydown", init));
            if (proceed && keyValue.length === 1) el.dispatchEvent(new KeyboardEvent("keypress", init));
            let action = proceed ? "none" : "prevented";
            if (proceed) {
              if (key === "Enter") {
                if (el.tagName === "TEXTAREA" || el.isContentEditable) {
                  document.execCommand("insertLineBreak"); action = "newline";
                } else if (el.tagName === "INPUT" && el.form) {
                  if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
                  action = "submit";
                } else if (["A", "BUTTON", "SUMMARY"].includes(el.tagName) || roleOf(el) === "button") {
                  el.click(); action = "click";
                }
              } else if (key === "Tab") {
                const list = focusables();
                const nextEl = list[(list.indexOf(el) + 1) % Math.max(list.length, 1)];
                if (nextEl) { nextEl.focus(); action = "focus " + describe(nextEl); }
              } else if (key === "Backspace" && isEditable(el)) {
                document.execCommand("delete"); action = "delete";
              } else if (key === "Delete" && isEditable(el)) {
                document.execCommand("forwardDelete"); action = "delete";
              } else if (key === "Space"
                && (["BUTTON", "SUMMARY"].includes(el.tagName) || ["checkbox", "radio"].includes(el.type))) {
                el.click(); action = "click";
              } else if (keyValue.length === 1 && isEditable(el)) {
                insert(el, keyValue); action = "insert";
              }
            }
            el.dispatchEvent(new KeyboardEvent("keyup", init));
            return { key, target: describe(el), action };
          }

          function scroll(target, by) {
            if (target) {
              center(resolve(target));
            } else {
              window.scrollBy(0, typeof by === "number" ? by : Math.round(innerHeight * 0.8));
            }
            return {
              scrollY: Math.round(scrollY),
              scrollHeight: document.documentElement.scrollHeight,
              viewportHeight: innerHeight,
            };
          }

          function find(text, selector) {
            if (selector) {
              let el;
              try { el = document.querySelector(selector); } catch (_) {
                throw fail("bad_request", `${q(selector)} is not a CSS selector.`);
              }
              if (!el || isHidden(el)) return false;
            }
            if (text && !(document.body && document.body.innerText.includes(text))) return false;
            return true;
          }

          function readConsole(clear) {
            const entries = consoleBuffer.slice();
            if (clear) { consoleBuffer.length = 0; consoleChars = 0; }
            return { entries };
          }

          const api = {
            snapshot: (a) => snapshot(!!a.full),
            click: (a) => click(a.ref),
            fill: (a) => fill(a.ref, String(a.text == null ? "" : a.text)),
            type: (a) => type(String(a.text == null ? "" : a.text)),
            press: (a) => press(String(a.key || "")),
            select: (a) => selectOption(resolve(a.ref), String(a.value == null ? "" : a.value)),
            scroll: (a) => scroll(a.ref, a.by),
            find: (a) => find(a.text, a.selector),
            console: (a) => readConsole(!!a.clear),
            state: () => ({ readyState: document.readyState, title: document.title, url: location.href }),
          };

          window.__mpx = {
            call(name, args) {
              const fn = api[name];
              if (!fn) return { error: { code: "unknown_method", message: `No helper ${name}.` } };
              try {
                return { ok: fn(args || {}) };
              } catch (e) {
                return { error: { code: e.mpxCode || "script_error", message: String(e && e.message || e) } };
              }
            },
          };
        })();
        """#
}
