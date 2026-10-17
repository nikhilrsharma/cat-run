# Cat Run product requirements

Version 0.2.1 · Updated October 16, 2026

Cat Run is a small native macOS utility for keeping a Mac awake for a chosen duration. It is created by Nikhil Sharma with assistance from OpenAI’s ChatGPT models, inspired by Caffeine by Dominic Rodemer, and published as open source under the MIT licence.

## Timer and completion

- Offer durations from 15 minutes to 6 hours in 15-minute increments. Use two-digit hour and minute values, omitting hours below one hour. Save the last three distinct successfully started durations for quick activation; show “No timers used yet.” when history is empty.
- Keep the Mac awake while a timer runs. Keeping the display awake is optional and can be changed only while inactive. Keep the Mac-awake checkbox checked and locked, with the hint “Keeps your Mac awake whenever you start a timer.”
- Show remaining time while active. Allow 15-minute extensions up to a total session duration of six hours. Keep Start and Stop in the same position and at the same size.
- On natural completion, show **“Timer finished at” followed by the finish date, time, and timezone** in the existing notice area. Use the Mac’s current regional date/time conventions and local timezone, including its applicable daylight-saving offset. Show hours and minutes without seconds.
- Capture the completion instant once. A delayed callback must use the timer’s deadline rather than the later time the window is opened or refreshed. Region or timezone changes may reformat that same instant. Wall-clock settings must not alter the countdown duration.
- Store only the most recent session outcome locally, including natural completion, and restore its notice after relaunch. A successfully started timer replaces that outcome. Failed activation displays the applicable failure without adding a recent duration. A failure after writing the new session marker may replace the saved outcome with that failed attempt.
- Manual stops, low-battery stops, unavailable readings, sleep, and failures retain their specific messages; they must not be presented as natural completion. Do not send session notifications.
- Closing the window leaves a timer running. Quitting, system sleep, user switching, and observed logout/shutdown end it. Relaunch inactive with saved duration, screen-awake preference, and recent durations; never restore an active timer.

## Interruption and outcome handling

- Write a session marker before acquiring sleep-prevention assertions. Persist the final reason and observed time after releasing them. A new process that finds an unfinished marker records an interruption with **unknown stop time**, never a successful completion inferred from elapsed time. Do not claim to distinguish an app crash from a forced quit or an abrupt system failure.
- Store a single bounded record with atomic writes in the app's local container. Reject malformed records, unexpected filesystem objects, and oversized input. Preserve a corrupt regular record separately and show that its prior status is unavailable. A failure to create the new session record prevents activation.
- Cancel on system sleep. Also reconcile an active timer on wake and compare continuous time with awake time to detect sleep when a notification is missed. Display sleep alone does not imply system sleep. Do not resume after waking, returning to the user session, or cancelling a logout/shutdown that has already stopped Cat Run.
- Keep stop processing serialized and tied to the current session identifier. An older callback must not stop, extend, resume, or overwrite a later session. Preserve the first recorded terminal outcome.
- Evaluate evidence of sleep before declaring completion. Without that evidence, a deadline already reached takes precedence over a low-battery reading first observed afterward. A low reading detected before the deadline stops the timer for low battery. Date/time text for safety stops is the observed stop time; it cannot establish the exact instant at which charge crossed a threshold.

## Battery protection and power use

- Refuse to start below 15% battery and stop an active timer below 15%, including while plugged in. Exactly 15% is allowed. If the Mac has a battery but its charge cannot be verified, block or stop the timer.
- Warn before starting or extending only when a usable forecast estimates ending charge below 15%. An unavailable runtime is unknown, not evidence of low charge: it must not trigger a warning, block activation with a valid charge reading, or fabricate an estimate. This corrects the earlier warning seen at 90% after unplugging.
- Use the current macOS internal-battery runtime only after at least 30 seconds of stable on-battery observations. Discard forecast confidence on wake, AC connection, missing/invalid charge or runtime, clock regression, a gap over 120 seconds, or a large runtime change. The stability check allows a change of up to five minutes or 25% of the previous runtime, whichever is larger, accounting for elapsed time. Return only the current estimate; retain no substitute for missing runtime. Actual percentage safety checks apply immediately throughout settling.
- While active, show a low projection in the existing notice area as it becomes available, including after unplugging. Do not open a new warning dialog mid-session. Keep actual-charge protection in force regardless of whether a forecast exists.
- Use macOS power-source notifications and refresh on app launch, activation, and wake. While active, an independent serial safety queue obtains current charge every 10 seconds, allowing up to one second of timer tolerance. It performs no battery polling while idle.
- Renew native sleep-prevention assertions with an operating-system timeout of at most 45 seconds, shortened to the remaining session time. Check a main-thread heartbeat with a 30-second timeout; when the interface stalls, the safety queue releases assertions and records the stop without waiting for it. If the safety queue stalls too, its last assertion retains its OS timeout. Do not silently reacquire an expired lease.
- Release assertions on completion, cancellation, safety stop, or quit. macOS may override them for explicit sleep, lid closure, shutdown, or system safety. OS scheduling and battery reports limit response timing; the guard cannot promise an exact battery floor or reliable execution during a kernel/system failure.

## Interface and menu bar

