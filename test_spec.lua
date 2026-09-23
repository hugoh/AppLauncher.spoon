-- Busted tests for the AppLauncher Spoon using a mock hs environment.

local mock_hs
local AppLauncher

local HYPER = { "ctrl", "alt", "cmd" }

local function makeLogger()
	local l = { _infos = {}, _warnings = {} }
	l.f = function(fmt, ...) table.insert(l._infos, string.format(fmt, ...)) end
	l.wf = function(fmt, ...) table.insert(l._warnings, string.format(fmt, ...)) end
	return l
end

local function makeApp(windowCount)
	local app = { _activated = {}, _raised = 0, _windows = {} }
	for _ = 1, windowCount or 1 do
		table.insert(app._windows, { raise = function() app._raised = app._raised + 1 end })
	end
	function app:activate(allWindows) table.insert(self._activated, allWindows) end
	function app:allWindows() return self._windows end
	return app
end

before_each(function()
	local timers = {}
	mock_hs = {
		_now = 0,
		_hotkeys = {},
		_apps = {},
		_launched = {},
		_tasks = {},
		_menubars = {},
	}
	mock_hs.logger = { new = function() return makeLogger() end }

	mock_hs.timer = {
		_pending = timers,
		absoluteTime = function() return mock_hs._now end,
		doAfter = function(delay, fn)
			local t = { _delay = delay, _fn = fn, _stopped = false }
			function t:stop() self._stopped = true end
			table.insert(timers, t)
			return t
		end,
	}
	-- Fire pending timers in the order they were scheduled, skipping stopped
	-- ones; callbacks may schedule more.
	mock_hs._fireTimers = function()
		while #timers > 0 do
			local t = table.remove(timers, 1)
			if not t._stopped then t._fn() end
		end
	end
	-- Fire, in scheduling order, every live timer due within `seconds`
	-- (delays are treated as relative to the press).
	mock_hs._advance = function(seconds)
		local fired = true
		while fired do
			fired = false
			for i, t in ipairs(timers) do
				if not t._stopped and t._delay <= seconds then
					table.remove(timers, i)
					t._fn()
					fired = true
					break
				end
			end
		end
	end
	mock_hs._liveTimers = function()
		local live = {}
		for _, t in ipairs(timers) do
			if not t._stopped then table.insert(live, t) end
		end
		return live
	end

	mock_hs.hotkey = {
		bind = function(mods, key, message, fn)
			local hk = { _mods = mods, _key = key, _message = message, _fn = fn }
			mock_hs._hotkeys[key] = hk
			return hk
		end,
	}

	mock_hs.application = {
		find = function(name, exact)
			assert.is_true(exact, "application lookup must be exact")
			return mock_hs._apps[name]
		end,
		launchOrFocus = function(name) table.insert(mock_hs._launched, name) end,
	}

	mock_hs.task = {
		new = function(path, callback, args)
			local task = { _path = path, _callback = callback, _args = args, _started = false }
			function task:start()
				self._started = true
				return self
			end
			table.insert(mock_hs._tasks, task)
			return task
		end,
	}

	mock_hs.menubar = {
		new = function()
			local bar = { _deleted = false }
			function bar:setTitle(title)
				self._title = title
				return self
			end
			function bar:delete() self._deleted = true end
			table.insert(mock_hs._menubars, bar)
			return bar
		end,
	}

	package.loaded.hs = nil
	_G.hs = mock_hs

	AppLauncher = dofile("init.lua")
end)

local function press(key) mock_hs._hotkeys[key]._fn() end

local function indicatorShown()
	local bar = mock_hs._menubars[#mock_hs._menubars]
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
		assert.are.same(HYPER, mock_hs._hotkeys.s._mods)
		assert.is_truthy(mock_hs._hotkeys.n)
	end)

	it("shows no hotkey alert unless notify is set", function()
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })
		assert.is_nil(mock_hs._hotkeys.s._message)
	end)

	it("shows the mapping's name as the hotkey alert when notify is set", function()
		AppLauncher.notify = true
		AppLauncher:registerMappings(HYPER, {
			{ key = "s", app = "Slack" },
			{ key = "d", func = function() end, label = "My Day" },
		})
		assert.are.equal("Slack", mock_hs._hotkeys.s._message)
		assert.are.equal("My Day", mock_hs._hotkeys.d._message)
	end)

	it(
		"returns self for chaining",
		function() assert.are.equal(AppLauncher, AppLauncher:registerMappings(HYPER, {})) end
	)
end)

describe("app mappings", function()
	it("activates a running app and raises its windows from the hotkey callback", function()
		local slack = makeApp(2)
		mock_hs._apps.Slack = slack
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })

		press("s")

		assert.are.same({ true }, slack._activated)
		assert.are.equal(2, slack._raised)
		assert.are.same({}, mock_hs._launched)
	end)

	it("launches an app that isn't running, then activates it once it's up", function()
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })

		press("s")
		assert.are.same({ "Slack" }, mock_hs._launched)

		local slack = makeApp()
		mock_hs._apps.Slack = slack
		mock_hs._advance(1)
		assert.are.same({ true }, slack._activated)
	end)

	it("only calls launchOrFocus when forceOpen is set", function()
		local slack = makeApp()
		mock_hs._apps.Slack = slack
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack", forceOpen = true } })

		press("s")

		assert.are.same({ "Slack" }, mock_hs._launched)
		assert.are.same({}, slack._activated)
	end)
end)

