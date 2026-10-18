# Cat Run

A small native macOS menu bar utility that keeps a Mac awake for a chosen time. Created by Nikhil Sharma with assistance from OpenAI ChatGPT models. Last updated: October 17, 2026.

Inspired by Caffeine by Dominic Rodemer.

Version 0.3.1 places View logs directly beneath Back, centered on the Launch at login row, with matching button size.

Version 0.3.0 adds a concise reason whenever a timer stops, an encrypted seven-day activity history in Settings, and visibly faded duration controls while a timer runs. Logs use date-only separators and show the most recently recorded activity first.

Earlier releases corrected the unavailable-forecast warning after unplugging, strengthened interruption handling, and fixed clipping around the duration slider and script wordmark. An unavailable battery-runtime estimate means **unknown**, not that the battery is predicted to fall below 15%; it does not require confirmation when the actual charge reading is valid.

## Behavior

- Choose 15 minutes to 6 hours in 15-minute increments. Hours and minutes use two-digit values, such as `15m` and `01h 15m`; hours are omitted below one hour. The countdown uses the same notation, such as `03m` or `01h 03m`. The three most recently started, distinct durations are saved for quick reuse.
- Keep Mac awake is required during a timer. Keeping the display awake is optional. That choice and start at login can be changed only while the timer is inactive.
- A static menu bar cat becomes periodically animated during a timer. A small two-line countdown shows two-digit hours above minutes beside the cat, for example `01` above `03`. Click to open the window; right-click for Open and Quit.
- Below 15% battery, a timer cannot start and an active timer stops, including while connected to power. Exactly 15% is allowed. An unavailable charge reading blocks or stops a timer on a battery-equipped Mac. Missing runtime estimates are different: a valid charge reading remains usable without a forecast.
- A settled forecast below 15% warns before activation or extension. If a low projection becomes available during a running timer, including after unplugging, a short notice appears in the existing window without opening a confirmation dialog. Predictions never replace the actual-charge cutoff or guarantee a duration.
- Every stop uses “Timer stopped · Reason”, for example “Time elapsed”, “Stopped by you”, or “Battery below 15%”. A known stop date, time, and timezone appear below, using the Mac’s current region and timezone. The recorded instant stays fixed when the window is reopened or refreshed. The most recent session outcome survives app relaunch; starting another timer replaces it.
- Sleep, user switching, logout/restart/shutdown, and detected app stalls stop the timer. Wake and relaunch always leave it inactive. macOS does not reliably distinguish every system-ending request, so those share a reason. An unfinished record after an app crash, force quit, Mac crash, or power loss shows “Timer stopped · Unexpected interruption” and “Cause and stop time unknown.” The activity log records when that interruption was detected. Sleep first detected after waking also has an unknown stop time; its notice explicitly labels the detection date instead.
- Stopping releases Cat Run's sleep prevention. macOS and other apps decide when the computer actually sleeps. The app does not force an immediate sleep.
- Closing the window leaves an active timer running. Quitting ends it. Saved preferences and recent durations survive relaunch; a timer does not resume automatically.
- The window uses a fixed black background with peach (`#FBC193`) text and outlines. Main and Settings screens do not scroll; only Activity logs scroll. The disabled duration slider and its minus/plus symbols and borders visibly fade while a timer runs, with no pressed feedback. Ordinary labels retain their brightness, and the separate +15m extension remains available when allowed. Verdana is used for controls; the Cat Run wordmark uses a script face. The header uses the same sitting cat artwork as the idle menu-bar icon. Settings and Back lettering is centered inside its button. The duration slider has a rounded track and thumb centered between its minus and plus buttons. Hovering over the lock beside Keep Mac awake shows “Keeps your Mac awake whenever you start a timer.” above the icon. The duration value uses the same 15pt Verdana text size as its label. Start and Stop occupy exactly the same space in every timer state.
- No session notifications, telemetry, accounts, ads, or cloud service.

## Activity history and privacy

Open **Settings → View logs** to inspect activity in the same window at its current size. **Back** returns to Settings. The scrolling list has clear date-only headings such as “17 Oct 2026”; it does not use Today or Yesterday. The current date heading remains visible while scrolling. Each entry shows local time, including seconds and timezone for audit clarity, beside a short explanation. The running countdown and stop notice continue to show hours and minutes only.

Entries appear in recording order, newest first, even if the system clock changes. History includes app openings and exits, detected unrecorded exits, timer starts/extensions/stops, warnings and blocked actions, sleep/wake and user-session events, power connection changes, and duration/display/login setting changes. Routine countdown updates, battery polling, and cat animation frames are not logged. A crash can prevent the final event from being written; recovery describes missing information rather than guessing a cause or exact stop time.

Keep at most seven days and 4,000 entries, whichever limit removes an older entry first. Retention is checked when history is read or written and hourly while the app is running; expired entries are removed on the next launch after an extended absence. The log contains app-owned descriptions, without personal contact details, file paths, or device identifiers. Nothing is uploaded.

Logs and the separate last-session record are encrypted locally with AES-256-GCM authenticated encryption. The key is stored in macOS Keychain, never in source or beside the history. The older session record is migrated in place without a plaintext backup when its key is available. Corrupt-record copies are restricted to three for seven days; recent legacy copies are encrypted in place. The encrypted last-session status itself remains available for the main-screen notice beyond the log retention period.

An unavailable key or unverifiable history produces **“Logs unavailable”** rather than silently saving plaintext or replacing the key. Some events can be missing after a storage failure; resumed recording says so. Log encryption and disk access use a separate utility queue and do not hold up releasing keep-awake assertions. Keychain access adds no app entitlement, network service, analytics, or general access to other credentials. macOS may request approval if the app's signing identity changes.

