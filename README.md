# MacDash

**English** · [Português](README.pt-BR.md)

A native macOS app (SwiftUI) for cleaning and maintenance: Smart Care, Advanced Cleanup, Applications (uninstall, login items and updates), Protection (app permissions, security checks, Wi‑Fi and browser extensions), Processes, Space Lens, Duplicate Files and Similar Photos.

Nothing is removed without your approval: every scan ends on a review screen.

## Install

Pick one:

1. **Terminal, one line (recommended).** Paste this into Terminal:
   ```sh
   curl -fsSL https://witchmymac.com/install.sh | bash -s macdash
   ```
   It downloads the latest release from GitHub, checks its SHA-256, installs MacDash in Applications and opens it. There's no macOS warning, because files downloaded by `curl` don't get the "downloaded from the internet" mark. Run the same line again to update. The script is open: [install.sh](https://witchmymac.com/install.sh).
2. **Download the DMG** from [Releases](https://github.com/matthfaria96/MacDash/releases) or [witchmymac.com](https://witchmymac.com), drag MacDash to Applications, then allow it once with:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/MacDash.app"
   ```
   It only removes the "downloaded from the internet" mark from that app.
3. **Download the DMG** and allow it in System Settings: open the app, click OK on the warning, then go to System Settings › Privacy & Security and click Open Anyway.

Requires macOS 13 or later.

## Build and run

```bash
scripts/dev.sh run     # builds (Debug) and opens the app
scripts/dev.sh build   # builds only
scripts/dev.sh test    # runs the tests
```

The app ends up in `build/derived/Build/Products/Debug/MacDash.app`. The Xcode project is `PureMac.xcodeproj` (scheme `PureMac`). The project's internal names are still `PureMac`; the product is `MacDash.app`, with bundle ID `com.macdash.app`. Requires macOS 13 or later.

## Permissions

In **Settings › Permissions** (and on first use) the app shows, checked live with macOS:

- **Full Disk Access** (required): to scan Mail, Safari, app containers and the Trash, and to read app permissions in Protection.
- **App Management**: to remove and update other apps.
- **System Events automation**: to turn login items on and off.
- **Notifications**: to tell you when a scheduled scan finishes.

Wi‑Fi passwords live in the system keychain: macOS asks for your Mac account's user name and password. Choose "Always Allow" and that network won't ask again.

## Credits and licenses

MacDash is free software, Copyright (C) 2026 Matheus Faria, under the **GNU AGPL v3.0** license ([`LICENSE`](LICENSE)). You may use, study, modify and redistribute it; anyone who distributes a modified version must publish its source under the same license.

- Based on [PureMac](https://github.com/momenbasel/PureMac), MIT license (notice in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)).
- Features adapted from [Mac Sai](https://github.com/iliyami/MacSai), 3-clause BSD license ([`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)).
- Space Lens rings adapted from [SquirrelDisk](https://github.com/adileo/squirreldisk) (AGPL-3.0) and per-app size adapted from [Disk Audit](https://github.com/srwiseman/diskaudit-macos) (GPL-3.0).
- The other credits (Kitesail, Stats, Performance Monitor) are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and in Settings › Open source licenses.
- The antivirus was written from scratch. It contains no code, rules or databases from any commercial product; it uses the EICAR test pattern and its own rules.
- Other product names mentioned belong to their owners; MacDash is not affiliated with them.
