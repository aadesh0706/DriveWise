# DriveWise

[![GitHub issues](https://img.shields.io/github/issues/aadesh0706/DriveWise)](https://github.com/aadesh0706/DriveWise/issues)
[![GitHub forks](https://img.shields.io/github/forks/aadesh0706/DriveWise)](https://github.com/aadesh0706/DriveWise/network/members)
[![GitHub stars](https://img.shields.io/github/stars/aadesh0706/DriveWise)](https://github.com/aadesh0706/DriveWise/stargazers)
[![License](https://img.shields.io/github/license/aadesh0706/DriveWise)](https://github.com/aadesh0706/DriveWise/blob/main/LICENSE)
[![Top language](https://img.shields.io/github/languages/top/aadesh0706/DriveWise)](https://github.com/aadesh0706/DriveWise)
[![Latest release](https://img.shields.io/github/v/release/aadesh0706/DriveWise)](https://github.com/aadesh0706/DriveWise/releases)
[![Downloads](https://img.shields.io/github/downloads/aadesh0706/DriveWise/total)](https://github.com/aadesh0706/DriveWise/releases)

**Smart disk cleanup for Windows — find out what's filling your drives, then clear it in one click.**

Built by [Aadesh Gulumbe](https://github.com/aadesh0706).

DriveWise scans your connected drives, shows you exactly what's eating up space — junk/cache files, oversized folders, huge individual files, and installed programs — and lets you remove any of it straight from a clean local dashboard. No account, no cloud upload, no telemetry. Everything runs locally on your PC.

---

### 🏷️ Tags

`Windows` `PowerShell` `Disk Cleanup` `Storage Management` `System Utility` `NSIS Installer` `Open Source` `Desktop App` `Free Space` `Drive Analyzer`

---

## Features

- **Every connected drive, not just C:** — pick any fixed, removable, or network drive to analyze.
- **Cache & junk finder** — Windows Update cache, temp files, browser cache, Recycle Bin, old Windows installs, and more, each labeled Safe or Review First.
- **Big folder / big file scanner** — surfaces the largest space hogs on the selected drive.
- **Installed programs list** — see what's installed and launch the official uninstaller for anything you don't need, filtered to the drive you're viewing.
- **Safe by design** — a hardcoded blocklist refuses to touch Windows, Program Files, Users, or a drive root, and the delete API only ever acts on something DriveWise itself just found during a scan. Anything outside of regenerable cache/temp is sent to the Recycle Bin, not permanently deleted.
- **No installs required to run it** — DriveWise is a single PowerShell script (the interpreter ships with every copy of Windows). The installer just makes it a proper double-click app with Start Menu / Desktop shortcuts.

## Installing

1. Download `DriveWise-Setup-1.0.0.exe` from the [Releases](https://github.com/aadesh0706/DriveWise/releases) page.
2. Run it. It installs to your user profile — no admin prompt needed for installation itself.
3. Launch DriveWise from the Desktop or Start Menu shortcut.

When DriveWise actually runs, it will ask for administrator permission — that's needed to see and clean protected system folders. You can decline and it'll still work, just with some locations skipped.

## Running without the installer

You can also just run the two files in `src/` directly on any Windows PC:

1. Double-click `Start-DriveWise.bat`.
2. Approve the UAC prompt.
3. Your browser opens automatically to the DriveWise dashboard.

No Python, Node, or other runtime needed — just the PowerShell that's built into Windows.

## How deletion works

| Category | What happens when you click Remove |
|---|---|
| Cache & Junk | Permanently deleted (these regenerate automatically) |
| Big Folders / Big Files | Sent to the Recycle Bin — recoverable if you change your mind |
| Programs | Launches that program's own official uninstaller |

## Feedback

Found a bug or have an idea for what DriveWise should do next? [Send feedback here](https://docs.google.com/forms/d/e/1FAIpQLSf0f4vhJda0SYY0oVhfR5WXGgSLSDokjaew7zcxVhOAi1Te6Q/viewform?usp=header) — there's also a "Send Feedback" button right in the app.

## Building the installer yourself

The installer is built with [NSIS](https://nsis.sourceforge.io/). With NSIS installed:

```
cd installer
makensis DriveWiseSetup.nsi
```

This produces `DriveWise-Setup-1.0.0.exe` in the `installer/` folder.

## Project structure

```
DriveWise/
├── src/
│   ├── DriveWise.ps1        # The app itself (local server + scan/delete engine + UI)
│   └── Start-DriveWise.bat  # Self-elevating launcher
├── installer/
│   ├── DriveWiseSetup.nsi   # NSIS installer script
│   └── icon.ico
├── LICENSE
└── README.md
```

## Contributing

Found a bug, want a new scan category, or have an idea for the UI? Forks and pull requests are welcome — open an issue first for anything bigger than a small fix so we can talk it through.

If DriveWise saved you some disk space, a ⭐ on the repo helps other people find it.

## License

MIT © 2026 Aadesh Gulumbe
