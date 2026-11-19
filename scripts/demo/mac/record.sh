#!/bin/zsh
# Records the Mac tour: reseed + launch the app, record the window region (at 2x) with ffmpeg while
# drive runs tour.txt, then quit the app and restore Proj's settings. Hands off the mouse while it runs.
# usage: record.sh <work dir> [tour file]   — writes raw.mov, rec_start.txt, events.txt in <work dir>
H=${0:A:h}
W=${1:?usage: record.sh <work dir> [tour file]}; W=${W:A}
TOUR=${2:-$H/tour.txt}
$H/launch.sh $W || exit 1
rm -f $W/raw.mov
# window 448,150 1280x820 pt -> 896,300 2560x1640 px on the Retina main screen ("Capture screen 0")
ffmpeg -hide_banner -f avfoundation -capture_cursor 1 -framerate 30 -use_wallclock_as_timestamps 1 \
  -i "Capture screen 0:none" -vf "crop=2560:1640:896:300" -c:v h264_videotoolbox -b:v 24M -y $W/raw.mov > $W/rec.log 2>&1 &
REC=$!
while ! grep -q "start:" $W/rec.log 2>/dev/null; do sleep 0.05; done
sleep 1
# wall-clock time of the first recorded frame: lines up the drive events with the video
grep -m1 -o "start: [0-9.]*" $W/rec.log | cut -d' ' -f2 > $W/rec_start.txt
$W/drive $(cat $W/pid) $TOUR > $W/events.txt 2> $W/drive.err
sleep 1; kill -INT $REC; wait $REC
$H/launch.sh $W quit
echo "events $(wc -l < $W/events.txt); not found: $(tr '\n' ' ' < $W/drive.err)"
