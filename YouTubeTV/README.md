# YouTube TV (tvOS prototype)

A minimal Apple TV (tvOS 18+, SwiftUI) app that logs into YouTube via the device-activation
flow, shows your personalized Home recommendations, and plays videos natively with AVPlayer.

## Setup

1. Install [xcodegen](https://github.com/yonyz/XcodeGen): `brew install xcodegen`
2. Provide credentials (kept out of source control):
   ```sh
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   # then edit Config/Secrets.xcconfig and fill in the three values
   ```
   These are the well-known **public** YouTube-on-TV OAuth credentials (the same ones SmartTube
   and yt-dlp use) plus the public InnerTube web API key — not per-user confidential secrets,
   but kept in a gitignored file so nothing credential-shaped lands in the repo.
3. Generate the Xcode project and build:
   ```sh
   xcodegen generate
   open YouTubeTV.xcodeproj    # or build from the command line
   ```

## Run on the Apple TV simulator (CLI)

```sh
xcodebuild -project YouTubeTV.xcodeproj -scheme YouTubeTV -sdk appletvsimulator \
  -destination 'name=Apple TV 4K (3rd generation)' -derivedDataPath build build
xcrun simctl install booted build/Build/Products/Debug-appletvsimulator/YouTubeTV.app
xcrun simctl launch booted dk.delectosoft.metube
```

Sign in by visiting the shown URL on your phone/computer and entering the code (or scan the QR).

## Run on a real Apple TV

One-time setup:

1. Sign into Xcode with your Apple ID (**Xcode → Settings → Apple Accounts**) so it can create a
   provisioning profile, and set `DEVELOPMENT_TEAM` in your own `Config/Secrets.xcconfig`, then
   re-run `xcodegen generate`. Your team ID is the `OU` field of your signing certificate:

   ```sh
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
   ```

   (It is *not* the value in parentheses shown by `security find-identity` — that's the
   certificate ID. Xcode also lists the team under **Settings → Apple Accounts**.)
2. Pair the device: on the Apple TV open **Settings → Remote Apps and Devices**, then in Xcode
   **Window → Devices and Simulators** select it under *Discovered* and enter the code shown on
   the TV. The Mac and Apple TV must be on the same network.

Then build and install (`DEVICE_ID` comes from `xcrun devicectl list devices`):

```sh
DEVICE_ID=<your-apple-tv-udid>
xcodebuild -project YouTubeTV.xcodeproj -scheme YouTubeTV -sdk appletvos \
  -destination "id=$DEVICE_ID" -derivedDataPath build-device -allowProvisioningUpdates build
xcrun devicectl device install app --device "$DEVICE_ID" \
  build-device/Build/Products/Debug-appletvos/YouTubeTV.app
xcrun devicectl device process launch --device "$DEVICE_ID" dk.delectosoft.metube
```

On a free Apple developer account the installed app stops working after 7 days and must be
reinstalled; a paid membership lasts a year.

## Drive the simulator remote

tvOS has no touch input, so the simulator is navigated entirely with the Siri Remote's
directional pad. `xcrun simctl` cannot send those presses (it has no key/press subcommand),
so `Scripts/tvremote` synthesizes key events to Simulator.app instead:

```sh
Scripts/tvremote right 2 --shot     # two steps right, then screenshot
Scripts/tvremote down               # one step down
Scripts/tvremote select             # up down left right select menu playpause
```

It raises the Apple TV window before the first press (activation otherwise swallows one) and
spaces presses 1s apart by default, because tvOS treats rapid repeats as an accelerating
scroll — two quick rights can jump several cards. It needs Simulator.app running and
Accessibility permission, and it necessarily takes keyboard focus, so it is interactive-only.

Screenshots work independently of the remote, and are the reliable way to see a tvOS device:

```sh
xcrun simctl io booted screenshot out.png   # picks the TVOut display automatically
```

## UI tests

`UITests/` drives the focus engine through `XCUIRemote` — the supported, headless path, and the
right one for CI:

```sh
xcodebuild test -project YouTubeTV.xcodeproj -scheme YouTubeTV -sdk appletvsimulator \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -derivedDataPath build
```

The tests skip rather than fail when the target simulator is signed out or the feed fails to
load: both states leave a single focusable button, so directional navigation has nothing to
assert. Sign in on the simulator you test against to actually exercise them. Note that
`xcodebuild test` installs the app it builds onto that device.

## Lint & format

```sh
brew install swiftlint
swiftlint lint --quiet --strict            # style rules (.swiftlint.yml)
xcrun swift-format lint --strict --recursive Sources UITests   # layout (.swift-format)
xcrun swift-format format -i --recursive Sources UITests       # auto-fix layout
```

swift-format owns layout (4-space indent, 120-column lines); SwiftLint enforces
everything else. Both run in CI (`.github/workflows/tvos-ci.yml`) with `--strict`,
so any violation blocks the merge.

## Structure

- `Sources/Core` — InnerTube client, OAuth token store, models (shared contracts)
- `Sources/Auth` — OAuth device-activation flow + `LoginView`
- `Sources/Feed` — TV `browse` (Home) parsing + grid `HomeView`
- `Sources/Player` — VISIONOS `player` stream resolve + `AVPlayerViewController`
- `reference/` — distilled InnerTube notes and captured sample responses

## Scope / limitations

Intentionally minimal: no search, subscriptions, shorts, or ad blocking.

Playback uses the HLS multivariant playlist from the VISIONOS InnerTube client, which needs only
a scraped `visitorData` token — no PO token and no JavaScript signature deciphering. AVFoundation
handles variant selection and ABR, settling at **1080p60 H.264**. That is the ceiling on real
hardware: YouTube publishes 1440p/2160p only in VP9 and AV1, and no shipping Apple TV can decode
either. The ANDROID client (muxed `itag 18`, 360p) remains as a fallback. Age- or login-restricted
videos surface a graceful message.
