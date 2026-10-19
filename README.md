# MacDash

**English** · [Português](README.pt-BR.md)

A native macOS app (SwiftUI) for cleaning and maintenance: Smart Care, Advanced Cleanup, Applications (uninstall, login items and updates), Protection (app permissions, security checks, Wi‑Fi and browser extensions), Processes, Space Lens, Duplicate Files and Similar Photos.

Nothing is removed without your approval: every scan ends on a review screen.

## Build and run

```bash
scripts/dev.sh run     # builds (Debug) and opens the app
scripts/dev.sh build   # builds only
scripts/dev.sh test    # runs the tests
```

The app ends up in `build/derived/Build/Products/Debug/MacTidy.app`. The Xcode project is `PureMac.xcodeproj` (scheme `PureMac`). The project's internal names are still `PureMac`; the product is `MacTidy.app`, with bundle ID `com.mactidy.app`. Requires macOS 13 or later.

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
