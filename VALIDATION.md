# Cat Run 0.2.1 validation

Checked October 16, 2026 on an Apple Silicon Mac running macOS 27.0.1. The build targets macOS 13 or later; older supported versions and Intel hardware have not been exercised here.

## Current revision

- Corrected slider endpoint clipping by calculating the track and circular thumb from the control's bounds with three points of outer clearance. The drawing path uses that same thumb rectangle rather than the inherited cached rectangle. Native keyboard/accessibility and 24 duration tick values remain in place.
- All 18 focused native tests passed: the 17 existing window/layout tests plus a rendered-slider regression. The new test captures the actual slider view at minimum, middle, and maximum durations, enabled and disabled, at minimum/maximum window sizes and 1×/2× rendering (24 bitmap cases). It checks complete thumb dimensions/area and outer-edge clearance. The prior implementation failed the endpoint-clearance checks; the corrected implementation passed. The unrelated session/core suite was not rerun for this drawing-only patch.
- An isolated native preview using the production window and slider confirmed complete circular thumbs at both ends in active and inactive appearances. Pointer drags from 15 minutes to six hours and back reached the correct values. The preview did not hold power assertions or modify the running app's timer, history, or preferences.

- Version 0.2.1/build 13 was packaged with the same App Sandbox-only entitlement and hardened runtime. The extracted app archive passed strict signature verification and matched the build byte for byte. All 49 publication files passed the privacy scan; the stripped executable contained no personal home path.

- Installed 0.2.1 only after the existing 15-minute session finished naturally. The prior app was backed up; the installed bundle passed strict signature verification and matched the build byte for byte. Native inspection confirmed the complete left-end thumb, unchanged 15-minute selection and 15/165/90-minute history, screen-awake preference, inactive state, and the same completed-session timestamp after reopening.

## Checks retained from 0.2.0

- Fixed the reported 90%-charge/15-minute warning: an unavailable runtime estimate is no longer classified as a low-battery forecast. Regression tests cover wake/unplug settling, AC transitions, missing and unstable runtime, charge validity, and the exact 15% boundary.
- All 189 tests passed: 107 native and 82 core tests. The native suite includes 37 safety-guard tests; the core suite includes 15 forecast and 19 journal tests. New message/layout coverage exercises 66 persisted or failure notices across five locale/timezone combinations and three simulated display sizes at their minimum and maximum window sizes (396 layout cases), in addition to the retained layout checks.
- Safety tests cover fresh charge on AC and battery, a blocked interface, missed sleep notifications, invalid or delayed clocks/reads, failed and expired assertion leases, exact extensions, slow initial assertion acquisition, generation isolation, and terminal-event ordering. Journal tests cover restart recovery, first-stop-wins behavior, malformed and oversized data, missing end times, permissions, and unexpected filesystem objects.
- An isolated native harness used the production safety guard and power-assertion manager with real macOS assertions. With only its own main thread blocked, it stopped for unresponsiveness after 33.020 seconds, saved the outcome on the background queue, and verified that neither its system nor display assertion remained. A second case injected 14% while on AC without changing the physical battery; it stopped after 11.009 seconds from session start (about nine seconds after injection), persisted the outcome, and verified no remaining assertion. This confirms native integration with controlled input, not a real battery-drain experiment.
- The 22-scenario acceptance table in PRD.md identifies implemented behavior, automated coverage, and remaining hardware checks. Sleep, logout, shutdown, OS crashes, and real battery depletion were not forced on the user's Mac during this revision.

