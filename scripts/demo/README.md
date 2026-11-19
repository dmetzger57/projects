# Demo videos

Scripted feature tours of the apps, recorded and turned into 1080p videos with captions, click/touch
indicators and intro/outro cards. Every run starts from a fictional workspace (`seed.sh`: Kitchen
Remodel, Vegetable Beds, Learn Spanish, …), so none of your real projects appear.

```
make demo-mac       # ios/build/demo/proj-mac-demo.mp4     (~3 min; takes over the mouse)
make demo-iphone    # ios/build/demo/proj-iphone-demo.mp4  (simulator "iPhone 18 Pro")
make demo-ipad      # ios/build/demo/proj-ipad-demo.mp4    (simulator "iPad Pro 11-inch (M5)")
make demo-web       # ios/build/demo/proj-web-demo.mp4     (headless Chrome; ~3.5 min, runs in the background)
```

All output (demo data, Debug builds, raw recordings) goes in `ios/build/demo/<platform>/`.
Needs `ffmpeg`, ImageMagick (`magick`) and the Python venv (`make setup`); the web tour also needs Google
Chrome and Node 22+.

## How it works

1. **Seed:** `seed.sh <work dir>` builds the demo workspace with the `proj` CLI.
2. **Record:** a Debug build of the app runs on that workspace (`PROJ_DEBUG_ROOT`; Debug builds only)
   while a driver plays the tour and prints `EVT|<epoch>|…` lines: `SCENE` (caption) and the
   clicks/taps (for the indicators).
   - **Mac** (`mac/`): `drive.swift` moves the real cursor with CGEvent and finds controls through the
     Accessibility API; the tour is plain text in `mac/tour.txt` (commands listed at the top of
     `drive.swift`). ffmpeg records the window region on the main (Retina) screen. The window sits
     at the screen's right edge so toolbar menus open inside it.
   - **iPhone/iPad** (`ios/`): an XCUITest (`ios/driver/DemoUITests/IPhoneDemo.swift`,
     `IPadDemo.swift`) drives the simulator while `simctl io recordVideo` records it.
   - **Web** (`web/`): `record.sh` serves the demo workspace on port 8791 (the launchd UI is untouched) and
     `drive.mjs` plays `web/tour.txt` in headless Chrome over the DevTools protocol (no npm packages),
     drawing a cursor into the page and saving the screencast frames, which become `raw.mov`. Native
     `<select>` menus and `confirm()` dialogs don't render headless, so the tour sets selects directly and
     avoids confirm prompts.
3. **Compose:** `compose.py <work dir> <iPhone|iPad|Mac|Web> <out.mp4>` cuts the recording to the tour,
   adds the graphics drawn by `render.swift` (background, device frame or window shadow, one caption
   card per scene, intro/outro) and writes the video. Captions are synced from the first frame's
   time (`rec_start.txt`).

## Changing a tour

- Mac: edit `mac/tour.txt`. To find a control's label, run the app (`mac/launch.sh <work dir>`),
  then `<work dir>/axdump $(cat <work dir>/pid)`; try single steps with
  `<work dir>/drive $(cat <work dir>/pid) -c "click|Projects@AXStaticText"`.
  `mac/launch.sh <work dir> quit` closes it and restores Proj's settings (the Debug build shares them).
- iPhone/iPad: edit the XCUITest.
- Web: edit `web/tour.txt` (commands and target syntax at the top of `web/drive.mjs`); targets are
  aria-labels, titles, placeholders or visible text, or `css:` selectors.
- After recording, `python3 sheet.py <work dir> 0 30` makes a contact sheet (`sheet.png`) of the
  frame after each event, to check that every step landed before composing.

Requirements on the Mac: the terminal needs Screen Recording and Accessibility permission. The Mac
geometry assumes a 1728 × 1117 pt main screen (MacBook Pro 16"); change the window position in
`mac/launch.sh` and the crop in `mac/record.sh` for another screen.
