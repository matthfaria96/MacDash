# MacDash

SwiftUI cleanup app for macOS 13+. Xcode project `PureMac.xcodeproj` (scheme `PureMac`, internal
names still PureMac); `scripts/dev.sh build|run|test`. The project is not file-system synchronized:
new Swift files must be added to `project.pbxproj` (and kept in line with `project.yml`).

## Diagnosis (`PureMac/Services/Assistant`, `Views/Tools/Assistant*.swift`)

Shown as "Diagnosis" in a row of its own above Settings (`AppSection.assistant` internally); the
toolbar "Assistant" button is the separate quick panel and links to it. Its look is the aurora
palette (`SectionPalette.assistant`, `auroraColors`), the only section with two hues.

A diagnosis that runs on fixed rules, with no model and no network. It only works while an analysis
runs: no timer, no file watching, nothing at launch.
- `AssistantScanner` measures (one pass over the home folder), `AssistantRules` turns the numbers
  into findings and wording, `AssistantCatalog` is what it knows (editors, Claude, build folders).
- Without Full Disk Access the walk only opens folders listed as open (`guardedPaths`): an analysis
  must never make macOS show a permission prompt.
- Only the analysis made in this session can be acted on. Reports on disk
  (`~/Library/Application Support/MacDash/Assistant`) are records and never run anything.
- Full Disk Access is asked for in place (`AssistantAccessCard`), not with the sheet. AppKit refuses
  to quit while a sheet is open, which broke System Settings' "Quit & Reopen": `AppDelegate` handles
  the quit event itself (`PermissionCoordinator.quitClosingSheets`) and a reopen during a request
  comes back to the last section (`MacDash.lastSection`, `MacDash.resumeAfterAccess`).
- Before anything moves, `AssistantExecutor` checks every item again (same inode, still fits its
  rule via `AssistantCatalog.permits`, owner app closed) and then moves it to the Trash. Never add a
  delete-in-place or administrator fallback there.

## Demo mode (site screenshots)

`MACDASH_DEMO=1` (`PureMac/Core/DemoMode.swift`) is for the witchmymac.com screenshots. Every
number, file and app it shows is fictional; nothing is scanned, cleaned, removed, purged or
updated (those AppState actions return early), and there is no menu bar item, Sparkle, scheduler,
antivirus scheduler or Full Disk Access registration. A "scan" just shows the demo findings.
- `MACDASH_DEMO_RESULTS=smartCare|cleanup` opens that screen with its findings already in.
- `MACDASH_DEMO_REVIEW=<CleaningCategory raw value, e.g. "User Cache">` also opens its review.
- Debug builds also take `-DebugSection <section>` (and `-DebugTab`) to pick the sidebar section.
Run a renamed copy, never the installed app: copy the Debug app, set `CFBundleIdentifier` to
`com.macdash.app.showcase`, remove `NSServices` and `SUFeedURL`, `codesign --force --deep --sign -`,
`defaults write com.macdash.app.showcase MacTidy.OnboardingComplete -bool true` (and
`settings.general.menuBarMonitor -bool false`), then
`open -g -n --env CFFIXED_USER_HOME=<temp home> --env MACDASH_DEMO=1 <copy> --args -AppleLanguages "(en)" -DebugSection smartCare`.
Avoid Protection, Processes' app list, the Assistant toolbar panel and the Wi‑Fi note in Settings:
they read the real Mac (permissions, running apps, usage stats, user name). The Assistant screen
itself is safe: `-DebugSection assistant -DebugScan YES` shows a fictional analysis (`AssistantDemo`),
and `-DebugAssistant recommendations|review|history|report|details` opens that state of it.
`-DebugPermissionSheet YES` shows the Full Disk Access sheet. Afterwards quit it,
`defaults delete com.macdash.app.showcase`, delete the temp home and `lsregister -u` the copy.