- Version 0.2.0/build 12 was installed after preserving 0.1.10. Strict signature verification passed; App Sandbox is still the only entitlement and hardened runtime remains enabled. Installed About shows the new version/date and retained Caffeine attribution. Native checks confirmed a 15-minute selection, recent values of 15, 165, and 90 minutes, screen awake on, launch at login off, and an inactive final state.
- Clicking the saved 15-minute duration in the installed app started immediately at 84% with no warning sheet. A normal stop showed its local timestamp and retained that same outcome after quitting and reopening. A fresh main-screen capture confirmed the complete header, controls, and two-line stop notice fit without scrolling or overlap.
- A test session created for this revision was forcibly terminated in the installed sandboxed app. The process's two real power assertions were present before termination and absent afterward. Relaunch remained inactive and displayed “Previous timer interrupted. Stop time unknown.” Settings/history were unchanged. A subsequent normal test stop replaced the test interruption notice, and the app was left inactive.
- The packaged app archive passed strict signature verification and all four bundle files matched both the build and installed app byte for byte. The source privacy scan covered 48 publication files and found no personal paths, email addresses, or credentials; generated `@2x.png` asset names were excluded as false email matches. The stripped executable contained no personal home-directory path. Local evidence, preferences, caches, and backups are excluded from source publication.

- Short performance samples of the installed release measured 0.47 CPU-seconds across 30.008 active seconds (about 1.57% of one core, window open) and 0.01 CPU-seconds across 30.016 idle seconds (about 0.03% of one core). Active resident memory moved from about 86 to 83 MiB; idle memory was about 89 MiB. The final inactive process held no power assertions. These are brief observations on this Mac, not a battery-life benchmark or a guarantee across hardware.

## Checks retained from 0.1.10

- Natural completion now records the timer deadline once and displays its date, time, and timezone using the Mac’s current regional settings. Locale and timezone notifications refresh its presentation without changing the stored instant. The countdown still uses the monotonic clock.
- All 110 tests passed: 69 native and 41 core tests. Nine new tests cover exact and delayed expiry, stable completion timestamps, failed and successful starts, extensions, non-expiry stops, timezone date rollover, the repeated daylight-saving hour, and 12/24-hour formatting. The existing layout matrix now includes completed notices for five locale/timezone combinations at all tested window sizes.
- An isolated native rendering harness used the production model, formatter, and window to simulate expiry and render the minimum 420×400-point content area. Visual inspection confirmed that the complete local date/time notice fits without overlap or scrolling. This is simulated expiry; a live 15-minute session was not run for this revision.
- Version 0.1.10/build 11 was installed and passed strict signature verification with only the App Sandbox entitlement. Native checks confirmed the version and preserved the 165-minute selection, recent values of 165, 90, and 60 minutes, screen awake on, launch at login off, and inactive timer.
- The extracted app archive passed strict signature verification and matched the built and installed app files byte for byte. All 42 publication files passed the source privacy scan.
- Added PRD.md beside the source and updated the README with the completion-time requirements. The earlier installed app was archived before replacement.

## Checks retained from 0.1.9

- Added the Caffeine attribution to About and the README. All 16 existing layout tests passed; the full behavior suite was not rerun for this text/layout change.
- Version 0.1.9/build 10 was built, installed, and passed strict signature verification. A native Settings screenshot confirmed the attribution fits with the creator, version, and licence text.
- Relaunch preserved the 90-minute selection, recent values of 90, 165, and 60 minutes, and enabled screen-awake setting. Launch at login remained off, and the timer remained inactive.

## Checks retained from 0.1.8

