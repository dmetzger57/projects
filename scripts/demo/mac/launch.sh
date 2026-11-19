#!/bin/zsh
# Launches a Debug build of the Mac app on the demo workspace, in light mode, with its window flush
# against the right edge of the main screen (so toolbar menus open leftward, inside the recording).
# usage: launch.sh <work dir> [noseed]      — writes <work dir>/pid
# Builds the app into <work dir>/dd if needed (PROJ_DEBUG_ROOT only works in Debug builds).
# The Debug build shares Proj's settings; they are backed up to <work dir>/prefs-backup.plist the first
# time, and restored by `launch.sh <work dir> quit`.
set -e
H=${0:A:h}; REPO=${H:h:h:h}
W=${1:?usage: launch.sh <work dir> [noseed|quit]}; mkdir -p $W
APP=$W/dd/Build/Products/Debug/Proj.app

[[ -f $W/pid ]] && { kill $(cat $W/pid) 2>/dev/null || true; rm -f $W/pid; sleep 1; }
if [[ "$2" == quit ]]; then
  [[ -f $W/prefs-backup.plist ]] && defaults import com.dmetzger57.proj $W/prefs-backup.plist && rm $W/prefs-backup.plist
  exit 0
fi
[[ -f $W/prefs-backup.plist ]] || defaults export com.dmetzger57.proj $W/prefs-backup.plist

if [[ ! -d $APP || -n "$REBUILD" ]]; then
  xcodebuild -project $REPO/ios/Proj.xcodeproj -scheme Proj -configuration Debug -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO -derivedDataPath $W/dd -quiet build
fi
for t in drive axdump; do
  [[ $W/$t -nt $H/$t.swift ]] || swiftc -O -o $W/$t $H/$t.swift
done
[[ "$2" == noseed ]] || $H/../seed.sh $W >/dev/null 2>&1

PROJ_DEBUG_ROOT=$W/data/Projects PROJ_DEBUG_TAB=today $APP/Contents/MacOS/Proj \
  -NSRequiresAquaSystemAppearance YES > $W/app.log 2>&1 &
echo $! > $W/pid; sleep 3
# 1280x820 pt at the right edge of a 1728 pt wide main screen (x = 1728 - 1280)
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $(cat $W/pid))
set frontmost to true
set position of window 1 to {448, 150}
set size of window 1 to {1280, 820}
end tell"
sleep 1
