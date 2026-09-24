-- vim: set ft=lua:

--- === AppLauncher ===
---
--- A Hammerspoon Spoon that binds hotkeys to launch or focus apps, open files
--- or URLs, or run functions.
---
--- Actions run straight from the hotkey callback. If one is still running
--- after a short delay, a `●` appears in the menu bar until it finishes. Each
--- press also logs when the key was received and how long the action took, so
--- slow hotkeys are easy to spot in the Console.
---
--- Download: https://github.com/hugoh/AppLauncher.spoon/releases/latest

local obj = {}
obj.__index = obj

obj.name = "AppLauncher"
obj.version = "dev"
obj.author = "Hugo Haas"
obj.license = "MIT"
obj.homepage = "https://github.com/hugoh/AppLauncher.spoon"

--- AppLauncher.notify
--- Variable
--- Show Hammerspoon's hotkey alert with the mapping's name on each press (default: false).
obj.notify = false

--- AppLauncher.indicatorDelay
--- Variable
--- Seconds an action may run before a `●` appears in the menu bar, or `false`
--- to never show it (default: 0.2). The indicator can only appear while
--- Hammerspoon's main thread is free, e.g. while an app launches or an `async`
--- function waits; work that blocks the main thread shows nothing.
obj.indicatorDelay = 0.2

--- AppLauncher.actionTimeout
--- Variable
--- Seconds after which an action that hasn't finished (e.g. an `async`
--- function that never calls `done`) stops counting as running, so the
--- indicator can't get stuck; `false` to wait forever (default: 5).
obj.actionTimeout = 5

--- AppLauncher.logElapsedAbove
--- Variable
--- Seconds an action must take before its elapsed time is logged, `0` to
--- always log it, or `false` to never log it (default: 0.1).
obj.logElapsedAbove = 0.1

obj.log = hs.logger.new("AppLauncher", "info")

--- AppLauncher:init()
--- Method
--- Called automatically by `hs.loadSpoon()`. Logs the loaded version.
function obj:init()
	self.log.f("Loaded %s v%s", self.name, self.version)
	return self
end

-- Seconds to wait after launching an app before activating it.
local LAUNCH_SETTLE_DELAY = 1

local pending = 0
local indicator
local indicatorTimer

-- Hammerspoon may garbage-collect a running hs.task or hs.timer that nothing
-- references, silently dropping its callback.
local inFlight = {}

local function showIndicator()
	indicatorTimer = nil
	if pending > 0 and not indicator then
		local bar = hs.menubar.new()
		if bar then indicator = bar:setTitle("●") end
	end
end

local function busyStart()
	pending = pending + 1
	if obj.indicatorDelay and not indicator and not indicatorTimer then
		indicatorTimer = hs.timer.doAfter(obj.indicatorDelay, showIndicator)
	end
end

local function busyDone()
	pending = math.max(0, pending - 1)
	if pending > 0 then return end
	if indicatorTimer then
		indicatorTimer:stop()
		indicatorTimer = nil
	end
	if indicator then
		indicator:delete()
		indicator = nil
	end
end

-- Counts an action as running until the returned function is called, or
-- until actionTimeout. Calling it more than once has no further effect.
local function track(chord, name)
	busyStart()
	local released = false
	local timeout
	local function release()
		if released then return end
		released = true
		if timeout then timeout:stop() end
		busyDone()
	end
	if obj.actionTimeout then
		timeout = hs.timer.doAfter(obj.actionTimeout, function()
			obj.log.wf("Key %s (%s) still running after %g s; no longer tracked", chord, name, obj.actionTimeout)
			release()
		end)
	end
	return release
end

local function mappingName(m) return m.app or m.open or m.label or "function" end

local function raiseWindows(app)
	for _, win in ipairs(app:allWindows()) do
		win:raise()
	end
end

local function focus(app, m)
	app:activate(true)
	if m.raiseWindows then raiseWindows(app) end
end