- Before initial GitHub publication, the complete 0.1.8 suite passed all 101 tests: 69 native and 32 core tests. The 38 publication files were checked for personal paths, email addresses, private keys, and common credential patterns; none were detected. This is a local check, not a GitHub Actions run.
- Disabled button and checkbox labels now retain the full peach text color and brightness. Control behavior is unchanged. A source audit confirmed the app window's text uses the full foreground color; only the two custom disabled-title color attributes needed correction.
- All 16 existing layout tests passed, including a final rerun after adding layer backing and limiting background painting to the dirty region. The full suite was not rerun for this cosmetic change.
- The final 0.1.8/build 9 release passed strict signature verification. Native idle and active checks confirmed equal text brightness, including disabled recent-duration buttons and the launch-at-login label. The app was left inactive with 195 minutes selected, recent values of 195, 240, and 60 minutes, screen awake enabled, and launch at login off.
- A complete Settings capture was obtained, but some later UI-automation captures omitted unchanged labels while their accessibility nodes and app behavior remained present. The cause is unconfirmed; the rendering adjustment is not claimed to have resolved that capture limitation.
- Reopening the final installed release produced a complete inactive screenshot with equal text brightness. The extracted app archive passed strict signature verification and matched the built and installed files byte for byte. Version 0.1.8/build 9, the 0.1.7 backup, and one running Applications copy were verified. The 38 source files passed the privacy audit; the stripped binary contained no private paths.

## Checks retained from 0.1.7

These results describe 0.1.7 and retained behavior; they are not claims that all hardware checks were repeated for 0.1.8.

- The lock hint and Mac-awake checkbox help now read “Keeps your Mac awake whenever you start a timer.” The stop-to-change reminder was removed from the screen/login checkbox tooltips and the main/Settings inline text. Controls remain disabled while a timer runs.
- All 21 existing focused tests passed: 16 layout and five hint tests. Native checks confirmed that the new hint fits above the lock and the removed reminders are absent from the main and Settings screens during a timer. The full suite was not rerun for this copy change.
- Version 0.1.7/build 8 was installed and passed strict signature verification with only the App Sandbox entitlement. A timer set to 195 minutes was started and then stopped; the app was left inactive. Recent values of 195, 240, and 60 minutes, screen awake enabled, and launch at login off were preserved.
- The extracted app archive passed strict signature verification, and every file matched the built and installed apps. Version 0.1.7/build 8, the 0.1.6 backup, and a single running Applications copy were verified. The 38 source files passed the privacy audit; the stripped binary contained no private paths.

## Checks retained from 0.1.6

These results describe 0.1.6 and retained behavior; they are not claims that all hardware checks were repeated for 0.1.8.

- The final 0.1.6/build 7 app was installed in Applications and passed strict signature verification. Hardened runtime and App Sandbox remain enabled, with only the `com.apple.security.app-sandbox` entitlement. Exactly one process was running, from the installed app. The 195-minute selection, recent values of 195, 240, and 60 minutes, and enabled screen-awake preference were preserved.
- Native checks on the final installed app confirmed that launch at login was initially unchecked with no warning, enabling checked it without an error, and disabling unchecked it without an error. It was left off with Settings open. The final Settings screenshot also confirmed the clean header, centered Back text, and black/peach theme. An actual macOS logout/login was not performed.
- All 31 focused tests passed: 16 layout, four login-status mapping, and 11 login-service tests. The full suite was not rerun for this patch. Service tests use a fake backend and cover fresh status reads, quiet never-registered states, confirmed enable/disable results, required approval, and operation failures without fabricating a successful state.
- Investigation of the installed 0.1.5 app reproduced a false warning while launch at login was off and macOS reported `.notFound`. Apple's Developer Technical Support explains that this status can occur before the service has ever been registered. [Apple DTS explanation](https://developer.apple.com/forums/thread/719862).
- Real enable/disable checks on that installed app succeeded: enabling checked the setting and removed the message; quitting and reopening the app kept the setting checked; disabling unchecked it with no message. The original off state was restored. This tested registration changes and app relaunch, not an actual macOS logout/login.
- The final app archive was extracted, confirmed as version 0.1.6/build 7, and passed strict signature verification. Every file matched the built and installed apps byte for byte. The preceding backup archive was confirmed as version 0.1.5. The 38 intended source files passed the privacy audit for personal paths and email addresses; fictitious example paths in historical documentation were treated as examples rather than personal data. The stripped release binary contained no personal home-directory paths.

## Checks retained from 0.1.5

These results describe 0.1.5 and retained behavior; they are not claims that all hardware checks were repeated for 0.1.8.

