# Proj for iPhone

A native SwiftUI app for the same `~/Documents/Projects` folder the `proj` CLI and web UI use.
It reads and writes the README.md files directly in iCloud Drive, so it works anywhere,
without the Mac being on, and changes show up in `proj` on the Mac.

**Setup:** an empty folder is set up for you (areas, template, Closed, backlog) · **New Area** ·
**Projects:** projects by area, filters, search, goal progress and spending ·
**Project:** status, goals (tap to tick off, swipe to delete), a **Tasks** checklist (tap the box
to tick, tap the text to edit, swipe or long-press to edit, move or delete; drag to reorder; long-press ›
Attach File/Link to add files from iCloud Drive › Documents or URLs, tap one to open it; long-press › Add Note
for notes shown under the task, tap a note to edit it, long-press it to delete), notes, editing
Description, **Project Files** links to files in iCloud Drive › Documents or to URLs (browse or
type a path, friendly names, Show Paths, tap to open), links, and receipts (scan with the camera or pick a file,
preview, detach), rename, close and reopen · **Ideas:** add, delete, make into a project ·
pull to refresh; reloads when you return to the app.

## Install on your iPhone (free Apple ID)

1. **Install Xcode** from the Mac App Store and open it once. Accept the license and let it
   install the iOS platform when it offers to.
2. **Add your Apple ID:** Xcode → Settings → Accounts → **+** → Apple ID. This creates a free
   "Personal Team".
3. **Prepare the iPhone:** connect it by USB and tap *Trust This Computer*. Then turn on
   **Settings → Privacy & Security → Developer Mode**; the phone restarts.
4. **Open the project:** `open ios/Proj.xcodeproj`
   - Select the **Proj** target → **Signing & Capabilities** → Team: *your name (Personal Team)*.
   - If Xcode says the bundle ID is unavailable, change it to something unique, e.g.
     `com.<yourname>.proj` (or run `python3 ios/make_xcodeproj.py --bundle-id com.<yourname>.proj`).
5. **Run:** choose your iPhone as the run destination (top bar) and press **⌘R**.
   The first time, the iPhone will refuse to open the app. Go to **Settings → General → VPN & Device
   Management**, trust your developer certificate, then open Proj.
6. **In the app:** tap *Choose Projects Folder* → **iCloud Drive › Documents › Projects** → Open.
   Then in **Settings**, choose **Receipts** → **iCloud Drive › Documents › Receipts**.

### Free account limits

- The app **stops opening after 7 days**. Connect the phone and press ⌘R in Xcode again
  (after the first time, it can also deploy over Wi-Fi). Nothing is lost, because your data
  lives in iCloud Drive, not in the app.
- At most 3 apps installed from Xcode at once on a free account.
- The app does not use iCloud entitlements, which free accounts can't use. It works through
  folders you pick in the Files picker, which it remembers.

## Publishing and sharing with family (paid Apple Developer Program)

A paid membership ($99/year) removes the 7-day limit and allows TestFlight and App Store distribution.

**One-time setup after enrolling**
1. Xcode → Settings → Accounts: your Apple ID now shows the paid team. In the **Proj** target →
   Signing & Capabilities, set **Team** to the paid team (not "Personal Team"). Then run
   `python3 ios/make_xcodeproj.py --team <NEWTEAMID>` once, or just commit Xcode's change.
2. If the bundle ID `com.dmetzger57.proj` is refused (it was first registered by the free team),
   pick a new one, e.g. `com.dmetzger57.projapp`, in the same tab.
3. In [App Store Connect](https://appstoreconnect.apple.com) → Apps → **+** → New App: iOS, any
   available name (the home-screen name stays "Proj"), the bundle ID from step 2, SKU `proj`.
   Under **App Privacy**, answer "No data collected".

**Each release**
```sh
sh ios/release.sh            # runs the checks, archives, uploads (build number = date/time)
```
The build appears in App Store Connect → **TestFlight** after processing.

**Sharing with family through TestFlight**
- **External testing:** TestFlight → *External Testing* → **+** group "Family" → add the build →
  submit for Beta App Review (the first time only; usually under a day) → **Enable Public Link**,
  and send that link. Family members install the free **TestFlight** app, then tap the link.
- TestFlight builds expire after **90 days**. Run `release.sh` again before then; testers update
  in the TestFlight app.
- For no expiry, submit the same build for App Store review, either public or as an
  **unlisted** app (request unlisted distribution from Apple), and share the link.

**Family members' data**
- On first launch they choose a folder in *their* iCloud Drive. If it is empty, Proj offers to
  **set it up**: areas, template, Closed folder, idea backlog, and optionally `3 - Receipts`
  for receipts. No Mac is needed.
- To **share projects**, share your whole `Projects` folder in the Files app (Share →
  Collaborate) and have them choose the shared folder in Proj. Their edits then show up in
  `proj` on your Mac. Share the whole folder, not one area: Proj expects to be given the
  folder that *contains* the areas.
- Amounts are shown in each phone's local currency. The files store plain numbers.

## How it works

- `ProjKit/`: Swift package `ProjKitCore`, a port of the Python model and `ops.py`
  (README parsing, notes and sections, goals, links, receipts, close and reopen, rename, ideas),
  with no dependencies. Its small YAML reader and writer handles the front-matter format in
  [`../SPEC.md`](../SPEC.md). Keys the app doesn't change are written back byte-for-byte;
  changed keys are written in the same style as the Python tool.
- All file access is coordinated with `NSFileCoordinator`, which downloads evicted iCloud files
  and keeps edits from other devices from interleaving. Each edit re-reads the README first.
- `App/`: the SwiftUI app (iOS 17+). iPhone-only code (the document scanner) is in
  `App/Platform.swift`.
- A receipt picked with **Choose File** is linked by its path, never copied (pick it from iCloud Drive › Documents).
  Only scanned receipts become new files, saved as `Receipts/<year>/<date> <description>.pdf`. iOS can't set Finder tags,
  so run `proj lint --fix` on the Mac to add the `receipt` tag (lint reports it as L013).

## Checks (no Xcode needed)

```sh
cd ios/ProjKit && swift run Checks   # core tests, including byte-identical round-trip of real READMEs
sh ios/crosscheck.sh                 # Swift edits a copy of your projects; Python verifies and lints it
```

`Proj.xcodeproj` is generated by `make_xcodeproj.py`. New Swift files in `App/` are picked up
automatically, so regenerate it only to change build settings.

If Xcode won't open the project: File → New → Project → iOS App (SwiftUI, name "Proj").
Delete the generated Swift files, drag in the `App/` folder, then File → Add Package
Dependencies → Add Local… → `ios/ProjKit`, and add `ProjKitCore` to the target.
