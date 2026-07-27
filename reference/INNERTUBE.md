# InnerTube reference (distilled from SmartTube) — prototype cheatsheet

This is the minimal, verified subset needed for the tvOS prototype. All facts below were
confirmed with live requests on 2026-07-26. (Raw sample responses are intentionally not
committed — they contain session-correlated identifiers like `visitorData`/`feedbackToken`.)

## Base

- InnerTube endpoint base: `https://www.youtube.com/youtubei/v1/{endpoint}?key={API_KEY}&prettyPrint=false`
- API_KEY: the public InnerTube web key (embedded in every youtube.com page). Not stored in the
  repo — set `YT_INNERTUBE_API_KEY` in `YouTubeTV/Config/Secrets.xcconfig`.
- All InnerTube calls are `POST`, `Content-Type: application/json`, body = `{"context":{...}, ...endpoint params...}`.

## Clients

### TVHTML5 (used for the personalized HOME feed — REQUIRES the user's OAuth token)
- clientName: `TVHTML5`
- clientVersion: `7.20260707.07.00`
- `X-Youtube-Client-Name: 7`
- `X-Youtube-Client-Version: 7.20260707.07.00`
- Referer: `https://www.youtube.com/tv`
- User-Agent (Fire TV Cobalt):
  `Mozilla/5.0 (Linux armeabi-v7a; Android 7.1.2; Fire OS 6.0) Cobalt/22.lts.3.306369-gold (unlike Gecko) v8/8.8.278.8-jit gles Starboard/13, Amazon_ATV_mediatek8695_2019/NS6294 (Amazon, AFTMM, Wireless) com.amazon.firetv.youtube/22.3.r2.v66.0`

### ANDROID (used for PLAYBACK stream extraction — works UNauthenticated for public videos)
- clientName: `ANDROID`
- clientVersion: `21.26.364`
- `X-Youtube-Client-Name: 3`
- `X-Youtube-Client-Version: 21.26.364`
- User-Agent: `com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip`
- extra context client fields: `"androidSdkVersion":30,"osName":"Android","osVersion":"11"`
- endpoint host for player: `https://youtubei.googleapis.com/youtubei/v1/player?key=...`

## Context body shape

```json
{
  "context": { "client": {
      "clientName": "<NAME>", "clientVersion": "<VER>",
      "hl": "en", "gl": "US"
      /* ANDROID also: "androidSdkVersion":30,"osName":"Android","osVersion":"11" */
  }},
  /* endpoint params below, e.g.: */
  "browseId": "default"
}
```

## Auth — OAuth 2.0 device flow (YouTube-on-TV credentials)

Uses the well-known **public** YouTube-on-TV client credentials (the same ones SmartTube and
yt-dlp use). They are NOT stored in this repo — put them in `YouTubeTV/Config/Secrets.xcconfig`
(gitignored; see `YouTubeTV/Config/Secrets.example.xcconfig`). The values needed:
- client_id: `<YT_OAUTH_CLIENT_ID>` — a `*.apps.googleusercontent.com` id
- client_secret: `<YT_OAUTH_CLIENT_SECRET>` — the public TV client secret
- scope: `http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content`

1. **Get code** — `POST https://www.youtube.com/o/oauth2/device/code`
   Form (`application/x-www-form-urlencoded`): `client_id`, `scope`.
   Response JSON: `device_code`, `user_code`, `verification_url` (e.g. `https://www.youtube.com/activate`),
   `expires_in`, `interval` (seconds).
   Show the user: go to `verification_url` and enter `user_code`.

2. **Poll for token** — `POST https://www.youtube.com/o/oauth2/token`
   Form: `client_id`, `client_secret`, `code={device_code}`, `grant_type=http://oauth.net/grant_type/device/1.0`.
   Poll every `interval` seconds. While pending, HTTP 4xx with JSON `{"error":"authorization_pending"}`
   (or `"slow_down"` → increase interval). On success: `access_token`, `refresh_token`, `expires_in`, `token_type` (Bearer).

3. **Refresh** — `POST https://www.youtube.com/o/oauth2/token`
   Form: `client_id`, `client_secret`, `refresh_token`, `grant_type=refresh_token`.

Authenticated InnerTube calls add header: `Authorization: Bearer {access_token}`.

Each profile in the app is its own run of this flow, with its own `access_token`/`refresh_token`
pair. There is no InnerTube-side account switching involved: switching profiles just swaps which
Bearer token the feed requests carry.

## WHO AM I — `account/accounts_list` (TVHTML5 + Bearer token)

Verified 2026-07-27. Takes no parameters and describes whoever the token belongs to — the only
call that puts a name and a face on a set of credentials. A device-flow token is bound to a
single account, so the list is one entry, but read `isSelected` rather than assuming that.

```
contents[*].accountSectionListRenderer
  .contents[*].accountItemSectionRenderer
    .contents[*].accountItem
      .accountName        {"simpleText": "..."}   display name
      .channelHandle      {"simpleText": "@..."}
      .accountByline      {"simpleText": "..."}   the account's email
      .accountPhoto.thumbnails[*]                 avatar, up to 216x216
      .isSelected                                 which account the token is for
      .serviceEndpoint.selectActiveIdentityEndpoint.supportedTokens[*]
        .accountStateToken.obfuscatedGaiaId       Google's stable id for the account
```

