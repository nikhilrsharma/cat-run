# Cat Run

A small native macOS menu bar utility that keeps a Mac awake for a chosen time. Created by Nikhil Sharma with assistance from OpenAI ChatGPT models. Last updated: October 12, 2026.

## Behavior

- Choose 15 minutes to 6 hours in 15-minute increments. Hours and minutes use two-digit values, such as `15m` and `01h 15m`; hours are omitted below one hour. The countdown uses the same notation, such as `03m` or `01h 03m`. The three most recently started, distinct durations are saved for quick reuse.
- Keep Mac awake is required during a timer. Keeping the display awake is optional. That choice and start at login can be changed only while the timer is inactive.
- A static menu bar cat becomes periodically animated during a timer. A small two-line countdown shows two-digit hours above minutes beside the cat, for example `01` above `03`. Click to open the window; right-click for Open and Quit.
- Below 15% battery, a timer cannot start and an active timer stops, including while connected to power. Exactly 15% is allowed. A forecast below 15% warns before activation; the forecast is an estimate, not a guarantee.
- Stopping releases Cat Run's sleep prevention. macOS and other apps decide when the computer actually sleeps. The app does not force an immediate sleep.
- Closing the window leaves an active timer running. Quitting ends it. Saved preferences and recent durations survive relaunch; a timer does not resume automatically.
- The window uses a fixed black background with peach (`#FBC193`) text and outlines, and no scrolling. Text keeps the same color and brightness when controls are disabled. Verdana is used for controls; the Cat Run wordmark uses a script face. The header uses the same sitting cat artwork as the idle menu-bar icon. Settings and Back lettering is centered inside its button. The duration slider has a rounded track and thumb centered between its minus and plus buttons. Hovering over the lock beside Keep Mac awake shows “Keeps your Mac awake whenever you start a timer.” above the icon. The duration value uses the same 15pt Verdana text size as its label. Start and Stop occupy exactly the same space in every timer state.
- No session notifications, telemetry, accounts, ads, or cloud service.

Battery monitoring responds to macOS power-source notifications, refreshes at launch, activation, and wake, and uses a 60-second fallback check only during an active timer. The fallback has a five-second scheduling tolerance so macOS can combine wakeups. There is no idle polling. Readings are limited by when macOS reports a change; this is not a real-time guarantee.

The countdown uses a continuous monotonic clock, with an operating-system timeout on its power assertions. The menu bar cat has [20 original activities](CAT-ACTIONS.md). A randomly chosen activity lasts about two seconds and starts every five seconds while active, without immediately repeating the previous choice. Low Power Mode reduces the animation to two frames per second. Reduce Motion, a sleeping display, or serious thermal pressure suppresses movement; the active pose remains distinct from idle. Swift and native macOS frameworks avoid a browser or an additional language runtime.

The cat's 340 raster frames are cached for reuse. Images combining the cat with its countdown use a separate cache limited to 19 entries, cleared when the activity or displayed minute changes.

Cat Run prevents **idle** sleep using macOS power assertions. It does not override choosing Sleep, closing a laptop's lid, a shutdown, or macOS safety decisions. It cannot guarantee that a background task continues through those events. Screen lock and display sleep are separate macOS behaviors; Cat Run does not bypass a locked session.

The minimum content size is 420×400 points; the title bar adds the height required by macOS. The initial window grows by up to 15% on larger logical displays. Resizing preserves the complete window's aspect ratio, including the title bar. Its maximum width and height are each 25% above that display's default size, or less if needed to fit the display's usable area. On an unusually small logical display that cannot contain the minimum, the usable minimum takes priority. Resizing does not change font sizes or add scrolling. Main controls, notices, and the Start/Stop button retain their assigned positions when the timer starts or stops.

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
