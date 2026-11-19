#!/usr/bin/env python3
"""Builds the final demo video from a recording: <work dir>/raw.mov + events.txt + rec_start.txt,
with captions, click/touch indicators and intro/outro cards drawn by render.swift (next to this file).
usage: compose.py <work dir> <iPhone|iPad|Mac|Web> <output.mp4>"""
import subprocess, sys
from pathlib import Path

D = Path(sys.argv[1]).resolve(); PLATFORM = sys.argv[2]; OUT = sys.argv[3]
G = D / "gfx"; G.mkdir(exist_ok=True)
S = float((D / "rec_start.txt").read_text())
ev = [l.split("|") for l in (D / "events.txt").read_text().splitlines()]
for e in ev: e[1] = float(e[1]) - S                      # seconds into raw.mov

# geometry per platform (passed to render.swift in layout.json); pts = screen width in points
LAYOUTS = {
    "iPhone": dict(x=250, y=49, w=452, h=982, r=62, bezel=14, tx=840, tw=960, title=76, sub=40, ty=400, pts=402),
    "Mac":    dict(x=56, y=128, w=1300, h=832, r=17, bezel=0, tx=1410, tw=470, title=50, sub=30, ty=330, pts=1280),
    # Web: the Mac window with a drawn browser toolbar (bar px) above a 1280x768 viewport
    "Web":    dict(x=56, y=180, w=1300, h=780, r=17, bezel=0, bar=52, tx=1410, tw=470, title=50, sub=30, ty=330, pts=1280),
    "iPad":   dict(x=64, y=154, w=1120, h=772, r=24, bezel=20, tx=1240, tw=630, title=60, sub=34, ty=360, pts=1210),
}
LAY = LAYOUTS[PLATFORM]
SX, SY, SW, SH = LAY["x"], LAY["y"], LAY["w"], LAY["h"]
K = SW / LAY["pts"]                                       # px per screen point
import json; (G / "layout.json").write_text(json.dumps({k: float(v) for k, v in LAY.items()}))
FPS = 30
INTRO, OUTRO, XF = 3.5, 3.5, 0.6

scenes = [e for e in ev if e[2] == "SCENE"]
end = next(e[1] for e in ev if e[2] == "END")
T0 = scenes[0][1] - 0.6                                   # trim start in raw time
T1 = end + 0.8
MAIN = T1 - T0

(G / "captions.tsv").write_text("\n".join(f"{s[3]}\t{s[3]}\t{s[4]}" for s in scenes))
subprocess.run(["swift", str(Path(__file__).resolve().parent / "render.swift"), str(G), PLATFORM, str(G / "captions.tsv")], check=True)

# ---- main segment
LEN = f"{MAIN + 6:.2f}"
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(D / "raw.mov"), "-vf",
                f"fps={FPS},trim=start={T0:.3f},setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=5,scale={SW}:{SH}:flags=lanczos",
                "-c:v", "libx264", "-crf", "10", "-preset", "fast", "-pix_fmt", "yuv420p", str(G / "screen.mp4")], check=True)
inputs = ["-loop", "1", "-framerate", str(FPS), "-t", LEN, "-i", str(G / "frame.png"), "-i", str(G / "screen.mp4"),
          "-loop", "1", "-t", LEN, "-i", str(G / "mask.png"), "-loop", "1", "-t", LEN, "-i", str(G / "dot.png")]
f = ["[1:v]format=rgba[scr]",
     "[2:v]format=gray[m]", "[scr][m]alphamerge[scrm]",
     f"[scrm]setpts=PTS-STARTPTS[scr2]", f"[0:v][scr2]overlay={SX}:{SY}:shortest=0:eof_action=repeat[v0]"]
lst = []
for i, s in enumerate(scenes):
    a = max(s[1] - T0, 0)
    b = (scenes[i + 1][1] - T0) if i + 1 < len(scenes) else MAIN + 1
    if i == 0 and a > 0:
        lst.append(f"file '{G}/blank.png'\nduration {a:.3f}")
    lst.append(f"file '{G}/cap{i:02d}.png'\nduration {b - a:.3f}")