local function openApp(m, done)
	if m.forceOpen then
		hs.application.launchOrFocus(m.app)
		return done()
	end

	local app = hs.application.find(m.app, true)
	if app then
		focus(app, m)
		return done()
	end

	hs.application.launchOrFocus(m.app)
	local settle
	settle = hs.timer.doAfter(LAUNCH_SETTLE_DELAY, function()
		inFlight[settle] = nil
		local launchedApp = hs.application.find(m.app, true)
		if launchedApp then focus(launchedApp, m) end
		done()
	end)
	inFlight[settle] = true
end

local function openTarget(m, done)
	local task
	task = hs.task.new("/usr/bin/open", function()
		inFlight[task] = nil
		done()
	end, { m.open })
	if task and task:start() then
		inFlight[task] = true
	else
		done()
	end
end

function obj:_launch(m, mods)
	local chord = #mods > 0 and table.concat(mods, "+") .. "+" .. m.key or m.key
	self.log.f("Key %s received: %s", chord, mappingName(m))

	local started = hs.timer.absoluteTime()
	local function finished()
		local elapsed = (hs.timer.absoluteTime() - started) / 1e9
		if type(self.logElapsedAbove) == "number" and elapsed >= self.logElapsedAbove then
			self.log.f("Key %s done in %.0f ms", chord, elapsed * 1e3)
		end
	end
	if m.func and not m.async then
		m.func()
		return finished()
	end

	local release = track(chord, mappingName(m))
	local function asyncDone()
		release()
		finished()
	end

	if m.func then
		local ok, err = pcall(m.func, asyncDone)
		if not ok then
			asyncDone()
			error(err, 0)
		end
	elseif m.open then
		openTarget(m, asyncDone)
	elseif m.app then
		openApp(m, asyncDone)
	end
end

--- AppLauncher:configure(opts) -> AppLauncher
--- Method
--- Sets one or more of AppLauncher's variables (`notify`, `indicatorDelay`,
--- `actionTimeout`, `logElapsedAbove`) from a table. Call it before `registerMappings`, since `notify`
--- is read when hotkeys are bound.
---
--- Parameters:
---  * opts - a table with any of the variable names above as keys
---
--- Returns:
---  * The AppLauncher object, for method chaining
function obj:configure(opts)
	for _, key in ipairs({ "notify", "indicatorDelay", "actionTimeout", "logElapsedAbove" }) do
		if opts[key] ~= nil then self[key] = opts[key] end
	end
	return self
end

--- AppLauncher:registerMappings(mods, mappings) -> AppLauncher
--- Method
--- Binds a hotkey for each mapping.
---
--- Parameters:
---  * mods - a table of modifier keys shared by all mappings, e.g. `{ "ctrl", "alt", "cmd" }`
---  * mappings - a list of tables, each with a `key` and one action:
---    * `app` - name of an app to focus, launching it if needed; set `forceOpen = true`
---      to always go through `hs.application.launchOrFocus`; activating brings all
---      of the app's windows forward, and `raiseWindows = true` also raises each
---      window individually (off by default: it can take ~150 ms per window in
---      some apps, e.g. Electron ones, blocking Hammerspoon meanwhile)
---    * `open` - a file, folder or URL passed to `/usr/bin/open`
---    * `func` - a function to call; with `async = true` it receives a `done`
---      callback to call when finished; the action counts as running until then
---    * `label` - optional name for a `func` mapping, used in logs and alerts
---
--- Returns:
---  * The AppLauncher object, for method chaining
function obj:registerMappings(mods, mappings)
	for _, m in ipairs(mappings) do
		if not (m.app or m.open or m.func) then
			error(string.format("AppLauncher: mapping for key %q needs app, open or func", tostring(m.key)), 2)
		end
		local message = self.notify and mappingName(m) or nil
		hs.hotkey.bind(mods, m.key, message, function() self:_launch(m, mods) end)
	end
	return self
end

return obj