- The final 0.1.5/build 6 app was installed in Applications and passed strict signature verification. Hardened runtime and App Sandbox remain enabled, with only the `com.apple.security.app-sandbox` entitlement. Exactly one process was running, from the installed app. It opened inactive with a 195-minute selection, recent values of 195, 240, and 60 minutes, and the screen-awake preference enabled.
- Installed Settings showed a two-line missing-login-item explanation with launch at login unchecked. The later 0.1.6 investigation identified that explanation as incorrect for the normal never-registered state. Login registration and actual macOS logout/login had not been tested at this point.
- The initial complete automated suite passed 85 tests: 29 session/core, three duration-format, 16 layout, 11 artwork, four lock-hover, five single-instance election, nine stacked-status, and eight window-sizing policy tests. After the pointer-event refinement, all 21 focused tests passed again: 16 layout and five lock-hover tests, including one new hover case. Four additional login-status wording tests then passed. This provides passing results for 90 distinct tests across those runs; the complete 90-test suite was not rerun.
- The header now uses the idle menu-bar cat artwork, tightly cropped and tinted `#FBC193`. Isolated image checks confirmed exact alpha-byte identity with the cropped idle image and the expected premultiplied tint at 24×20, 44×32, and 52×32-point source sizes. An offscreen rendering was visually inspected. The 20 menu-bar animations are unchanged.
- Current layout checks cover centered visible button lettering, including Settings and Back, the black/peach palette, and the lock's custom hint above its hover area. The hint reads “Required while the timer runs.” These automated checks do not by themselves verify native pointer behavior or every display configuration.
- Native main and Settings screens were visually checked for the black background, peach text and outlines, shared idle-cat artwork, and centered Settings/Back lettering. The hover refinement observes pointer events only inside Cat Run's own window; it adds no global input monitoring, polling, or permission requirement.
- In a 0.1.5 release build, clicking the lock displayed the exact hint above it, and clicking blank space dismissed it. Dragging the pointer from blank space onto the lock also showed the hint; dragging away dismissed it. Main and Settings colors and centered navigation lettering were visually checked again in that release.
- Native Start and Stop were checked in the installed app before the final login-status wording correction. The selected duration was 195 minutes and recent values were 195, 240, and 60 minutes. The wording correction distinguishes an app outside Applications from an unavailable login component when the app is already installed there; four focused tests cover those messages.
- The final app archive was extracted, confirmed as version 0.1.5/build 6, and passed strict signature verification. Every file matched the built and installed apps byte for byte. The preceding backup archive was confirmed as version 0.1.4. All 37 intended source files passed the privacy audit for personal paths and email addresses; fictitious home-directory paths in test fixtures were excluded from the personal-path scan. The stripped release binary contained no personal home-directory paths.

## Checks retained from 0.1.4

These results describe 0.1.4 and retained behavior; they are not claims that all hardware checks were repeated for 0.1.8.