## Power and timing

Battery monitoring responds to macOS power-source notifications and refreshes at launch, activation, and wake. A separate safety queue checks current charge every 10 seconds while a timer runs, with up to one second of scheduling tolerance. It checks independently of the interface and performs no periodic work while idle. Readings still depend on macOS reporting and scheduling; the cutoff is not an instantaneous or battery-drain guarantee.

Forecasts use only macOS's current internal-battery runtime estimate after at least 30 seconds of stable on-battery observations. Wake, connecting power, missing or invalid estimates, large estimate changes, and observation gaps over two minutes reset that settling period. Charge readings remain available immediately. Cat Run does not invent a runtime from the charge percentage or reuse an old runtime when the new one is missing.

The safety queue renews power assertions for at most 45 seconds at a time, bounded by the session deadline. It checks whether the interface has answered within 30 seconds and stops an unresponsive session when the guard next runs. If the guard itself stalls, macOS's assertion timeout limits the last issued keep-awake request. These are layered safeguards subject to operating-system behavior, not a promise to prevent every kind of battery drain or system failure.

Sleep notifications cancel the timer, with a wake fallback and a comparison of continuous time against awake time to detect a missed sleep notification. A deadline reached while awake is recorded as completion before evaluating a battery reading first observed afterward. Evidence of sleep takes priority over labeling a session complete. Once stopped, late callbacks cannot resume it or alter a newer session.

The countdown uses a continuous monotonic clock, with an operating-system timeout on its power assertions. The menu bar cat has [20 original activities](CAT-ACTIONS.md). A randomly chosen activity lasts about two seconds and starts every five seconds while active, without immediately repeating the previous choice. Low Power Mode reduces the animation to two frames per second. Reduce Motion, a sleeping display, or serious thermal pressure suppresses movement; the active pose remains distinct from idle. Swift and native macOS frameworks avoid a browser or an additional language runtime.

The cat's 340 raster frames are cached for reuse. Images combining the cat with its countdown use a separate cache limited to 19 entries, cleared when the activity or displayed minute changes.

Cat Run prevents **idle** sleep using macOS power assertions. It does not override choosing Sleep, closing a laptop's lid, a shutdown, or macOS safety decisions. It cannot guarantee that a background task continues through those events. Screen lock and display sleep are separate macOS behaviors; Cat Run does not bypass a locked session.

The minimum content size is 420×400 points; the title bar adds the height required by macOS. The initial window grows by up to 15% on larger logical displays. Resizing preserves the complete window's aspect ratio, including the title bar. Its maximum width and height are each 25% above that display's default size, or less if needed to fit the display's usable area. On an unusually small logical display that cannot contain the minimum, the usable minimum takes priority. Resizing does not change font sizes; only the Activity page has a scrollbar. Main controls, notices, and the Start/Stop button retain their assigned positions when the timer starts or stops.

The [product requirements](PRD.md) include the full interruption-scenario table and distinguish automated policy coverage from remaining hardware checks. [VALIDATION.md](VALIDATION.md) records checks actually performed.

## Build and test

Requires macOS 13 or later and a full Xcode installation with Swift 6 or later. There are no third-party packages. The default build uses `/Applications/Xcode.app`; use `DEVELOPER_DIR` to select a different full Xcode installation.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
bash scripts/build-app.sh
```

The script creates `build/Cat Run.app` for the current Mac's architecture. It signs that app locally with the App Sandbox entitlement and hardened runtime. Run the app bundle, rather than the loose Swift executable, when evaluating its permissions and login behavior.

Build caches stay in `.build`. The script disables SwiftPM's separate build-manifest sandbox to work in already restricted build environments; the resulting app's App Sandbox remains enabled. The package has no external dependencies or build plugins. Review source before building it.

The bundled app icon uses original peach outline artwork on a black background, generated by `scripts/generate-icon.swift`. To regenerate the included `Resources/CatRun.icns` after editing the artwork:

```sh
mkdir -p .build/module-cache
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift \
  -module-cache-path .build/module-cache scripts/generate-icon.swift .build/CatRun.iconset
iconutil --convert icns .build/CatRun.iconset --output Resources/CatRun.icns
```

Apple's icon converter may require execution outside a restricted build environment. Regular builds reuse the included generated icon.

Copy `Cat Run.app` into Applications before enabling start at login. An unchecked setting is normal when launch at login has never been enabled. macOS may require approval in System Settings → General → Login Items. Validate registration and a real logout/login from that stable location. Moving or replacing the app can affect login registration. Automated tests and an ordinary app relaunch do not prove a successful future login launch.

The build script replaces its prior generated app in `build`; it does not install the app, register it to start at login, modify macOS power settings, or accept the Xcode license.

## Local build and public release

The generated app is **ad-hoc signed**, not Developer ID signed or notarized. This is suitable for local testing but is not a ready-to-distribute public macOS binary. A public binary release needs a stable signing identity, Developer ID signing, Apple notarization, and verification on a clean Mac. An archive copied from another computer may be subject to Gatekeeper checks. Do not disable Gatekeeper to distribute or test a release.

Publish the source separately from build outputs. The source is MIT licensed. No GitHub repository is created by the build script.

Before publishing a binary, complete the manual checks in [SECURITY.md](SECURITY.md) alongside the automated tests. Battery readings, macOS sleep decisions, login-item approval, and display behavior require testing on real hardware.
