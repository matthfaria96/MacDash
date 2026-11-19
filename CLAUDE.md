# MacDash

SwiftUI cleanup app for macOS 13+. Xcode project `MacDash.xcodeproj` (scheme and module `MacDash`);
`scripts/dev.sh build|run|test`. `project.yml` is the source: after adding, moving or renaming files or
targets, run `xcodegen generate` (it rewrites the project; don't edit that by hand).

Code is grouped by feature: `MacDash/App` (entry, `AppState`, window), `MacDash/Features/<Screen>`
(logic and views together), `MacDash/Shared` (permissions, system readers, design), `MacDash/Resources`.
Where everything lives and the naming rules: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md); keep it
current when adding or moving files.

MacDash is its own product: don't add references to other apps or projects in code, comments or UI.
The former names (MacFresh, Mac Tidy) live only in `App/LegacyMigration.swift`; a published
preference key is never renamed without an entry in `LegacyMigration.renamedKeys`. License headers
on adapted files, `THIRD_PARTY_NOTICES.md` and Settings › About › Open-source licenses stay: the
licenses require them.

## Assistant (`MacDash/Features/Assistant`)

Opened by the toolbar "Assistant" button (`AppSection.assistant`, no sidebar row); its look is the
neutral palette (`SectionPalette.assistant`: near-black, blue-gray light, ice accent, `assistantGlow`
edges). Past analyses and MacDash's usage numbers live in the
History section (`HistoryView`, above Settings). One folder can be analyzed on its own: from the
screen, by dropping it there, or from Finder's right-click "Analyze with MacDash" (the
`MacDashFinder` Finder Sync extension, which only builds the menu and opens `macdash://analyze?path=`).
The diagnosis runs on fixed rules, with no model and no network. It only works while an analysis
runs: no timer, no file watching, nothing at launch. It is the doctor of the whole Mac: a whole-Mac
analysis also reads disk health and the backup (`DeviceHealthReader`, judged by `DeviceHealthRules`
like Processes' Health card) and hands those findings to Processes (`AssistantTool.processes`).
- "Ask the Assistant" (`AssistantChat`; a card, `AssistantChatLauncher`, opens `AssistantChatSheet`) is a conversation through Apple's
  on-device model (`FoundationModels`, macOS 26+ with Apple Intelligence; weak-linked so macOS 13-15
  still launch). MacDash gathers the facts itself (`AssistantChatFacts` from the analysis, plus a
  fresh `MacActivitySnapshot` sent with each question) and the model only words them. It has no
  tools: tested on 2026-11-19, the small model didn't call tools reliably. It never acts; answers
  point to the Review button or another screen. Nothing loads until the window opens, and closing it
  forgets the conversation (`AssistantChat.end`): no message is ever saved.
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

`MACDASH_DEMO=1` (`MacDash/App/DemoMode.swift`) is for the witchmymac.com screenshots. Every
number, file and app it shows is fictional; nothing is scanned, cleaned, removed, purged or
updated (those AppState actions return early), and there is no menu bar item, Sparkle, scheduler,
antivirus scheduler or Full Disk Access registration. A "scan" just shows the demo findings.
- `MACDASH_DEMO_RESULTS=smartCare|cleanup` opens Smart Care with Essential or Complete findings already in.
- `MACDASH_DEMO_REVIEW=<CleaningCategory raw value, e.g. "User Cache">` also opens its review.
- `MACDASH_DEMO_WINDOW=1080x780` sizes the main window (the site's shots are 1080×780). History
  shows fictional usage numbers in demo mode.
- Debug builds also take `-DebugSection <section>` (and `-DebugTab`) to pick the sidebar section;
  `-DebugScanAreas YES` opens Smart Care's "Choose areas…" sheet.
Run a renamed copy, never the installed app: copy the Debug app, set `CFBundleIdentifier` to
`com.macdash.app.showcase`, remove `NSServices`, `SUFeedURL` and `Contents/PlugIns/MacDashFinder.appex`,
`codesign --force --deep --sign -`,
`defaults write com.macdash.app.showcase MacDash.OnboardingComplete -bool true` (and
`settings.general.menuBarMonitor -bool false`), then
`open -g -n --env CFFIXED_USER_HOME=<temp home> --env MACDASH_DEMO=1 <copy> --args -AppleLanguages "(en)" -DebugSection smartCare`.
Avoid Protection, Processes (its "Your Mac" card, app list and Health card), History's usage numbers and the
Wi‑Fi note in Settings: they read the real Mac (permissions, displays, packages, running apps, disks and backup,
usage stats, user name). Smart Care's home only shows the demo disk.
`-DebugHealth backup` (or `drive:disk0`, `memory`, `temperature`) opens that Health item's details. The Assistant screen
itself is safe: `-DebugSection assistant -DebugScan YES` shows a fictional analysis (`AssistantDemo`),
and `-DebugAssistant recommendations|review|details|chat` opens that state of it (`chat` opens the chat window,
with a fictional exchange in demo mode; no model runs).
`-DebugPermissionSheet YES` shows the Full Disk Access sheet. Afterwards quit it,
`defaults delete com.macdash.app.showcase`, delete the temp home and `lsregister -u` the copy.