- Version 0.1.4/build 5 was installed in Applications after backing up 0.1.3. Strict signature verification passed; hardened runtime and App Sandbox remain enabled, with only the `com.apple.security.app-sandbox` entitlement. The installed app relaunched inactive with the selected 195-minute duration, recent durations of 240, 60, and 45 minutes, and enabled screen-awake preference preserved. The green zoom button remained absent from its accessibility tree. Quitting was verified to leave no Cat Run process.
- The complete automated suite passed 79 tests: 29 session/core, three duration-format, 14 layout, eight artwork/animation-timing, five single-instance election, nine stacked-status, three walking-header artwork, and eight window-sizing policy tests.
- After the final navigation-button drawing adjustment, all 14 layout tests passed again. They cover the visible Settings/Back lettering alignment, unchanged button frame, absence of the green zoom button, and aspect-ratio constraints in addition to the retained layout checks.
- The release build passed signature verification with ad-hoc signing, hardened runtime, and App Sandbox. The 33 intended source files passed checks for personal paths and email addresses; the stripped binary contained no personal filesystem paths.
- The workspace 0.1.4 app was visually checked on the main and Settings screens: the `#FBC193` palette, fluffy walking header cat, and shared bottom alignment of the wordmark, cat's feet, and navigation lettering were confirmed. Settings and Back retained the same outer button frame. The green zoom button was absent in both the accessibility tree and screenshot. An active four-hour session showed the correct time format and locked controls.
- The complete 20-activity contact sheet and the fluffy header cat were rendered and visually inspected at small and enlarged sizes, with no clipping found. This verifies the artwork offscreen; it is not a live menu-bar animation check.
- Animation checks cover all 340 cached frames, distinct activity artwork, return to rest, no immediately repeated random choice, the five-second cadence, and reduced frame rate in Low Power Mode. Countdown checks also cover the 19-entry composed-image cache limit.
- One 65-second observation with a timer active and the window open consumed 1.15 seconds of CPU, about 1.8% of one core. Resident memory moved from 92,288 KiB to 82,432 KiB, approximately 90 MiB to 80.5 MiB. This is a limited observation on this Mac, not a battery-life benchmark or a claim of unchanged energy use.
- The sizing policy preserves the whole window's aspect ratio, including the actual macOS title bar, with a 420×400-point minimum content area. Automated checks cover defaults that grow by at most 15% on larger logical displays, maximum dimensions 25% above the default capped by available display space, width/height/corner resizing, screen changes, malformed inputs, and the too-small-display fallback. These are simulated geometry inputs, not measurements on multiple physical monitors.
- An attempted native edge drag through UI automation left the pointer at the window's edge without resizing it. The cause was not established. Live edge-drag behavior therefore remains unverified; the sizing-policy and native geometry tests are the available evidence.
- After installation, exactly one Cat Run process remained, from Applications. The app archive was extracted and its 0.1.4 version and strict signature verified. The source archive contains the 33 intended project files, including the activity catalog, and excludes preferences, caches, logs, and test artifacts.

## Checks retained from 0.1.3

These results describe 0.1.3 and retained behavior; they are not claims that all hardware checks were repeated for 0.1.8.

- Final release installed in Applications as version 0.1.3/build 4, with 0.1.2 backed up. The installed copy relaunched inactive with its selected 60-minute duration, recent durations of 60, 45, and 30 minutes, and enabled screen-awake preference preserved. Signature verification passed; App Sandbox and hardened runtime remain enabled, with only the `com.apple.security.app-sandbox` entitlement.
- All 66 automated tests passed: 29 session/core, three duration-format, 12 layout, six artwork/animation-timing, five single-instance election, eight stacked-status, and three walking-header artwork tests.
- The workspace 0.1.3 app was launched and visually checked. The soft round slider thumb and track shared the center line of the minus and plus buttons. A native pointer drag changed the duration from `03h 00m` to `05h 15m`. The app was returned to an inactive 60-minute selection; its three recent durations remained 60, 45, and 30 minutes. The walking header cat's feet aligned with the visible wordmark bottom.
- Native active and stopped states were also visually checked. The header alignment remained correct, controls were locked during the timer, and `Remaining 01h 00m` and `+15m` were displayed correctly.
- Layout checks cover 45 main-page and 24 Settings combinations across simulated usable display areas of 1440×875, 1024×700, and 800×600 points. Slider geometry was checked at all 24 durations, at minimum, intermediate, and maximum window sizes on each of those simulated displays: 216 combinations. Its 4-point track and 18-point thumb stayed inside the control and centered on both buttons, including both endpoints.
- Other layout checks verify the required lock and fixed checkbox state, visible header-ink alignment, padded duration and history labels such as `15m` and `01h 15m`, countdowns such as `03m` and `01h 03m`, identical Start/Stop frames, and both actual warning messages. The two-digit 14% forecast exercises the longest valid below-threshold estimate. The separate 480×400-point case verifies the documented minimum-size fallback.
- The menu bar uses one 40×20-point template image containing the cat and a smaller two-row numeric countdown, with two-digit hours above minutes and no unit suffixes. Pixel, layout, formatting, cache, and five-second action-cadence tests passed. These automated checks do not constitute visual verification of the live menu bar.
- The production menu image was rendered and visually inspected at 22- and 24-point menu-bar heights in light and dark samples. Both numeric rows fitted beside the cat. This is offscreen image verification, not live menu-bar observation.
- Exactly one Cat Run process remained, running the installed app. Source checks found no personal paths or email addresses, and the stripped release binary contained no personal filesystem paths. The app archive was extracted and its 0.1.3 version and strict signature verified. The source archive contains only the 30 intended project files; preferences, caches, logs, and test artifacts are excluded.

