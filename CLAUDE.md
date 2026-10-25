# MacDash

SwiftUI cleanup app for macOS 13+. Xcode project `PureMac.xcodeproj` (scheme `PureMac`, internal
names still PureMac); `scripts/dev.sh build|run|test`. The project is not file-system synchronized:
new Swift files must be added to `project.pbxproj` (and kept in line with `project.yml`).

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
Avoid Protection, Processes' app list, the Assistant and the Wi‑Fi note in Settings: they read
the real Mac (permissions, running apps, usage stats, user name). Afterwards quit it,
`defaults delete com.macdash.app.showcase`, delete the temp home and `lsregister -u` the copy.
