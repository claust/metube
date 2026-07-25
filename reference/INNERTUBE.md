# InnerTube reference (distilled from SmartTube) — prototype cheatsheet

This is the minimal, verified subset needed for the tvOS prototype. All facts below were
confirmed with live requests on 2026-07-26 (see `reference/samples/*.json`).

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

## HOME feed — `browse` with `"browseId":"default"` (TVHTML5 client + Bearer token)

Response path to video cells (see `reference/samples/browse_home.json` for the unauth shape —
signed-in adds the shelves/tiles):

```
contents.tvBrowseRenderer
  .content.tvSurfaceContentRenderer
    .content.sectionListRenderer
      .contents[*]  (each is a shelfRenderer)
        .shelfRenderer.content.{ gridRenderer | horizontalListRenderer }.items[*]
          .tileRenderer      <-- the video cell
```

`tileRenderer` field paths (from SmartTube's TileItem.java):
- videoId: `onSelectCommand.watchEndpoint.videoId`  (fallback `onSelectCommand.reelWatchEndpoint.videoId`)
- title: `metadata.tileMetadataRenderer.title` (`.simpleText` or `.runs[*].text`)
- channel/subtitle: `metadata.tileMetadataRenderer.lines[*].lineRenderer.items[*].lineItemRenderer.text` (`.runs`/`.simpleText`)
- thumbnail(s): `header.tileHeaderRenderer.thumbnail.thumbnails[*].url` (pick the largest)
- contentType filter: `contentType == "TILE_CONTENT_TYPE_VIDEO"` (skip channels/playlists)

Parsing MUST be defensive: walk recursively and collect every `tileRenderer` that has a
`watchEndpoint.videoId`, rather than relying on the exact nesting (nesting varies by row type).
A robust approach: recursively find all `tileRenderer` objects anywhere in the tree.

## PLAYBACK — `player` (ANDROID client, unauthenticated)

`POST https://youtubei.googleapis.com/youtubei/v1/player?key=...` body:
```json
{"context":{"client":{"clientName":"ANDROID","clientVersion":"21.26.364","androidSdkVersion":30,"osName":"Android","osVersion":"11","hl":"en","gl":"US"}},
 "videoId":"<id>","contentCheckOk":true,"racyCheckOk":true}
```
Response (see `reference/samples/player_android.json`):
- `playabilityStatus.status` must be `OK` (else `LOGIN_REQUIRED`/`UNPLAYABLE` → show error, cannot play).
- `streamingData.formats[*]` — progressive (muxed audio+video) formats.
  **itag 18** = 360p MP4 (H.264 + AAC) and comes with a **direct `url`** field, **no `signatureCipher`,
  no `n` throttle param** → play it directly in AVPlayer. VERIFIED unthrottled.
- Strategy: from `streamingData.formats`, pick the format with `itag == 18` (or any format that has a
  plain `url` and a muxed mime `video/mp4`), and hand `url` straight to AVPlayer.
- Do NOT attempt signatureCipher/DASH — prototype uses the muxed itag-18 URL only. If itag 18 is
  absent or status != OK, surface a friendly "can't play this video" message.

## NOTES / constraints
- itag 18 caps at 360p — acceptable for the prototype.
- Age-restricted / login-required videos may not play via the unauth ANDROID client; that's an accepted limitation.
- `NSAllowsArbitraryLoads` is already enabled in Info.plist (googlevideo.com stream hosts).
