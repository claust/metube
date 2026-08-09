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

## Make targets

`Makefile` (in this directory, which is where every command below has to run from) wraps the
xcodebuild invocations the rest of this README spells out. `make` on its own lists them:

```sh
make run        # build, install and launch on the Apple TV simulator
make deploy     # the same on a paired Apple TV — device auto-detected
make testflight # archive and upload to TestFlight (see the TestFlight section)
make check      # SwiftLint + swift-format lint, exactly what CI gates on
make format     # reformat in place
make build      # compile for the simulator only (no signing, no device)
make test       # the UI tests
```

Both simulator and device are overridable — `make run TV_SIMULATOR="Apple TV B"`,
`make deploy TV_DEVICE=<name-or-udid>`. The long-hand equivalents follow below.

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
— the active one ringed and shown first — plus a plus button that runs the sign-in flow again for
another account. Pressing another account's avatar switches to it straight away; pressing the
active one offers *Sign out*.

Each profile keeps its own OAuth tokens (Keychain) and its own watch progress, so the feed,
history and resume positions are whatever that account sees. Signing a profile out deletes its
credentials and its watch progress from the device — but not the backup (see below), so signing
the same account back in restores it.

## Watch progress sync

Resume positions and which videos have been watched are backed up to a self-hosted
[Appwrite](https://appwrite.io) project, so reinstalling the app — or watching on a second
Apple TV — doesn't start from nothing. `Backend/` in this repository holds the project: its
database schema and the one function it needs. `Backend/README.md` covers deploying it.

**There is no extra login.** The YouTube sign-in above is the only one. A profile's id is
already `sha256` of YouTube's own account id, which is the same value on every device and after
every reinstall, so it doubles as an Appwrite user id; the `metube-auth` function checks the
app's YouTube token really belongs to the account it claims, and mints a session from that.

Syncing is local-first and entirely best-effort. UserDefaults stays the source of truth for
what the feed and player see, uploads are debounced (the player records a position every five
seconds — that is not a network round trip each) and queued across launches, and a backend that
can't be reached costs nothing but the sync. Where the same video has been watched on two
boxes, the later position wins.

**Syncing is off unless you ask for it.** `AP_HOST` and `AP_PROJECT_ID` in
`Config/Secrets.xcconfig` name your own Appwrite; left empty — which is what a fresh clone
gets — the app keeps progress on the device and uploads nothing. Neither value is a
credential, but both point at somebody's personal server, so committing them would mean
anyone who built this repo sent their viewing history there.

## History

The menu's **History** screen lists what has already been watched, most recent first, as a grid
of the same cards the feed draws — press one and it opens in the player, resuming where it was
left.

The list comes from **watch progress** — the same per-video position, duration and date the
player writes, that syncs to the backend and comes back on a fresh install or a second Apple TV.
That is the app's real record of what has been watched, which is also why every card here carries
the red progress line: the page is drawn from the thing that line comes from. Videos played here
too briefly to record a position (under ten seconds) are kept alongside it by `WatchHistoryStore`.

What watch progress does *not* carry is the videos themselves — it is ids and dates. So
`WatchHistoryStore` holds a card per video (title, channel, artwork, running time), filled in
from three places: the video the player just started, the account's history list, and
`VideoMetadataService` for whatever ids are left. That last one is `player` on the VISIONOS
client — the same call the player already makes, minus the streaming half — one request per
video, four at a time, and the answers are kept for good. A history restored from the backend
therefore costs a burst of lookups on the first visit and nothing on later ones.

Folded into the same list is YouTube's own `FEhistory` (~15 videos, no paging) — the only sight
the app gets of what was watched on a phone or a laptop, since nothing played here ever reaches
it (resolving a stream ourselves tells YouTube nothing about it). Those videos carry no
timestamps, only YouTube's ordering, so they are *placed* rather than dated: an undated video
sits directly below the most recent video the app does have a time for, keeping YouTube's
sequence. It never claims to be newer than something known to be newer, and one list stays one
list.

The cards are never uploaded, unlike the progress behind them: they are a local copy of what some
feed already said, pruned to what the page still draws, and signing the profile out deletes them.

## Refreshing the feed

The feed is checked for new videos in the background — when the app comes back to the
foreground, and when you return to Home from a video or from Search — but only if what's on
screen is more than 15 minutes old.

A newer feed is never swapped in on its own. It waits behind a **_n_ new videos** button in the
Home header, and only appears there if the fetch actually turned up videos that aren't already
on screen. This is deliberate: shelf ids are regenerated on every load, so applying a feed
rebuilds every row and resets scroll and focus. Doing that unprompted when someone comes back
from a video would take away the card they meant to play next — the one to the right of what
they just watched.

## Shorts

Shorts get a row of their own and a tile of their own, and appear nowhere else.

The tile is portrait (9:16, 240pt wide) with no title, no stats and no duration badge — a Short
has no running time to show, and the format is the point. The only thing over the artwork is the
channel's avatar, in the same bottom-right corner a video card puts it in, and the focus
treatment is a white edge around the tile rather than the grey caption panel a video card lights
up (a Short's artwork covers that panel completely).

Rows are split in `FeedService.parseSections`. A `reelShelfRenderer`, or any shelf holding
nothing but Shorts, becomes a Shorts row; every other row has its Shorts lifted out, because
YouTube mixes them into ordinary shelves — one turned up in Recommended. Lifted Shorts are
appended to that response's Shorts row, or collected into one at the end of the page if it has
none, so filtering them out never loses them. Row paging applies the same rule on every page
(`FeedSection.admitting`) — a continuation reply is a bare list of cells with nothing naming the
shelf it belongs to, so the row it lands in is what decides.

A cell is taken to be a Short if any of these hold, since no single field is on every cell shape:
a `reelWatchEndpoint` anywhere in it, a `contentType` naming Shorts, a
`thumbnailOverlayTimeStatusRenderer` with `style: "SHORTS"`, or portrait artwork. The Top Shelf
skips Shorts — it draws its tiles wide, with the title beside the artwork, which is neither the
shape nor the metadata a Short has.

A focused Shorts tile previews like any other card — a portrait video in a portrait box, so it
fills the tile exactly.

## Preview on the focused card

Focusing a card starts the video playing in place of its thumbnail, silently and at normal
speed, from the beginning. Moving focus away tears the player down and the thumbnail comes
back. It is only a preview, so nothing is recorded: no watch progress is written and no resume
position is read, and opening the video for real still starts where the user actually left off.

Playback starts as soon as the card takes focus — the stream has to be resolved first
(`StreamService`, the same ladder the player uses), so there is a beat before the first frame,
during which the thumbnail simply stays up and then cross-fades. Losing focus cancels a
resolution still in flight, so scrolling along a row doesn't leave requests running behind it.

The preview is an `AVPlayerLayer` rather than an `AVPlayerViewController`: no transport bar and
nothing focusable, both of which would fight the card it sits in. It also leaves `AVAudioSession`
alone — it is muted, so it must not interrupt whatever else is playing — and doesn't hold the
screen saver off, since a card left focused is someone who walked away.

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

## Skipping sponsors (SponsorBlock, prototype)

In-video interruptions — read-out sponsor spots, "smash that subscribe", intros, non-music
sections of a music video — are skipped automatically using
[SponsorBlock](https://sponsor.ajay.app), the crowd-sourced database behind the browser
extension of the same name. Its API is public, free and unauthenticated.

This is **not** ad blocking in the YouTube sense: pre-roll and mid-roll ads served by YouTube
never reach this app to begin with (the InnerTube clients used for playback hand back a plain
media stream). What SponsorBlock removes is the sponsor read *inside* the video the creator
uploaded, which no stream-level blocking can touch.

- Categories skipped by default: `sponsor`, `selfpromo`, `interaction`, `music_offtopic`.
  `intro`, `outro`, `preview` and `filler` are parsed but off — they are part of the video most
  people want. The set lives in `SponsorCategory.defaultSkipped`; there is no settings UI yet.
- The videoId is never sent. Only the **first four hex characters of its SHA-256** go to the
  server, which answers with every video sharing that prefix (~80 of them); the match happens on
  device. See `SponsorBlockService`.
- A skip shows a brief *Skipped sponsor · 42s* toast, so a chunk of video vanishing doesn't read
  as a stream glitch.
- Each segment is skipped **once per playback**: rewinding into one (a discount code, or simply
  wrong timestamps) works normally instead of bouncing the user forward again.
- Downvoted submissions (`votes < 0`) and segments under a second are ignored; overlapping ones
  are merged into a single seek. A SponsorBlock outage is silent — the video just plays whole.

Segment lookup runs *after* playback starts, so a slow third-party server can never delay the
first frame. Verified against the live API; the skip-and-seek behaviour itself has only been
exercised in the simulator, not on a real Apple TV.

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

The extension takes precedence over the static Top Shelf image in the asset catalog, which
stays as the fallback: it is what shows while nobody is signed in, or before the feed has
loaded once, because the provider answers `nil` rather than an empty shelf in those cases.

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

## TestFlight

`make deploy` is for the edit-build-look loop, not for keeping the app on the Apple TV: it
signs with a *development* provisioning profile, and when that profile expires tvOS stops
launching the app. A TestFlight build is signed for distribution, installs through the
TestFlight app on the Apple TV, lasts 90 days, and is replaced by uploading again.

```sh
make testflight           # archive → export → validate → upload
make testflight-validate  # same, minus the upload (checks signing + the automated checks)
make archive              # just produce build-archive/YouTubeTV.ipa
```

The build number is the git commit count, so it climbs on its own — App Store Connect refuses
a `CFBundleVersion` it has already seen. Override with `BUILD_NUMBER=<n>` when uploading from
a branch whose count has drifted below what is already up there. `MARKETING_VERSION` in
`project.yml` stays hand-owned.

TestFlight requires a **paid** Apple Developer Program membership, which also means
`YT_DEVICE_ENTITLEMENTS` should now be set — see below.

### One-time setup

1. **Create an App Store Connect API key.** *Users and Access → Integrations → App Store
   Connect API → Team Keys*, role **Admin**. Note the Key ID and the Issuer ID, and download
   the `AuthKey_<KEYID>.p8` — Apple serves it once.

   Admin, not App Manager: cloud signing has to mint an *Apple Distribution* certificate, and
   only Admin and Account Holder may create one. An App Manager key archives fine and then
   fails the export with `Cloud signing permission error` / `No profiles for '<bundle id>'
   were found`. A key's role cannot be changed after it is generated, so getting this wrong
   means making a new key.
2. **Put the key where the tools look:**
   ```sh
   mkdir -p ~/.private_keys && mv ~/Downloads/AuthKey_*.p8 ~/.private_keys/
   ```
3. **Name it in `.testflight.env`** (gitignored; copy `.testflight.env.example`):
   ```
   ASC_KEY_ID=XXXXXXXXXX
   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```
4. **Turn on the app group** in `Config/Secrets.xcconfig`, which a free account had to leave
   empty:
   ```
   YT_DEVICE_ENTITLEMENTS = Config/AppGroup.entitlements
   ```
   Without it the app and the Top Shelf extension get separate containers and testers see no
   tiles. The script warns if it is still unset.
5. **Create the app record** in App Store Connect: *Apps → + → New App*, platform tvOS, bundle
   ID `dk.delectosoft.metube`, any SKU. The record cannot be created from the command line and
   the upload fails without it. The bundle IDs themselves — app and Top Shelf extension — and
   the app group are registered automatically by `xcodebuild -allowProvisioningUpdates`.

   For this repo that record already exists, named **Fjernsyn** — the App Store name has to be
   unique across the store and "YouTube TV" is Google's.
6. **Add yourself as an internal tester** under *TestFlight → Internal Testing*, then install
   TestFlight on the Apple TV (App Store → search "TestFlight") and sign in with the same
   Apple ID. Internal builds skip Beta App Review and appear within minutes of processing.

   The existing group is called *Internal* and has automatic distribution on, so an uploaded
   build reaches the Apple TV without anyone clicking anything in App Store Connect.

Keep it to internal testing. This app reimplements YouTube's private InnerTube API against
Google's account; External (Beta App Review) or App Store distribution would very likely be
rejected.

### From CI

`.github/workflows/testflight.yml` does the same thing on a macOS runner, triggered manually
(*Actions → TestFlight release → Run workflow*, or `gh workflow run testflight.yml --ref
master`). It needs these repository secrets:

| Secret | Value |
| --- | --- |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | as in `.testflight.env` |
| `ASC_KEY_P8` | the `.p8` file, base64-encoded: `base64 -i ~/.private_keys/AuthKey_XXXX.p8 \| pbcopy` |
| `DEVELOPMENT_TEAM` | your team ID |
| `YT_INNERTUBE_API_KEY`, `YT_OAUTH_CLIENT_ID`, `YT_OAUTH_CLIENT_SECRET` | as in `Config/Secrets.xcconfig` — the runner has no gitignored file to read, so it writes its own |

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

## App icon

The mark is a rune monogram for *Fjernsyn*: **ᚠ** (U+16A0, fehu/fé, "f") beside **ᛋ** (U+16CB,
long-branch sól, "s"), in the red ochre that runestone carvings were painted with. Both are real
runes for their own sound, set from the actual Unicode codepoints in Apple Symbols — the one
runic-capable system font whose terminals are cut at an angle, which reads as chisel work.

The artwork is generated rather than checked in as an opaque bitmap, so the design lives in one
editable file:

```sh
Scripts/generate-app-icon.py
```

That rewrites `Sources/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets`. The
generated PNGs *are* committed, so a normal build needs neither the script nor the font. tvOS wants
the icon as a layered image stack, which the system separates in 3D when the icon is focused; here
the stone slab is the back layer, the chiselled groove the middle, and the red paint the front, so
focusing the icon lifts the paint off the stone.

Two things to know before reusing this elsewhere: it renders through a macOS system font, so the
outlines are Apple's; and of the three S runes in the Runic block, only U+16CB is usable here —
U+16CA points the wrong way and U+16CC is barely more than a tick.

## Structure

- `Sources/Core` — InnerTube client, profile/token store, models, video-cell parsing (shared contracts)
- `Sources/Auth` — OAuth device-activation flow, account lookup + `LoginView`
- `Sources/Feed` — TV `browse` (Home) parsing + grid `HomeView`
- `Sources/Search` — TV `search` + `SearchView` (reached from the icon in the Home header)
- `Sources/History` — the menu's `HistoryView`, its card store, and the by-id video lookup
- `Sources/UI` — the video card and layout metrics both screens share
- `Sources/Player` — VISIONOS `player` stream resolve + `AVPlayerViewController` + SponsorBlock skipping
- `TopShelf/` — the Top Shelf extension; shares only `Sources/Core/TopShelf.swift` with the app
- `reference/` — distilled InnerTube notes and captured sample responses

## Scope / limitations

Intentionally minimal: no subscriptions management beyond the card menu, and no ad blocking
beyond the in-video SponsorBlock segments described above.
Shorts are shown and play in the ordinary player — there is no vertical swipe-through reel.

Search is one page of results with no filters and no paging past it — enough to find and
play something, not a replacement for YouTube's search UI.

Playback uses the HLS multivariant playlist from the VISIONOS InnerTube client, which needs only
a scraped `visitorData` token — no PO token and no JavaScript signature deciphering. AVFoundation
handles variant selection and ABR, settling at **1080p60 H.264**. That is the ceiling on real
hardware: YouTube publishes 1440p/2160p only in VP9 and AV1, and no shipping Apple TV can decode
either. The ANDROID client (muxed `itag 18`, 360p) remains as a fallback. Age- or login-restricted
videos surface a graceful message.
