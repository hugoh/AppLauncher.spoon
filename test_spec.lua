-- Busted tests for the AppLauncher Spoon using the shared hs_mock from spoon-tools.

local hs_mock = require("hs_mock")

local ctl
local AppLauncher

local HYPER = { "ctrl", "alt", "cmd" }

local function makeApp(windowCount)
	local app = { _activated = {}, _raised = 0, _windows = {} }
	for _ = 1, windowCount or 1 do
		table.insert(app._windows, { raise = function() app._raised = app._raised + 1 end })
	end
	function app:activate(allWindows) table.insert(self._activated, allWindows) end
	function app:allWindows() return self._windows end
	function app:mainWindow() return self._windows[1] end
	return app
end

before_each(function()
	local hs
	hs, ctl = hs_mock.new()
	_G.hs = hs

	-- Local, not in hs_mock: this asserts AppLauncher's own lookups are exact; it
	-- isn't a fake of Hammerspoon.
	local find = hs.application.find
	hs.application.find = function(name, exact)
		assert.is_true(exact, "application lookup must be exact")
		return find(name)
	end

	AppLauncher = dofile("init.lua")
end)

local function hotkey(key)
	for i = #ctl.hotkeys, 1, -1 do
		if ctl.hotkeys[i].key == key then return ctl.hotkeys[i] end
	end
end

local function press(key) hotkey(key).pressed() end

local function indicatorShown()
	local bar = ctl.menubars[#ctl.menubars]
	return bar ~= nil and not bar._deleted
end

local function registerAsync(key)
	local finishers = {}
	AppLauncher:registerMappings(HYPER, {
		{ key = key, async = true, func = function(done) table.insert(finishers, done) end },
	})
	return finishers
end

describe("configure", function()
	it("overrides only the provided keys", function()
		AppLauncher:configure({ indicatorDelay = 0.5 })
		assert.are.equal(0.5, AppLauncher.indicatorDelay)
		assert.is_false(AppLauncher.notify)
	end)

	it("sets actionTimeout", function()
		AppLauncher:configure({ actionTimeout = 30 })
		assert.are.equal(30, AppLauncher.actionTimeout)
	end)

	it("accepts false to turn the indicator off", function()
		AppLauncher:configure({ indicatorDelay = false })
		assert.is_false(AppLauncher.indicatorDelay)
	end)

	it("ignores unknown keys", function()
		AppLauncher:configure({ bogus = 1 })
		assert.is_nil(AppLauncher.bogus)
	end)

	it("returns self for chaining", function() assert.are.equal(AppLauncher, AppLauncher:configure({})) end)
end)

describe("registerMappings", function()
	it("binds each mapping's key with the given modifiers", function()
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" }, { key = "n", app = "Obsidian" } })
		assert.are.same(HYPER, hotkey("s").mods)
		assert.is_truthy(hotkey("n"))
	end)

	it("shows no hotkey alert unless notify is set", function()
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })
		assert.is_nil(hotkey("s").message)
	end)

	it("shows the mapping's name as the hotkey alert when notify is set", function()
		AppLauncher.notify = true
		AppLauncher:registerMappings(HYPER, {
			{ key = "s", app = "Slack" },
			{ key = "d", func = function() end, label = "My Day" },
		})
		assert.are.equal("Slack", hotkey("s").message)
		assert.are.equal("My Day", hotkey("d").message)
	end)

	it(
		"returns self for chaining",
		function() assert.are.equal(AppLauncher, AppLauncher:registerMappings(HYPER, {})) end
	)
end)

describe("app mappings", function()
	it("activates a running app from the hotkey callback without raising its windows", function()
		local slack = makeApp(2)
		ctl.apps.Slack = slack
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })

		press("s")

		assert.are.same({ true }, slack._activated)
		assert.are.equal(0, slack._raised)
		assert.are.same({}, ctl.launched)
	end)

	it("also raises each window when raiseWindows is true", function()
		local slack = makeApp(2)
		ctl.apps.Slack = slack
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack", raiseWindows = true } })

		press("s")

		assert.are.same({ true }, slack._activated)
		assert.are.equal(2, slack._raised)
	end)

	it("raises windows after a launch too when raiseWindows is true", function()
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack", raiseWindows = true } })

		press("s")
		local slack = makeApp(2)
		ctl.apps.Slack = slack
		ctl.advance(1)

		assert.are.same({ true }, slack._activated)
		assert.are.equal(2, slack._raised)
	end)

	it("launches an app that isn't running, then activates it once it's up", function()
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })

		press("s")
		assert.are.same({ "Slack" }, ctl.launched)

		local slack = makeApp()
		ctl.apps.Slack = slack
		ctl.advance(1)
		assert.are.same({ true }, slack._activated)
	end)

	-- Activating doesn't reopen a window; launchOrFocus sends the reopen event
	-- that clicking the Dock icon would.
	it("goes through launchOrFocus for a running app with no windows", function()
		local slack = makeApp(0)
		ctl.apps.Slack = slack
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })

		press("s")

		assert.are.same({ "Slack" }, ctl.launched)
		assert.are.same({}, slack._activated)
	end)

	it("only calls launchOrFocus when forceOpen is set", function()
		local slack = makeApp()
		ctl.apps.Slack = slack
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack", forceOpen = true } })

		press("s")

		assert.are.same({ "Slack" }, ctl.launched)
		assert.are.same({}, slack._activated)
	end)
