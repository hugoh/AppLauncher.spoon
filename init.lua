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
--- indicator can't get stuck; `false` to wait forever (default: 10).
obj.actionTimeout = 10

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

local function showIndicator()
	indicatorTimer = nil
	if pending > 0 then indicator = indicator or hs.menubar.new():setTitle("●") end
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

local function focus(app)
	app:activate(true)
	raiseWindows(app)
end

local function openApp(appName, forceOpen, done)
	if forceOpen then
		hs.application.launchOrFocus(appName)
		return done()
	end

	local app = hs.application.find(appName, true)
	if app then
		focus(app)
		return done()
	end

	hs.application.launchOrFocus(appName)
	hs.timer.doAfter(LAUNCH_SETTLE_DELAY, function()
		local launchedApp = hs.application.find(appName, true)
		if launchedApp then focus(launchedApp) end
		done()
	end)
end

function obj:_launch(m, mods)
	local chord = #mods > 0 and table.concat(mods, "+") .. "+" .. m.key or m.key
	self.log.f("Key %s received: %s", chord, mappingName(m))

	local started = hs.timer.absoluteTime()
	local function finished() self.log.f("Key %s done in %.0f ms", chord, (hs.timer.absoluteTime() - started) / 1e6) end
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
		m.func(asyncDone)
	elseif m.open then
		hs.task.new("/usr/bin/open", asyncDone, { m.open }):start()
	elseif m.app then
		openApp(m.app, m.forceOpen or false, asyncDone)
	end
end

--- AppLauncher:configure(opts) -> AppLauncher
--- Method
--- Sets one or more of AppLauncher's variables (`notify`, `indicatorDelay`,
--- `actionTimeout`) from a table. Call it before `registerMappings`, since `notify`
--- is read when hotkeys are bound.
---
--- Parameters:
---  * opts - a table with any of the variable names above as keys
---
--- Returns:
---  * The AppLauncher object, for method chaining
function obj:configure(opts)
	for _, key in ipairs({ "notify", "indicatorDelay", "actionTimeout" }) do
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
---      to always go through `hs.application.launchOrFocus`
---    * `open` - a file, folder or URL passed to `/usr/bin/open`
---    * `func` - a function to call; with `async = true` it receives a `done`
---      callback to call when finished; the action counts as running until then
---    * `label` - optional name for a `func` mapping, used in logs and alerts
---
--- Returns:
---  * The AppLauncher object, for method chaining
function obj:registerMappings(mods, mappings)
	for _, m in ipairs(mappings) do
		local message = self.notify and mappingName(m) or nil
		hs.hotkey.bind(mods, m.key, message, function() self:_launch(m, mods) end)
	end
	return self
end

return obj