## Checks retained from 0.1.2

These results describe 0.1.2 and retained behavior; they are not claims that all hardware checks were repeated for 0.1.8.

- Final release installed in Applications as version 0.1.2/build 3, with the preceding app backed up. It relaunched inactive with the selected duration, three recent values, and screen preference preserved. Signature verification passed; the app retains App Sandbox and hardened runtime with no added entitlements.
- The exact production status image was rendered and visually inspected at 22- and 24-point menu-bar heights, in light and dark samples. Both time rows were complete and separate from the cat. This is offscreen image verification, not live menu-bar observation.
- Source and stripped release binary passed checks for personal paths and email addresses. Release archives contain no local preferences, caches, or logs.

- The workspace 0.1.2 app was launched and visually checked in inactive and active states. The peach/black palette, visible lock, complete checkboxes, and aligned bottoms of the black wordmark and header cat were confirmed. Three history buttons containing `1hh 00mm`, `45mm`, and `30mm` fitted their row.
- Settings was visually checked with black text, a working Back button, and launch at login locked during a timer. The generated peach-and-black app icon was also checked.
- All 62 automated tests passed: 29 session/core, three duration-format, 11 layout, six artwork/animation-timing, five single-instance election, and eight stacked-status tests.
- Current layout checks cover 45 main-page and 24 Settings combinations across simulated usable display areas of 1440×875, 1024×700, and 800×600 points. They also verify the required lock, fixed checkbox state, visible header-ink alignment, longer `hh`/`mm` history-button labels with text padding, identical Start/Stop frames, and both actual warning messages. The two-digit 14% forecast exercises the longest valid below-threshold estimate. The separate 480×400-point case verifies the documented minimum-size fallback.
- The menu bar uses one 57×20-point template image containing the cat and the smaller two-row countdown. Pixel, layout, formatting, and cache tests passed, avoiding native button-title clipping. These automated checks do not constitute visual verification of the live menu bar.

## Checks retained from 0.1.1

These results describe 0.1.1 and retained behavior; they are not claims that all hardware checks were repeated for 0.1.8.