- Use a black background with peach `#FBC193` text and outlines. Keep text equally bright for enabled and disabled controls. Use Verdana for controls and a script wordmark, with the same sitting cat as the idle menu-bar icon.
- Align the wordmark, cat, and navigation button at the bottom. Center Settings and Back labels within their buttons. Use a rounded duration slider with a centered thumb, without a duplicate duration dropdown. Reserve enough clearance at both endpoints for the complete circular thumb, outline, and shadow in active and inactive states.
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
2. Refreshing, reopening the window, or relaunching does not change the stored completion instant. A late callback still reports the deadline when the session remained awake.
3. Timezone conversion handles date rollover and daylight-saving changes; regional formatting respects the local hour cycle.
4. A successful new timer replaces the old outcome. Failed starts and repeated idle updates do not fabricate a completion instant.
5. Manual and safety stops retain their existing messages, and extensions report the extended deadline.
6. The complete notice fits within the existing two-line area at the minimum and maximum window sizes, without overlap, smaller text, or scrolling.

## Scenario acceptance matrix

The following is the expected policy for the 22 reviewed scenarios. “Automated” identifies policy tests with controlled clocks, battery values, and power-service doubles; it does not mean the physical action was performed on a Mac. “Manual” identifies integration checks still needed unless explicitly recorded in [VALIDATION.md](VALIDATION.md).

| # | Scenario during an active timer | Expected result | Verification coverage and remaining checks |
|---|---|---|---|
| 1 | Close a laptop lid in ordinary use | If macOS sleeps, cancel; retain the sleep reason and remain inactive on wake. | Automated sleep-gap and journal tests; manual lid/wake check. |
| 2 | Close the lid with an external monitor | Continue if macOS stays awake in its supported closed-lid configuration; otherwise use the sleep-stop behavior. | Automated no-sleep/sleep clock paths; manual external-display setup. |
| 3 | Choose Sleep or use a sleep shortcut | Cancel for system sleep; optional display prevention does not override the request. | Automated sleep-stop policy; manual menu/shortcut and assertion check. |
| 4 | Wake after a sleep interruption | Stay inactive and show the stop reason; wake fallback handles a missed pre-sleep notification. | Automated missed-notification and recovery tests; manual wake notification delivery. |
| 5 | Lock the screen or start a screen saver | Continue if the user session remains active and the Mac stays awake; do not bypass authentication. | Manual lock/screen-saver integration check. |
| 6 | Only the display sleeps | Continue the timer; pause cat motion while the display sleeps. | Manual display-only sleep and animation check. |
| 7 | Close, minimize, or hide Cat Run's window | Continue the current timer in the menu bar. | Existing window behavior and lifecycle code; manual window/menu-bar check. |
| 8 | Quit normally | Release assertions and record a quit outcome; reopen inactive. | Automated stop/journal tests; manual normal quit and assertion removal. |
| 9 | Shutdown, restart, or an OS-update restart | Stop on the lifecycle notification or process termination; relaunch inactive. Abrupt termination without a final record becomes an interruption. | Automated known-stop/recovery tests; manual restart and real login launch. |
| 10 | Log out | End the timer and relaunch inactive. Use the observed lifecycle reason; an unrecorded termination has unknown stop time. | Automated persisted-stop/recovery tests; manual logout/login. |
| 11 | Switch users without logging out | Stop for user switch; returning does not resume the timer. | Generic stop/journal policy tests; manual fast-user-switch notification check. |
| 12 | Begin logout/shutdown, then cancel | Once Cat Run received the stop/termination event, stay inactive or closed. If cancellation preceded any event, an otherwise healthy timer may continue. | Stop/relaunch policy tests; manual cancellation ordering. |
| 13 | App crashes or is force-quit | macOS removes process-owned assertions. On relaunch, recover the unfinished marker as interrupted with unknown stop time. | Automated journal recovery and installed-app forced-termination/assertion cleanup; genuine crash testing remains separate. |
| 14 | Mac crashes, loses power, or is forcibly switched off | No execution guarantee during the failure. Relaunch inactive; recover interruption if the marker survived. Never invent an exact end time. | Automated incomplete-record recovery; genuine system failure not simulated by policy tests. |
| 15 | App freezes while its process remains alive | Independent charge checks continue. Missing UI heartbeat stops the session when detected; if the guard stalls too, its last OS lease is at most 45 seconds. | Automated guard tests and an isolated native blocked-main-thread/assertion check; whole-process suspension remains manual. |
| 16 | Unplug the charger | Continue with valid charge at or above 15%. Reset forecast settling; missing runtime produces no warning. Show a low projection inline if a usable one later arrives. | Automated AC-transition/90%-15-minute forecast regression; manual unplug and inline-notice check. |
| 17 | Battery falls below 15%, including on AC | Stop on detection and remain inactive after charging. Exactly 15% is allowed. | Automated cutoff/AC tests and native assertions with injected low charge; real battery reporting remains manual. |
| 18 | Current battery charge becomes unavailable | Stop on a battery-equipped Mac; no auto-resume when it returns. Missing runtime alone does not stop the timer. | Automated unavailable-charge/runtime and desktop tests; manual transient hardware reporting. |
| 19 | Change the clock or timezone | Keep the countdown duration; display saved outcomes in the current local timezone. A clock validity failure ends the session safely. | Automated monotonic-clock, timezone, daylight-saving, locale, and persisted-date tests. |
| 20 | Internet disconnects | Continue normally; the app uses no network service. | Source/entitlement review; optional manual offline check. |
| 21 | Open Cat Run again while already running | Open the existing instance; create no independent second timer. | Automated instance-selection tests; manual double-launch check. |
| 22 | Reach the natural deadline | Release assertions and retain “Timer finished at …” across relaunch. macOS then applies normal sleep policy. A later charge reading cannot rewrite completion as a battery stop. | Automated deadline ordering, late callback, persistence, and layout tests; manual timed expiry/assertion check. |

See [VALIDATION.md](VALIDATION.md) for the exact completed checks, release evidence, and remaining hardware validation. No automated matrix can establish that every macOS hardware or failure combination is bug-free.
