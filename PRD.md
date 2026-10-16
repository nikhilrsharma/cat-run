# Cat Run product requirements

Version 0.1.10 · Updated October 16, 2026

Cat Run is a small native macOS utility for keeping a Mac awake for a chosen duration. It is created by Nikhil Sharma with assistance from OpenAI’s ChatGPT models, inspired by Caffeine by Dominic Rodemer, and published as open source under the MIT licence.

## Timer and completion

- Offer durations from 15 minutes to 6 hours in 15-minute increments. Use two-digit hour and minute values, omitting hours below one hour. Save the last three distinct successfully started durations for quick activation; show “No timers used yet.” when history is empty.
- Keep the Mac awake while a timer runs. Keeping the display awake is optional and can be changed only while inactive. Keep the Mac-awake checkbox checked and locked, with the hint “Keeps your Mac awake whenever you start a timer.”
- Show remaining time while active. Allow 15-minute extensions up to a total session duration of six hours. Keep Start and Stop in the same position and at the same size.
- On natural completion, show **“Timer finished at” followed by the finish date, time, and timezone** in the existing notice area. Use the Mac’s current regional date/time conventions and local timezone, including its applicable daylight-saving offset. Show hours and minutes without seconds.
- Capture the completion instant once. A delayed callback must use the timer’s deadline rather than the later time the window is opened or refreshed. Region or timezone changes may reformat that same instant. Wall-clock settings must not alter the countdown duration.
- Keep the completion notice while the app remains open, including across window closure and reopening. A successfully started timer clears it. A failed start may display its failure message without overwriting the stored completion instant. Completion history does not persist across app relaunches.
- Manual stops, low-battery stops, unavailable readings, sleep, and failures retain their specific messages; they must not be presented as natural completion. Do not send session notifications.
- Closing the window leaves a timer running. Quitting or system sleep ends it. Relaunch inactive with saved duration, screen-awake preference, and recent durations.

## Battery protection and power use

- Refuse to start below 15% battery and stop an active timer below 15%, including while plugged in. Exactly 15% is allowed. If the Mac has a battery but its charge cannot be verified, block or stop the timer.
- Warn before starting or extending when the estimated ending battery is below 15% or an estimate cannot be obtained while on battery. Treat estimates as uncertain and enforce protection against actual readings.
- Use macOS power-source notifications and refresh on app launch, activation, and wake. While active, supplement these with a 60-second fallback that allows a five-second scheduling tolerance. Avoid idle polling.
- Use native sleep-prevention assertions with an operating-system timeout. Release the app’s assertions on completion, cancellation, safety stop, or quit. Do not override explicit system sleep, lid closure, shutdown, or other macOS safety decisions.

## Interface and menu bar

- Use a black background with peach `#FBC193` text and outlines. Keep text equally bright for enabled and disabled controls. Use Verdana for controls and a script wordmark, with the same sitting cat as the idle menu-bar icon.
- Align the wordmark, cat, and navigation button at the bottom. Center Settings and Back labels within their buttons. Use a rounded duration slider with a centered thumb, without a duplicate duration dropdown.
- Keep the interface free of scrollbars. The minimum content area is 420 × 400 points. Choose the default size for the display; preserve the complete window’s aspect ratio when resizing, up to 25% above its default width and height while fitting the usable display. Hide and disable the green zoom control.
- Show a static cat in the menu bar while inactive. While active, choose from [20 actions](CAT-ACTIONS.md) every five seconds without immediately repeating an action; show two-digit hours above minutes beside the cat. Left-click opens the app. Right-click offers only Open and Quit.
- Reduce animation work in Low Power Mode and suppress motion for Reduce Motion, sleeping displays, or serious thermal pressure. Cache artwork and bound the combined cat/countdown cache.

## Settings and distribution

- Allow launch at login to be changed only while inactive, using macOS’s login-item service. Report registration failures and approval requirements accurately.
- About must show the creator, OpenAI ChatGPT assistance, Caffeine attribution, version, update date, and MIT licence.
- Support macOS 13 or later using native Swift and macOS frameworks. Keep App Sandbox and hardened runtime enabled with no permissions beyond those needed. Do not add telemetry, network access, accounts, ads, notification permission, or a privileged helper.
- Keep personal contact details, preferences, caches, signing material, and generated binaries out of the public source repository. Publish source under MIT. Public binary distribution requires separate signing, notarization, and clean-machine validation.

## Completion timestamp acceptance criteria

1. A naturally completed timer displays its date, local time, and timezone immediately after “Timer finished at”.
2. Refreshing or reopening the window does not change the stored completion instant. A late callback still reports the deadline.
3. Timezone conversion handles date rollover and daylight-saving changes; regional formatting respects the local hour cycle.
4. A successful new timer clears the old completion time. Failed starts and repeated idle updates do not fabricate a new one.
5. Manual and safety stops retain their existing messages, and extensions report the extended deadline.
6. The complete notice fits within the existing two-line area at the minimum and maximum window sizes, without overlap, smaller text, or scrolling.

See [VALIDATION.md](VALIDATION.md) for completed checks and remaining hardware validation.
