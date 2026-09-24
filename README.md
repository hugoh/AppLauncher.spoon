# AppLauncher Spoon

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Hammerspoon Spoon](https://img.shields.io/badge/Hammerspoon-Spoon-FFA500.svg)](https://www.hammerspoon.org/docs/index.html)

A Hammerspoon Spoon that binds hotkeys to launch or focus apps, open files or URLs, or run functions.

**Repository**: [https://github.com/hugoh/AppLauncher.spoon](https://github.com/hugoh/AppLauncher.spoon)

## Features

- One table of mappings per modifier set: each key focuses an app (launching it if needed), opens a file or URL, or calls a function
- Actions run straight from the hotkey callback, with no added delay
- A `●` appears in the menu bar only when an action is slow (still running after 0.2 s by default), and is always cleared, even if an action never finishes
- Each press logs when the key was received and how long the action took, so slow hotkeys are easy to spot in the Console
- Async functions get a `done` callback, so the indicator and the logged time cover the whole action

## Installation

Ensure you have [Hammerspoon](https://www.hammerspoon.org) installed, then choose a method:

### Release zip (recommended)

1. Download `AppLauncher.spoon.zip` from the [latest release](https://github.com/hugoh/AppLauncher.spoon/releases/latest)
2. Unzip — this produces an `AppLauncher.spoon` folder
3. Move it to `~/.hammerspoon/Spoons/`
4. Reload Hammerspoon (menu bar icon → Reload Config, or run `hs.reload()` in the console)

### SpoonInstall (if you already use it)

```lua
spoon.SpoonInstall:installSpoonFromZip(
  "https://github.com/hugoh/AppLauncher.spoon/releases/latest/download/AppLauncher.spoon.zip"
)
```

### Clone from git (for development or latest changes)

```bash
cd ~/.hammerspoon/Spoons
git clone https://github.com/hugoh/AppLauncher.spoon.git
```

## Configuration

```lua
local hyper = { "ctrl", "alt", "cmd" }

hs.loadSpoon("AppLauncher"):registerMappings(hyper, {
  { key = "s", app = "Slack" },
  { key = "o", app = "Microsoft Outlook", forceOpen = true },
  { key = "w", open = "https://example.com" },
  { key = "9", label = "Play/Pause", func = function() hs.eventtap.event.newSystemKeyEvent("PLAY", true):post() end },
  {
    key = "m",
    label = "Slow thing",
    async = true,
    func = function(done)
      hs.timer.doAfter(2, done) -- report when the work is finished
    end,
  },
})
```

Each mapping has a `key` and one action:

| Field | Action |
| --- | --- |
| `app` | Focus the app, bringing all its windows forward, and launch it first if it isn't running. `forceOpen = true` always goes through `hs.application.launchOrFocus` instead. `raiseWindows = true` also raises each window individually, e.g. if some don't come forward; it's off by default because it can be slow in some apps (about 150 ms per window in Obsidian), and Hammerspoon is blocked meanwhile. |
| `open` | Pass a file, folder or URL to `/usr/bin/open`. |
| `func` | Call a function. With `async = true`, it receives a `done` callback to call when finished. |
| `label` | Optional name for a `func` mapping, used in logs and alerts. |

`registerMappings` can be called more than once, for example to keep machine-specific mappings in a separate block.

Tune behaviour with `configure()` before `registerMappings` (all optional):

```lua
hs.loadSpoon("AppLauncher"):configure({
  notify = true,         -- show Hammerspoon's hotkey alert with the mapping's name on each press
  indicatorDelay = 0.2,  -- seconds an action may run before the ● appears; false to never show it
  actionTimeout = 5,     -- seconds before an unfinished action stops counting as running; false to wait forever
  logElapsedAbove = 0.1, -- seconds an action must take before its elapsed time is logged; 0 always, false never
}):registerMappings(hyper, mappings)
```

### The slow-action indicator

Hammerspoon draws the menu bar on the same main thread that runs your hotkeys, so the `●` can only appear while that thread is free: while an app is launching, `open` is running, or an async function is waiting on something. Work that blocks the main thread shows nothing. Painting the indicator before every action would mean delaying every action, so AppLauncher shows it only for actions that turn out to be slow.

If an async function never calls `done`, the action stops counting as running after `actionTimeout` and a warning is logged, so the indicator can't get stuck. A `done` that arrives after that still logs the real elapsed time.

## Security & Permissions

Focusing apps and raising their windows uses the accessibility API, so Hammerspoon needs **Accessibility** permission (System Settings → Privacy & Security → Accessibility).

## API documentation

Full [API reference](https://applauncher-spoon.larve.net/) is generated from the docstrings in `init.lua` (`mise run docs`).
