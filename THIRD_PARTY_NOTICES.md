# Third-Party Notices

MacDash includes code adapted from the projects listed below. Each
project's license applies to the portions taken from it.

## Mac Sai

- Source: https://github.com/iliyami/MacSai
- License: BSD 3-Clause
- Used in:
  - `PureMac/Services/SparkleUpdateChecker.swift`: Sparkle appcast parsing and version comparison
  - `PureMac/Services/LaunchItemControl.swift`: login item handling
  - `PureMac/Services/UnusedAppsFinder.swift`: unused app detection rules
  - `PureMac/Services/AppPermissionsReader.swift`: TCC permission reading
  - `PureMac/Services/BrowserExtensionsScanner.swift`: browser extension discovery and safe removal
  - `PureMac/Services/SavedWiFiNetworks.swift`: saved Wi-Fi network listing and removal
  - `PureMac/Services/SpaceLensScanner.swift`: squarified treemap layout and file categories

```
BSD 3-Clause License

Copyright (c) 2026, Mac Sai Contributors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Kitesail

- Source: https://github.com/jaysahastrabudhe/kitesail
- License: MIT
- Used in:
  - `PureMac/Services/MemoryInsights.swift`: memory breakdown, per-app footprint and memory diagnosis
  - `PureMac/Views/Tools/PerformanceOverview.swift`: memory screen layout

```
MIT License

Copyright (c) 2026 Jay Sahastrabudhe

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## SquirrelDisk

- Source: https://github.com/adileo/squirreldisk
- Copyright (c) Adileo Barone
- License: GNU Affero General Public License v3.0 (https://www.gnu.org/licenses/agpl-3.0.html)

## Disk Audit

- Source: https://github.com/srwiseman/diskaudit-macos
- Copyright (C) 2026 Stephen Wiseman
- License: GNU General Public License v3.0 or later (https://www.gnu.org/licenses/gpl-3.0.html)

## Stats

- Source: https://github.com/exelban/stats
- Copyright (c) 2019 Serhiy Mytrovtsiy
- License: MIT
- Used in:
  - `PureMac/Services/MenuBarReadout.swift`: the stacked menu bar readout style
  - `PureMac/Services/HardwareSensors.swift`: the SMC structure layout

## Performance Monitor

- Source: https://github.com/inequitas/performancemonitor
- Copyright (c) 2026 inequitas
- License: MIT
- Used in:
  - `PureMac/Services/HardwareSensors.swift`: GPU load, disk activity, fans and system power
  - `PureMac/Services/MenuBarReadout.swift`: template drawing and fixed slot widths for the menu bar readout