- All 48 automated tests passed: 29 core, eight layout, six artwork/animation-timing, and five single-instance election tests.
- Release app compiled, replaced the prior installed copy in Applications, and launched inactive with saved settings/history retained. Signature verification passed; App Sandbox and hardened runtime remain enabled, with only the `com.apple.security.app-sandbox` entitlement. A subsequent launch from the build folder left exactly one running process, from Applications.
- 29 core tests passed, including 2,000 deterministic mixed-event steps. These cover all 24 durations, actual battery below/exactly 15% on and off AC, unknown readings, warnings and fresh confirmation, stale plans, failed-start history, locked preferences, deadlines, extensions, sleep, invalid clocks, and inactive relaunch.
- Eight native layout tests passed. The main-page matrix covers 45 combinations and Settings covers 24, using minimum, intermediate, and maximum sizes as applicable. Simulated usable display areas were 1440×875, 1024×700, and 800×600 points; these are geometry inputs, not three physical monitors. Checks cover clipping, overlapping controls, no scroll views, stable Start/Stop frames, matching 15pt duration text, checkbox drawing space and accessibility role, locked settings, and state-independent size limits. Both actual battery-warning messages also fit their 260-point panels, with no overlap and 40-point buttons; that test constructs panels without presenting them.
- A separate 480×400-point display test checks the documented extreme-size fallback: the fixed 420×400-point content minimum takes precedence when a 75% cap is too small. Window chrome is added using macOS's actual frame calculation, not an assumed title-bar height.
- Native visual inspection confirmed the updated header and cat, complete checkbox margins, no scrollbar, 15pt remaining time, identical Start/Stop frames, and the Settings Back button with launch at login locked during a timer.
- Six artwork and animation-timing tests checked all 85 cached action frames, transparent edges and interiors, changing poses, return to idle, Low Power Mode subsampling, the white header image, and bounded two-second animation behavior after delayed callbacks. A rendered contact sheet was visually inspected. This checks image content and scheduling calculations, not the live menu bar.
- Five pure instance-election tests passed. Separate runtime integration checks also confirmed that sequential and simultaneous launches of two copies leave one running instance. Quitting was verified to leave no Cat Run process.

- The 0.1.1 source and stripped release binary were scanned for personal paths and email addresses. Only standard `@2x.png` asset names matched the broad email pattern. Release archives excluded preferences, logs, caches, and test artifacts.

## Earlier checks retained for unchanged behavior

The following checks were performed on 0.1.0. They describe evidence for the retained power/session implementation; they are not claims that every hardware scenario was repeated for 0.1.8.

- Real IOKit tests confirmed system-only and system-plus-display assertions, explicit release, transactional extension, OS-enforced timeout, and no leftover requests. The timeout test allowed the main thread to stop processing; macOS still released the assertion.
- The packaged sandboxed app read live battery changes, started both timer modes, extended a timer, locked settings while active, stopped, and quit without leaving its power requests behind.
- Relaunch restored the duration, history, and screen preference while remaining inactive. The six-hour forecast warning appeared and Escape canceled it without starting. Clean first launch displayed its history explanation.
- The earlier warning sheet was visually checked. Its retained layout should also be inspected in the current build.
- A short active-session observation of 0.1.0, including some UI interaction, consumed 0.40 seconds of CPU across approximately 61 seconds (about 0.66% of one core). Resident memory was approximately 82 MiB. Animation and its cadence changed in later versions, so those measurements are not a benchmark of the current animation. They are limited observations, not a battery-life benchmark or a guarantee across Macs.
- Source and the stripped binary were checked for personal paths and email addresses. Source archives exclude preferences, logs, caches, and signing material. Only the author's permitted name is included.

## Still requires manual hardware testing

- A real battery crossing below 15%, including while connected to power. Core policy is tested; hardware was not deliberately drained to reproduce this.
- Perform an actual macOS logout/login with launch at login enabled, and test any macOS approval-required state. Enable/disable and ordinary app relaunch have been checked; the original off setting was restored afterward.
- Closed-lid/manual-sleep behavior, multiple displays, monitor changes, unusual display scaling, and every window-resize path.
- Visually inspect the menu-bar cat's randomly selected actions, five-second cadence, stacked countdown, and left-click/right-click interactions. The available UI inspection could not show the macOS menu bar, so its revised live rendering has not been visually verified. Also check its two-frame-per-second Low Power Mode behavior and motion suppression under Reduce Motion, sleeping displays, and thermal pressure. These conditions were not all reproduced interactively.
- Longer idle/active energy profiling and a clean-machine public-release test.

Quit other keep-awake utilities when checking sleep behavior. Cat Run releases only its own assertions; it cannot make another app release its requests. The locally signed app is for testing and has not been Developer ID signed or notarized. The source is published on GitHub; no signed or notarized binary release is provided.
