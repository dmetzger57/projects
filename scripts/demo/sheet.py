#!/usr/bin/env python3
"""Review aid: a contact sheet of the frame `delay` s after each event in events.txt[a:b], labelled
with the event, written to <work dir>/sheet.png.  usage: sheet.py <work dir> a b [delay]"""
import subprocess, sys, shutil
from pathlib import Path
D = Path(sys.argv.pop(1)).resolve(); cs = D / "cs"; shutil.rmtree(cs, ignore_errors=True); cs.mkdir()
a, b = int(sys.argv[1]), int(sys.argv[2]); delay = float(sys.argv[3]) if len(sys.argv) > 3 else 1.2
st = float((D / "rec_start.txt").read_text())
ev = [l.split("|") for l in (D / "events.txt").read_text().splitlines()][a:b]
for i, e in enumerate(ev):
    off = max(0, float(e[1]) - st + delay); x = cs / "x.png"; out = cs / f"{a+i:03d}.png"
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", f"{off:.3f}", "-i", str(D / "raw.mov"),
                    "-frames:v", "1", "-vf", "scale=640:-1", str(x)], check=True)
    subprocess.run(["magick", str(x), "-font", "/System/Library/Fonts/Supplemental/Arial.ttf", "-fill", "red", "-pointsize", "18", "-annotate", "+8+22",
                    f"{a+i} {e[2]} {' '.join(e[3:])[:50]}", str(out)], stderr=subprocess.DEVNULL)
(cs / "x.png").unlink()
subprocess.run(["magick", "montage", "-font", "/System/Library/Fonts/Supplemental/Arial.ttf", *sorted(map(str, cs.glob("*.png"))), "-tile", "5x", "-geometry", "+4+4", str(D / "sheet.png")], stderr=subprocess.DEVNULL)
