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
   but kept in a gitignored file so nothing credential-shaped lands in this (public) repo.

   Because it is gitignored, a fresh clone or a new git worktree starts without it, and a device
   build then fails to sign (`DEVELOPMENT_TEAM` is empty). Keeping one copy outside any checkout
   and symlinking to it saves redoing this each time:
   ```sh
   mkdir -p ~/.config/metube && chmod 600 ~/.config/metube/Secrets.xcconfig   # once, after filling it in
   ln -sfn ~/.config/metube/Secrets.xcconfig Config/Secrets.xcconfig          # in each clone/worktree
   ```
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

## Profiles

Several YouTube accounts can be signed in at once. The Home header shows one avatar per account
— the active one ringed — plus a plus button that runs the sign-in flow again for another
account. Pressing an avatar offers *Use this profile* and *Sign out*.

Each profile keeps its own OAuth tokens (Keychain) and its own watch progress, so the feed,
history and resume positions are whatever that account sees. Signing a profile out deletes its
watch progress along with its credentials.

## Card menu — channels and subscriptions (prototype)

Holding **Select** on a card in Home or Search opens a menu for the video's channel:

- **Go to channel** — pushes a channel screen: avatar, name, a Subscribe/Unsubscribe button, and
  the channel's own shelves. Only the first page of shelves loads; rows still page sideways.
- **Subscribe** / **Unsubscribe** — labelled by where the account currently stands with that
  channel, and applied straight away, with the local state rolled back if YouTube refuses.

Subscriptions are cached per profile (UserDefaults) so the first menu is labelled without a
round-trip, and refreshed from `FEchannels` each time the feed loads. A card whose cell didn't
link a channel — some Shorts and History rows — says so instead of offering the two actions.

The InnerTube calls behind this (`subscription/subscribe`, `subscription/unsubscribe`,
`FEchannels`, channel `browse`) are implemented from SmartTube's request shapes and have **not**
been verified against a live account yet.

## Top Shelf

When the app's icon is focused on the tvOS home screen's top row, the strip above it shows the
first two videos of the signed-in account's feed. Selecting one opens the app straight into the
player for that video.

The tiles come from a snapshot, not a live fetch. `HomeView` writes the first two videos into
the `group.dk.delectosoft.metube` app group each time the Home feed loads, and the extension in
`TopShelf/` only decodes it — it has no OAuth token of its own, tvOS gives it a short window to
answer in, and it can be asked for content before the app has run at all. So the tiles show the
feed as of the last time the app was open, and the app calls
`TVTopShelfContentProvider.topShelfContentDidChange()` after each load to push the new pair out.
Signing the last profile out clears the snapshot rather than leaving one account's
recommendations on a shared TV's home screen.

A tile's action is a `metube://video?id=…` URL, built and parsed in one place
(`TopShelfLink`) since it is the one thing the two processes must agree on exactly.
`RootView.onOpenURL` turns it back into a `VideoItem` — titled from the same snapshot the tile
was drawn from — and presents the player.

Both targets sign against the same `Config/AppGroup.entitlements` — they need the identical
group, or each would see its own empty store. Which builds get it is split by SDK, because App
Groups is a **paid** Apple Developer Program capability:

- **Simulator** always gets it. Nothing is provisioned there, so the Top Shelf works
  unconditionally and this is where to exercise the feature.
- **Device** only gets it when `YT_DEVICE_ENTITLEMENTS` names the file in
  `Config/Secrets.xcconfig`. Left empty (the default, and what a free account needs) the app
  still builds, installs and runs on an Apple TV — `TopShelfStore` no-ops without the group —
  it just shows no tiles. Set it once your team is in the paid program:

  ```
  YT_DEVICE_ENTITLEMENTS = Config/AppGroup.entitlements
  ```

Either way a device build needs Xcode to register the extension's own App ID
(`dk.delectosoft.metube.topshelf`) — an embedded extension is signed as its own bundle, so it
gets its own profile. `xcodebuild -allowProvisioningUpdates` can only do that if Xcode's Apple
account has a working developer-portal session; if it doesn't, it reports the rather misleading
`No Accounts: Add a new account in Accounts settings` even though the account is signed in.

Two things to know when testing on the simulator:

- Build **without** `CODE_SIGNING_ALLOWED=NO`. That flag (which CI passes, since CI only
  compiles) strips the entitlements, and the app then can't open the group container.
- The first install of the extension registers it with HeadBoard but doesn't start its
  controller — focusing the icon logs `extension controller … has not been started` and shows
  nothing. Reboot the simulator (`xcrun simctl shutdown booted && xcrun simctl boot <udid>`)
  once and the tiles appear. That the extension answered is visible in the log:

  ```sh
  xcrun simctl spawn booted log show --last 2m --predicate 'eventMessage CONTAINS "delectosoft.metube"' --style compact | grep loadTopShelf
  ```

The deep link can be exercised on its own, without touching the home screen:

```sh
xcrun simctl openurl booted "metube://video?id=<videoId>"
```

(tvOS shows an "Open in …?" confirmation for a URL opened this way; a real tile press doesn't.)

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

- `Sources/Core` — InnerTube client, profile/token store, models, video-cell parsing (shared contracts)
- `Sources/Auth` — OAuth device-activation flow, account lookup + `LoginView`
- `Sources/Feed` — TV `browse` (Home) parsing + grid `HomeView`
- `Sources/Search` — TV `search` + `SearchView` (reached from the icon in the Home header)
- `Sources/UI` — the video card and layout metrics both screens share
- `Sources/Player` — VISIONOS `player` stream resolve + `AVPlayerViewController`
- `TopShelf/` — the Top Shelf extension; shares only `Sources/Core/TopShelf.swift` with the app
- `reference/` — distilled InnerTube notes and captured sample responses

## Scope / limitations

Intentionally minimal: no subscriptions management, shorts, or ad blocking.

Search is one page of results with no filters and no paging past it — enough to find and
play something, not a replacement for YouTube's search UI.

Playback uses the HLS multivariant playlist from the VISIONOS InnerTube client, which needs only
a scraped `visitorData` token — no PO token and no JavaScript signature deciphering. AVFoundation
handles variant selection and ABR, settling at **1080p60 H.264**. That is the ceiling on real
hardware: YouTube publishes 1440p/2160p only in VP9 and AV1, and no shipping Apple TV can decode
either. The ANDROID client (muxed `itag 18`, 360p) remains as a fallback. Age- or login-restricted
videos surface a graceful message.
