#!/bin/zsh
# Records the iPhone or iPad tour on a simulator: reseed, install + launch a Debug build of Proj on the
# demo workspace, then record the screen while the XCUITest in driver/ runs the tour.
# usage: record.sh <work dir> <iPhone|iPad>   — writes raw.mov, rec_start.txt, events.txt in <work dir>
# Simulators: SIM="iPhone 18 Pro" / SIM="iPad Pro 11-inch (M5)" by default (override with SIM=...).
H=${0:A:h}; REPO=${H:h:h:h}
W=${1:?usage: record.sh <work dir> <iPhone|iPad>}; W=${W:A}; mkdir -p $W
case $2 in
  iPhone) TEST=IPhoneDemo; SIM=${SIM:-iPhone 18 Pro} ;;
  iPad)   TEST=IPadDemo;   SIM=${SIM:-iPad Pro 11-inch (M5)} ;;
  *) echo "usage: record.sh <work dir> <iPhone|iPad>" >&2; exit 1 ;;
esac
U=$(xcrun simctl list devices available | grep -F "$SIM (" | head -1 | grep -oE '[0-9A-F-]{36}')
[[ -n $U ]] || { echo "No simulator named '$SIM'" >&2; exit 1; }
xcrun simctl boot $U 2>/dev/null; xcrun simctl bootstatus $U -b >/dev/null; open -a Simulator

xcodebuild -project $REPO/ios/Proj.xcodeproj -scheme Proj -configuration Debug -destination "id=$U" \
  -derivedDataPath $W/dd-sim CODE_SIGNING_ALLOWED=NO -quiet build || exit 1
xcrun simctl install $U $W/dd-sim/Build/Products/Debug-iphonesimulator/Proj.app

$H/../seed.sh $W >/dev/null 2>&1
xcrun simctl status_bar $U override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3
xcrun simctl ui $U appearance light
SIMCTL_CHILD_PROJ_DEBUG_ROOT=$W/data/Projects xcrun simctl launch --terminate-running-process $U com.dmetzger57.proj >/dev/null
sleep 3
cd $H/driver
xcodebuild -project Driver.xcodeproj -scheme Demo -destination "id=$U" -derivedDataPath $W/dd-driver \
  CODE_SIGNING_ALLOWED=NO build-for-testing -quiet 2>&1 | grep -E "error"
rm -f $W/raw.mov
xcrun simctl io $U recordVideo --codec=h264 --force $W/raw.mov > $W/rec.log 2>&1 &
REC=$!
while ! grep -q "Recording started" $W/rec.log 2>/dev/null; do sleep 0.05; done
python3 -c "import time;print('%.3f'%time.time())" > $W/rec_start.txt
xcodebuild -project Driver.xcodeproj -scheme Demo -destination "id=$U" -derivedDataPath $W/dd-driver \
  CODE_SIGNING_ALLOWED=NO test-without-building -only-testing:DemoUITests/$TEST > $W/test.log 2>&1
STATUS=$?
sleep 1; kill -INT $REC; wait $REC
xcrun simctl status_bar $U clear
grep "^EVT|" $W/test.log > $W/events.txt
echo "test exit $STATUS; events $(wc -l < $W/events.txt)"
grep -E "error:|FAILTREE" $W/test.log | head