end)

describe("open mappings", function()
	it("runs /usr/bin/open with the target from the hotkey callback", function()
		AppLauncher:registerMappings(HYPER, { { key = "w", open = "https://example.com" } })

		press("w")

		local task = ctl.tasks[1]
		assert.are.equal("/usr/bin/open", task._path)
		assert.are.same({ "https://example.com" }, task._args)
		assert.is_true(task:isRunning())
	end)
end)

describe("func mappings", function()
	it("calls a synchronous func straight away", function()
		local calls = 0
		AppLauncher:registerMappings(HYPER, { { key = "d", func = function() calls = calls + 1 end } })

		press("d")

		assert.are.equal(1, calls)
		assert.are.same({}, ctl.timers())
	end)

	it("calls an async func straight away with a done callback", function()
		local finishers = registerAsync("m")

		press("m")

		assert.are.equal(1, #finishers)
	end)
end)

describe("slow-action indicator", function()
	it("never appears for an action that finishes before indicatorDelay", function()
		ctl.apps.Slack = makeApp()
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })

		press("s")
		ctl.flush()

		assert.are.equal(0, #ctl.menubars)
	end)

	it("appears after indicatorDelay while an action is still running, and goes once it's done", function()
		local finishers = registerAsync("m")

		press("m")
		assert.are.equal(0.2, ctl.timers()[1]:nextTrigger())
		assert.are.equal(0, #ctl.menubars)

		ctl.advance(0.2)
		assert.is_true(indicatorShown())

		finishers[1]()
		assert.is_false(indicatorShown())
	end)

	it("shows while a launched app settles and clears once it's focused", function()
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })

		press("s")
		ctl.advance(0.2)
		assert.is_true(indicatorShown())

		ctl.apps.Slack = makeApp()
		ctl.advance(1)
		assert.is_false(indicatorShown())
	end)

	it("shows while open is running and clears when it exits", function()
		AppLauncher:registerMappings(HYPER, { { key = "w", open = "https://example.com" } })

		press("w")
		ctl.advance(0.2)
		assert.is_true(indicatorShown())

		ctl.tasks[1]:complete(0, "", "")
		assert.is_false(indicatorShown())
	end)

	it("stays up until every in-flight action has finished", function()
		local finishers = registerAsync("m")

		press("m")
		press("m")
		ctl.advance(0.2)
		assert.are.equal(1, #ctl.menubars)

		finishers[1]()
		assert.is_true(indicatorShown())
		finishers[2]()
		assert.is_false(indicatorShown())
	end)

	it("cancels the pending timer once everything is done", function()
		local finishers = registerAsync("m")

		press("m")
		finishers[1]()

		assert.are.same({}, ctl.timers())
	end)

	it("is never shown when indicatorDelay is false", function()
		AppLauncher:configure({ indicatorDelay = false })
		registerAsync("m")

		press("m")
		ctl.advance(1)

		assert.are.equal(0, #ctl.menubars)
	end)
end)

describe("action timeout", function()
	it("clears the indicator and warns when an action never reports done", function()
		AppLauncher:registerMappings(HYPER, {
			{ key = "m", async = true, label = "Stuck", func = function() end },
		})

		press("m")
		ctl.advance(0.2)
		assert.is_true(indicatorShown())

		ctl.advance(AppLauncher.actionTimeout)
		assert.is_false(indicatorShown())
		assert.are.same(
			{ "Key ctrl+alt+cmd+m (Stuck) still running after 5 s; no longer tracked" },
			ctl.logged("warning")
		)
	end)

	it("lets the next slow action show the indicator again", function()
		AppLauncher:registerMappings(HYPER, { { key = "m", async = true, func = function() end } })

		press("m")
		ctl.flush()
		press("m")
		ctl.advance(0.2)

		assert.is_true(indicatorShown())
	end)

	it("ignores a late done so it can't clear another action's indicator", function()
		local finishers = registerAsync("m")

		press("m")
		ctl.flush()
		press("m")
		ctl.advance(0.2)

		finishers[1]()
		assert.is_true(indicatorShown())
		finishers[2]()
		assert.is_false(indicatorShown())
	end)

	it("still logs the real elapsed time when done arrives late", function()
		local finishers = registerAsync("m")

		press("m")
		ctl.flush()
		ctl.now = 12
		finishers[1]()

		assert.are.equal("Key ctrl+alt+cmd+m done in 12000 ms", ctl.logged("info")[#ctl.logged("info")])
	end)

	it("is cancelled when the action finishes in time", function()
		local finishers = registerAsync("m")

		press("m")
		finishers[1]()

		assert.are.same({}, ctl.timers())
	end)

	it("can be turned off with false", function()
		AppLauncher:configure({ actionTimeout = false })
		registerAsync("m")

		press("m")
		ctl.flush()

		assert.is_true(indicatorShown())
	end)
end)

describe("logging", function()
	it("logs the chord on receipt but not a fast action's elapsed time", function()
		local finish
		AppLauncher:registerMappings(HYPER, {
			{ key = "m", async = true, label = "Mute", func = function(done) finish = done end },
		})

		press("m")
		ctl.now = 0.042
		finish()

		assert.are.same({
			"Key ctrl+alt+cmd+m received: Mute",
		}, ctl.logged("info"))
	end)

	it("logs the elapsed time only above logElapsedAbove", function()
		local finish
		AppLauncher:registerMappings(HYPER, {
			{ key = "m", async = true, label = "Mute", func = function(done) finish = done end },
		})

		press("m")
		ctl.now = 0.15
		finish()

		assert.are.same({
			"Key ctrl+alt+cmd+m received: Mute",
			"Key ctrl+alt+cmd+m done in 150 ms",
		}, ctl.logged("info"))
	end)

	it("always logs the elapsed time with logElapsedAbove = 0", function()
		AppLauncher:configure({ logElapsedAbove = 0 })
		AppLauncher:registerMappings(HYPER, { { key = "m", func = function() end } })

		press("m")

		assert.are.equal("Key ctrl+alt+cmd+m done in 0 ms", ctl.logged("info")[#ctl.logged("info")])
	end)

	it("never logs the elapsed time with logElapsedAbove = false", function()
		AppLauncher:configure({ logElapsedAbove = false })
		local finishers = registerAsync("m")

		press("m")
		ctl.now = 60
		finishers[1]()

		assert.are.same({ "Key ctrl+alt+cmd+m received: function" }, ctl.logged("info"))
	end)
end)

describe("robustness", function()
	local function weakly(list) return setmetatable(list, { __mode = "v" }) end

	it("finishes an open action whose task fails to start", function()
		hs.task.new = function()
			return { start = function() return false end }
		end
		AppLauncher:registerMappings(HYPER, { { key = "w", open = "https://example.com" } })

		press("w")
		ctl.advance(0.2)

		assert.is_false(indicatorShown())
	end)

	it("keeps the launch settle timer alive until it fires", function()
		local settles = weakly({})
		-- A stub the mock doesn't track, so only AppLauncher can keep it alive.
		hs.timer.doAfter = function(delay, fn)
			local t = { _fn = fn, stop = function() end }
			if delay == 1 then table.insert(settles, t) end
			return t
		end
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })

		press("s")
		collectgarbage("collect")
		assert.is_not_nil(settles[1])

		settles[1]._fn()
		collectgarbage("collect")
		assert.is_nil(settles[1])
	end)

	it("stops tracking an async func that raises, and re-raises its error", function()
		AppLauncher:configure({ actionTimeout = false })
		AppLauncher:registerMappings(HYPER, {
			{ key = "m", async = true, func = function() error("boom", 0) end },
		})

		assert.has_error(function() press("m") end, "boom")
		ctl.advance(0.2)

		assert.is_false(indicatorShown())
	end)

	it("rejects a mapping with no action", function()
		assert.has_error(
			function() AppLauncher:registerMappings(HYPER, { { key = "x", async = true } }) end,
			'AppLauncher: mapping for key "x" needs app, open or func'
		)
	end)

	it("survives hs.menubar.new returning nil", function()
		hs.menubar.new = function() return nil end
		local finishers = registerAsync("m")

		press("m")
		ctl.advance(0.2)
		finishers[1]()
	end)

	it("doesn't fail on a non-numeric logElapsedAbove", function()
		AppLauncher:configure({ logElapsedAbove = true })
		AppLauncher:registerMappings(HYPER, { { key = "d", func = function() end } })

		press("d")
	end)
end)

describe("init", function()
	it("logs the loaded version", function()
		assert.are.equal(AppLauncher, AppLauncher:init())
		assert.are.same({ "Loaded AppLauncher vdev" }, ctl.logged("info"))
	end)
end)