`obfuscatedGaiaId` is what the app keys a profile on: it survives a rename of both the account
and its channel, so signing the same account back in lands on its existing watch history.

Note `account/account_menu` — the endpoint the *web* client uses for this — answers **HTTP 400**
on TVHTML5, with or without a token (it answers 401 unauthenticated, so the endpoint exists and
the client is what it rejects). Don't reach for it.

## HOME feed — `browse` with `"browseId":"default"` (TVHTML5 client + Bearer token)

Response path to video cells (the signed-in response nests shelves/tiles under this same path):

```
contents.tvBrowseRenderer
  .content.tvSurfaceContentRenderer
    .content.sectionListRenderer
      .contents[*]  (each is a shelfRenderer)
        .shelfRenderer.content.{ gridRenderer | horizontalListRenderer }.items[*]
          .tileRenderer      <-- the video cell
```

Each `shelfRenderer` is one horizontal row in the UI. Its heading is NOT at
`headerRenderer.shelfHeaderRenderer.title` on this client — the TV home feed nests it one level
deeper (verified 2026-07-26):

```
shelfRenderer.headerRenderer.shelfHeaderRenderer
  .avatarLockup.avatarLockupRenderer.title   (.runs[*].text — often split across several runs)
```

A signed-in home response returns ~3–4 shelves of 4–5 tiles each, with titles like
`Recommended`, `Recently uploaded`, and interest rows such as `Science and more`. The exact
shelves vary between loads. The same videoId can legitimately appear in two different shelves,
so dedupe per shelf, not globally.

### Paging home — continuations

The TV feed uses the OLDER continuation style, not `continuationItemRenderer` (verified
2026-07-26):

```
sectionListRenderer.continuations[0].nextContinuationData.continuation   <-- next PAGE of shelves
```

Fetch the next page with `browse` and `{"continuation": "<token>"}` (no `browseId`). The reply
wraps its shelves in `continuationContents.sectionListContinuation`, which carries the token for
the page after it; the last page simply omits `continuations`.

Careful: a response contains SEVERAL `nextContinuationData` objects — each shelf has its own for
scrolling further RIGHT within that row. Read `continuations` directly off the section-list
container; a recursive search for the renderer name returns a row token and pages the wrong axis.

Home exhausts after ~5 pages / ~16 shelves / ~78 videos for a typical account.

## Other feeds — same `browse` call, different `browseId`

Both verified working on TVHTML5 with the same Bearer token and the same shelf parsing
(2026-07-26):

- `FEsubscriptions` — ~7 shelves. Opens with `Most relevant` (~14 videos), then several
  **headerless** shelves of ~3 (their renderer has only `content`/`trackingParams`/
  `tvhtml5Metadata` — there is no title to find), plus a `Shorts` reel shelf. Paginates.
- `FEhistory` — a single untitled shelf of ~15 recently watched videos. No continuation.

Neither response names the feed it came from, so the caller has to supply that heading itself.

## SEARCH — `search` with `"query":"<text>"` (TVHTML5)

Verified 2026-07-26. Works with or without the Bearer token; the app sends it so results are
personalized. Same `sectionListRenderer` → `shelfRenderer` shape as the feeds: one
`Search results for <query>` shelf, then themed shelves (`Over 20 minutes`, and auto-generated
collections). No paging is implemented — the first response already carries ~30 videos.

**The hits are NOT `tileRenderer`s.** A typical response has ~2 tiles (both playlists) and
~43 `lockupViewModel`s, which is where every actual video lives. This is the newer view-model
shape and shares no field paths with the renderers:

- videoId: `contentId` (fallback `rendererContext.commandContext.onTap.innertubeCommand.watchEndpoint.videoId`)
- type filter: `contentType == "LOCKUP_CONTENT_TYPE_VIDEO"` (playlists/channels use the same
  cell, and their `contentId` is a playlist/channel id — handing one to `/player` 404s)
- title: `metadata.lockupMetadataViewModel.title.content` — a plain string, no `runs`/`simpleText`
- channel: `metadata.lockupMetadataViewModel.metadata.contentMetadataViewModel.metadataRows[0]
  .metadataParts[0].text.content` (later rows are view count and age)
- thumbnail(s): `contentImage.thumbnailViewModel.image.sources[*]` — `url`/`width`, like `thumbnails[*]`

Because both shapes turn up in one response, cell parsing collects every known shape in a
single ordered pass and dedupes, rather than treating one as a fallback for the other.

