# Installing the Proj app on the iPhone

## Prompt

> what are the steps / workflow for installing the app on my iphone

## Response

Your iPhone is already set up for this (Developer Mode on, your certificate trusted), so installing a new version takes one step. There are two ways to do it.

### Option A: from Xcode
1. Connect the iPhone by cable (or have it on the same Wi-Fi as the Mac after the first cable install) and **unlock it**.
2. Open the project: `open ~/src/projects/ios/Proj.xcodeproj`
3. In the toolbar at the top, check the run destination reads **Proj › DJM**. If not, click it and choose **DJM**.
4. Press **⌘R**. Xcode builds, installs and opens the app on the phone.

### Option B: from Terminal
```sh
cd ~/src/projects/ios
xcodebuild -project Proj.xcodeproj -scheme Proj -configuration Debug \
  -destination 'id=00008160-00064D8426E00036' -derivedDataPath /tmp/proj-build \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008160-00064D8426E00036 \
  /tmp/proj-build/Build/Products/Debug-iphoneos/Proj.app
xcrun devicectl device process launch --device 00008160-00064D8426E00036 com.dmetzger57.proj
```
The phone must be unlocked for the last step, which opens the app.

### Things to know
- **7-day limit:** with your free Personal Team, the app stops opening 7 days after each install. Reinstall with A or B; your data is safe because it lives in iCloud Drive, not in the app.
- **Keychain prompt:** if "codesign wants to access key…" appears, enter your Mac login password and click **Always Allow**.
- **"Untrusted Developer":** this only appears if the certificate changes. Fix it under **Settings → General → VPN & Device Management → your Apple ID → Trust**.
- **When the paid Developer Program is approved:** switch **Team** in Xcode (Proj target → Signing & Capabilities). Then `sh ios/release.sh` uploads to TestFlight. You and your family install from the TestFlight app, builds last 90 days, and no cable is needed.
