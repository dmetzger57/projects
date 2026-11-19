#!/bin/zsh
# Records the web UI tour: reseed, serve the demo workspace on its own port (not the launchd one), play
# tour.txt in headless Chrome (drive.mjs) and turn its screencast frames into raw.mov.
# usage: record.sh <work dir> [tour file]   — writes raw.mov, rec_start.txt, events.txt in <work dir>
# Needs Google Chrome and Node 22+ (built-in WebSocket).
H=${0:A:h}; REPO=${H:h:h:h}
W=${1:?usage: record.sh <work dir> [tour file]}; W=${W:A}; mkdir -p $W
TOUR=${2:-$H/tour.txt}
PORT=${PORT:-8791}

$H/../seed.sh $W >/dev/null 2>&1 || { echo "seed failed" >&2; exit 1; }
# The project page shows the folder with ~ for the home folder: serve with HOME=<work dir>/home and the
# workspace linked at ~/Documents/Projects, so it reads like a real one.
mkdir -p $W/home/Documents; ln -sfn $W/data/Projects $W/home/Documents/Projects
# placeholder PDFs for the seeded receipts (paths are relative to the receipts folder)
R=$W/home/Documents/Receipts; rm -rf $R; mkdir -p $R/2026
grep -h "path: 2026/" $W/data/Projects/*/*/README.md | sed 's/.*path: //' | while read -r f; do
  magick -size 850x1100 xc:white -font /System/Library/Fonts/Supplemental/Arial.ttf -pointsize 44 \
    -annotate +80+160 "${${f:t:r}#* }" "$R/$f"
done
HOME=$W/home $REPO/.venv/bin/proj serve --port $PORT --no-open --root $W/home/Documents/Projects \
  --receipts $W/home/Documents/Receipts > $W/serve.log 2>&1 &
SRV=$!
trap "kill $SRV 2>/dev/null" EXIT
for i in {1..40}; do curl -s -o /dev/null http://127.0.0.1:$PORT/ && break; sleep 0.25; done

node $H/drive.mjs http://127.0.0.1:$PORT $TOUR $W > $W/events.txt 2> $W/drive.err
head -1 $W/frames.txt | cut -d'|' -f2 > $W/rec_start.txt

# variable-rate screencast frames -> constant 30 fps video
python3 - $W <<'PY'
import sys
W = sys.argv[1]
rows = [l.split("|") for l in open(f"{W}/frames.txt").read().split()]
end = float(open(f"{W}/events.txt").read().split("|END")[0].split("|")[-1]) + 2
out = []
for i, (f, t) in enumerate(rows):
    nxt = float(rows[i + 1][1]) if i + 1 < len(rows) else max(end, float(t) + 0.1)
    out.append(f"file '{W}/frames/{f}'\nduration {nxt - float(t):.4f}")
out.append(f"file '{W}/frames/{rows[-1][0]}'")
open(f"{W}/frames.ffconcat", "w").write("\n".join(out) + "\n")
PY
ffmpeg -nostdin -hide_banner -loglevel error -y -f concat -safe 0 -i $W/frames.ffconcat \
  -vf "fps=30,format=yuv420p" -c:v libx264 -crf 12 -preset fast $W/raw.mov
echo "events $(wc -l < $W/events.txt); frames $(wc -l < $W/frames.txt); not found: $(tr '\n' ' ' < $W/drive.err)"