`tileRenderer` field paths (from SmartTube's TileItem.java):
- videoId: `onSelectCommand.watchEndpoint.videoId`  (fallback `onSelectCommand.reelWatchEndpoint.videoId`)
- title: `metadata.tileMetadataRenderer.title` (`.simpleText` or `.runs[*].text`)
- channel/subtitle: `metadata.tileMetadataRenderer.lines[*].lineRenderer.items[*].lineItemRenderer.text` (`.runs`/`.simpleText`)
- thumbnail(s): `header.tileHeaderRenderer.thumbnail.thumbnails[*].url` (pick the largest)
- contentType filter: `contentType == "TILE_CONTENT_TYPE_VIDEO"` (skip channels/playlists)

Parsing MUST be defensive: walk recursively and collect every `tileRenderer` that has a
`watchEndpoint.videoId`, rather than relying on the exact nesting (nesting varies by row type).
A robust approach: recursively find all `tileRenderer` objects anywhere in the tree.

## PLAYBACK — `player` (VISIONOS client, unauthenticated)

`POST https://www.youtube.com/youtubei/v1/player?key=...` body:
```json
{"context":{"client":{"clientName":"VISIONOS","clientVersion":"1.02","clientScreen":"WATCH",
 "userAgent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
 "deviceMake":"Apple","deviceModel":"RealityDevice17,1","osName":"visionOS","osVersion":"26.5.23O471",
 "hl":"en","gl":"US","visitorData":"<token>"}},
 "videoId":"<id>","contentCheckOk":true,"racyCheckOk":true}
```
Headers: `X-Youtube-Client-Name: 101`, `X-Youtube-Client-Version: 1.02`, `X-Goog-Visitor-Id: <token>`,
matching `User-Agent`, `Referer: https://www.youtube.com/tv`.

**`visitorData` is the only extra requirement** — VERIFIED 2026-07-26. Without it the response is
`LOGIN_REQUIRED` with no `streamingData`; with it alone the full ladder comes back. No PO token, no
`signatureTimestamp`, no `playbackContext`, no JS engine. Scrape it from the bootstrap JSON of
`https://www.youtube.com/tv?bpctr=9999999999&has_verified=1` (send the TV user agent and
`Cookie: SOCS=CAE=` to skip the consent interstitial), regex `"visitorData":"(.*?)"`, then cache it.
The `?key=` query param is optional; the host may be `www.youtube.com` or `youtubei.googleapis.com`.

Response:
- `playabilityStatus.status` must be `OK`. Treat `LOGIN_REQUIRED`/`ERROR` as *this client* being
  gated and fall through to the next client; only other non-OK values are real video-level errors.
- **`streamingData.hlsManifestUrl`** — a full HLS multivariant playlist, 144p → 2160p60. Hand it
  straight to `AVPlayer`. This is the whole strategy: AVFoundation does variant selection, ABR and
  audio for us, and silently ignores the VP9 variants it cannot decode.
- `streamingData.adaptiveFormats[*]` — 32 video/audio-only formats, all with a plain `url`,
  **no `signatureCipher` and no `n` throttle param**, and no byte-range restriction (any `Range`,
  or none, returns 200/206). Not used by the app; see the codec note below for why.

### Why not 4K
The HLS ladder and the adaptive formats both go to 2160p60, but above 1080p YouTube publishes only
VP9 (itags 308/315, WebM) and AV1 (itags 400/401, MP4). AVFoundation has no WebM demuxer at all, and
Apple ships no software AV1 decoder — AV1 hardware decode starts at A17 Pro/M3 while Apple TV 4K
(gens 1–3) is A10X/A12/A15. **itag 299 / `avc1.64002A` at 1080p60 is the highest resolution any
shipping Apple TV can decode.** VERIFIED: AVFoundation parses all 17 variants of a 4K video but
reports empty `codecTypes` for every `vp09` one and settles on 1920x1080 with zero dropped frames.
(The tvOS Simulator *can* decode 4K AV1 — it borrows the host Mac's decoder — so a green result
there is not evidence the feature works on device.)

### Fallback client — ANDROID (unauthenticated)
`POST https://youtubei.googleapis.com/youtubei/v1/player?key=...`, `clientName: ANDROID`,
`clientVersion: 21.26.364`. Returns muxed **itag 18** (360p MP4, H.264+AAC) with a direct `url`,
no cipher, no `n` param. Its `adaptiveFormats` are now **SABR-only** (every entry has
`serverAbrStreamingUrl` and no `url`), so 360p is all this client can give. Kept purely as a
last resort if the VISIONOS client is ever gated the same way.

Clients confirmed SABR-only or otherwise unusable as of 2026-07-26: `IOS` 21.26.4, `TVHTML5`
7.x, `ANDROID` 21.26.364. `TVHTML5` 5.20260707 and `TVHTML5_SIMPLY` do return plain URLs, but
those carry an `n` throttle param and **403 on every request** until it is solved by running
YouTube's `base.js` — which is exactly why SmartTube embeds a V8 engine. VISIONOS avoids this.

## NOTES / constraints
- Playback tops out at 1080p60 on real hardware — a codec-availability wall, not a code limit.
- Age-restricted / login-required videos may not play via the unauth clients; that's an accepted limitation.
- All endpoints (InnerTube, OAuth, and googlevideo.com stream hosts) are HTTPS, so the app
  uses the default App Transport Security policy — no ATS exceptions are configured.