lst.append(f"file '{G}/cap{len(scenes)-1:02d}.png'")
(G / "caps.txt").write_text("\n".join(lst) + "\n")
subprocess.run(["magick", "-size", "1920x1080", "xc:none", str(G / "blank.png")], check=True)
inputs += ["-f", "concat", "-safe", "0", "-i", str(G / "caps.txt")]
f.append(f"[4:v]fps={FPS},format=rgba[caps]")
f.append("[v0][caps]overlay=0:0:shortest=0[vc]")
cur = "vc"

for e in ev:                                               # Mac events -> touch-dot kinds
    if e[2] in ("CLICK", "RCLICK"): e[2] = "TAP"
    elif e[2] == "DRAG":
        x, y, dx, dy = map(float, e[3:7]); e[2:] = ["SWIPE", x, y, x + dx, y + dy]
touches = [e for e in ev if e[2] in ("TAP", "HOLD", "SWIPE")]
f.append(f"[3:v]split={len(touches)}" + "".join(f"[d{j}]" for j in range(len(touches))))
for j, e in enumerate(touches):
    t = e[1] - T0 + (0.0 if PLATFORM in ("Mac", "Web") else 0.08)
    px = lambda x: SX + float(x) * K - 28
    py = lambda y: SY + float(y) * K - 28
    if e[2] == "TAP":
        dur, xe, ye = 0.35, f"{px(e[3]):.1f}", f"{py(e[4]):.1f}"
    elif e[2] == "HOLD":
        dur, xe, ye = 1.5, f"{px(e[3]):.1f}", f"{py(e[4]):.1f}"
    else:
        x0, y0, x1, y1 = map(float, e[3:7])
        dur = 1.3 if PLATFORM in ("Mac", "Web") else (0.55 if y0 == y1 else 0.35)
        xe = f"{px(x0):.1f}+({(x1-x0)*K:.1f})*min(1,(t-{t:.3f})/{dur})"
        ye = f"{py(y0):.1f}+({(y1-y0)*K:.1f})*min(1,(t-{t:.3f})/{dur})"
    nxt = f"t{j}"
    f.append(f"[{cur}][d{j}]overlay=x='{xe}':y='{ye}':eval=frame:enable='between(t,{t:.3f},{t+dur:.3f})'[{nxt}]")
    cur = nxt
f.append(f"[{cur}]trim=duration={MAIN:.3f},setpts=PTS-STARTPTS,fps={FPS},format=yuv420p,settb=1/{FPS}[main]")

(G / "filter.txt").write_text(";\n".join(f))
cmd = ["ffmpeg", "-y", "-loglevel", "warning", "-stats", *inputs, "-/filter_complex", str(G / "filter.txt"),
       "-map", "[main]", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
       "-r", str(FPS), str(G / "main.mp4")]
subprocess.run(cmd, check=True)
pass2 = ["ffmpeg", "-y", "-loglevel", "warning", "-loop", "1", "-t", str(INTRO), "-i", str(G / "intro.png"),
         "-i", str(G / "main.mp4"), "-loop", "1", "-t", str(OUTRO), "-i", str(G / "outro.png"), "-filter_complex",
         f"[0:v]fps={FPS},format=yuv420p,setsar=1,settb=1/{FPS}[a];[1:v]setsar=1,settb=1/{FPS}[b];"
         f"[2:v]fps={FPS},format=yuv420p,setsar=1,settb=1/{FPS}[c];"
         f"[a][b]xfade=transition=fade:duration={XF}:offset={INTRO-XF}[ab];"
         f"[ab][c]xfade=transition=fade:duration={XF}:offset={INTRO+MAIN-2*XF:.3f}[out]",
         "-map", "[out]", "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", OUT]
subprocess.run(pass2, check=True)
print(f"wrote {OUT}: {INTRO + MAIN + OUTRO - 2*XF:.1f}s, {len(scenes)} captions, {len(touches)} touches")