describe("open mappings", function()
	it("runs /usr/bin/open with the target from the hotkey callback", function()
		AppLauncher:registerMappings(HYPER, { { key = "w", open = "https://example.com" } })

		press("w")

		local task = mock_hs._tasks[1]
		assert.are.equal("/usr/bin/open", task._path)
		assert.are.same({ "https://example.com" }, task._args)
		assert.is_true(task._started)
	end)
end)

describe("func mappings", function()
	it("calls a synchronous func straight away", function()
		local calls = 0
		AppLauncher:registerMappings(HYPER, { { key = "d", func = function() calls = calls + 1 end } })

		press("d")

		assert.are.equal(1, calls)
		assert.are.same({}, mock_hs._liveTimers())
	end)

	it("calls an async func straight away with a done callback", function()
		local finishers = registerAsync("m")

		press("m")

		assert.are.equal(1, #finishers)
	end)
end)

describe("slow-action indicator", function()
	it("never appears for an action that finishes before indicatorDelay", function()
		mock_hs._apps.Slack = makeApp()
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })

		press("s")
		mock_hs._fireTimers()

		assert.are.equal(0, #mock_hs._menubars)
	end)

	it("appears after indicatorDelay while an action is still running, and goes once it's done", function()
		local finishers = registerAsync("m")

		press("m")
		assert.are.equal(0.2, mock_hs._liveTimers()[1]._delay)
		assert.are.equal(0, #mock_hs._menubars)

		mock_hs._advance(0.2)
		assert.is_true(indicatorShown())

		finishers[1]()
		assert.is_false(indicatorShown())
	end)

	it("shows while a launched app settles and clears once it's focused", function()
		AppLauncher:registerMappings(HYPER, { { key = "s", app = "Slack" } })

		press("s")
		mock_hs._advance(0.2)
		assert.is_true(indicatorShown())

		mock_hs._apps.Slack = makeApp()
		mock_hs._advance(1)
		assert.is_false(indicatorShown())
	end)

	it("shows while open is running and clears when it exits", function()
		AppLauncher:registerMappings(HYPER, { { key = "w", open = "https://example.com" } })

		press("w")
		mock_hs._advance(0.2)
		assert.is_true(indicatorShown())

		mock_hs._tasks[1]._callback(0, "", "")
		assert.is_false(indicatorShown())
	end)

	it("stays up until every in-flight action has finished", function()
		local finishers = registerAsync("m")

		press("m")
		press("m")
		mock_hs._advance(0.2)
		assert.are.equal(1, #mock_hs._menubars)

		finishers[1]()
		assert.is_true(indicatorShown())
		finishers[2]()
		assert.is_false(indicatorShown())
	end)

	it("cancels the pending timer once everything is done", function()
		local finishers = registerAsync("m")

		press("m")
		finishers[1]()

		assert.are.same({}, mock_hs._liveTimers())
	end)

	it("is never shown when indicatorDelay is false", function()
		AppLauncher:configure({ indicatorDelay = false })
		registerAsync("m")

		press("m")
		mock_hs._advance(1)

		assert.are.equal(0, #mock_hs._menubars)
	end)
end)

describe("action timeout", function()
	it("clears the indicator and warns when an action never reports done", function()
		AppLauncher:registerMappings(HYPER, {
			{ key = "m", async = true, label = "Stuck", func = function() end },
		})

		press("m")
		mock_hs._advance(0.2)
		assert.is_true(indicatorShown())

		mock_hs._advance(AppLauncher.actionTimeout)
		assert.is_false(indicatorShown())
		assert.are.same(
			{ "Key ctrl+alt+cmd+m (Stuck) still running after 10 s; no longer tracked" },
			AppLauncher.log._warnings
		)
	end)

	it("lets the next slow action show the indicator again", function()
		AppLauncher:registerMappings(HYPER, { { key = "m", async = true, func = function() end } })

		press("m")
		mock_hs._fireTimers()
		press("m")
		mock_hs._advance(0.2)

		assert.is_true(indicatorShown())
	end)

	it("ignores a late done so it can't clear another action's indicator", function()
		local finishers = registerAsync("m")

		press("m")
		mock_hs._fireTimers()
		press("m")
		mock_hs._advance(0.2)

		finishers[1]()
		assert.is_true(indicatorShown())
		finishers[2]()
		assert.is_false(indicatorShown())
	end)

	it("still logs the real elapsed time when done arrives late", function()
		local finishers = registerAsync("m")

		press("m")
		mock_hs._fireTimers()
		mock_hs._now = 12e9
		finishers[1]()

		assert.are.equal("Key ctrl+alt+cmd+m done in 12000 ms", AppLauncher.log._infos[#AppLauncher.log._infos])
	end)

	it("is cancelled when the action finishes in time", function()
		local finishers = registerAsync("m")

		press("m")
		finishers[1]()

		assert.are.same({}, mock_hs._liveTimers())
	end)

	it("can be turned off with false", function()
		AppLauncher:configure({ actionTimeout = false })
		registerAsync("m")

		press("m")
		mock_hs._fireTimers()

		assert.is_true(indicatorShown())
	end)
end)

describe("logging", function()
	it("logs the chord on receipt and the elapsed time once done", function()
		local finish
		AppLauncher:registerMappings(HYPER, {
			{ key = "m", async = true, label = "Mute", func = function(done) finish = done end },
		})

		press("m")
		mock_hs._now = 42e6
		finish()

		assert.are.same({
			"Key ctrl+alt+cmd+m received: Mute",
			"Key ctrl+alt+cmd+m done in 42 ms",
		}, AppLauncher.log._infos)
	end)
end)
