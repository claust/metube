# MeTube backend

The Appwrite project behind the app's watch-progress sync — one row per (profile, video), so
reinstalling the app doesn't lose resume positions or which videos have been watched.

Runs on the self-hosted Appwrite at `https://sabeltiger.dk/v1` (see `home-server/CLAUDE.md`),
in its own project `metube`, separate from `photos`.

## Why there is no login screen

The app has no Appwrite credentials to offer and an Apple TV remote is a miserable thing to
type a password on. So it doesn't: the YouTube sign-in the app already performs *is* the login.

`Profile.id(for:)` in the app derives a profile id as `sha256(accountKey)` truncated to 16 hex,
where `accountKey` is YouTube's obfuscated Gaia id. That id is stable across reinstalls — the
same YouTube account always produces it. The `metube-auth` function turns it into an Appwrite
identity:

1. The app posts `{accessToken, accountKey}`.
2. The function calls YouTube's `account/accounts_list` with the token. This is the same call
   the app's `AccountService` makes, and it answers "who is this token?".
3. If `accountKey` is among the identities the response gives back, the claim is proven.
4. `userId = "yt" + sha256(accountKey)[0..16]` — the same hash the app computed. The user is
   created if this is its first sign-in anywhere.
5. `users.createToken` mints a custom token; the app exchanges it at
   `POST /v1/account/sessions/token` for a session.

The function is executable by `any` because the caller has no session yet — that is what it is
asking for. The guard is the YouTube token, not an Appwrite role.

## Layout

```
appwrite.config.json            project, function, database and table definitions
functions/metube-auth/          node-22 + TypeScript
```

## Data model

Database `metube`, table `watchProgress`, **row security on**.

| Column | Type | |
|---|---|---|
| `userId` | string(24) | `yt<profileID>` |
| `videoId` | string(24) | |
| `position` | double | seconds |
| `duration` | double | seconds |
| `watchedAt` | datetime | drives the app's incremental pull |

Row id is `<profileID>_<videoId>`, which makes every write an idempotent upsert with no
read-before-write. Rows are created by the app with `read/update/delete` for `user:<userId>`
only, so one profile cannot see another's history.

## Deploying

Needs Appwrite CLI **25 or newer**. Older CLIs can't reach the console-scoped APIs on a 1.9.6
server (`Admin mode is not allowed for console project`), which is what creating the project
and the platform below needs.

The CLI reads `appwrite.config.json` from the working directory, so every command runs from
this directory — otherwise it picks up whichever project the surrounding checkout points at.

```bash
appwrite push all --all
```

Then set the function's one secret (the same public InnerTube key as
`YouTubeTV/Config/Secrets.xcconfig`; it is not in the config file because it is gitignored on
the app side and this repo is public):

```bash
appwrite functions create-variable --function-id metube-auth --variable-id yt-innertube-api-key --key YT_INNERTUBE_API_KEY --value '<key>'
```

`push` creates the function but does **not** apply `execute` or `scopes` from the config file.
Without them the function is unreachable and its per-execution key has no permissions, so set
them once by hand — a later `push` leaves them alone:

```bash
appwrite functions update --function-id metube-auth --name "MeTube auth" --execute any --scopes users.read users.write
```

### Optional: restrict who can sign up

The function will mint an account for anyone holding a valid YouTube token. On a home server
that is usually fine. To limit it, set a comma-separated list of accepted account keys (Gaia
ids or handles):

```bash
appwrite functions create-variable --function-id metube-auth --key ALLOWED_ACCOUNT_KEYS --value '<gaia-id>,<gaia-id>'
```

### Creating it from scratch

```bash
appwrite init project --organization-id <org> --project-id metube --project-name MeTube
appwrite project create-apple-platform --platform-id metube-tvos \
  --name "MeTube (tvOS)" --bundle-identifier dk.delectosoft.metube
```

The platform is not optional: without it Appwrite rejects the app's
`Origin: appwrite-tvos://dk.delectosoft.metube` and every client call fails. The organization
id is the `teamId` of any existing project (`appwrite project get`).

## Things that cost an afternoon

Four of these bite in a row, and none of them announce themselves:

- **The function's return value is the response.** Calling `res.json(...)` without `return`ing
  it yields HTTP 500 and `Return statement missing`, even though the handler ran fine.
- **The API key arrives as a header, not an env var.** `req.headers['x-appwrite-key']` is the
  per-execution key minted from `scopes`; there is nothing in `process.env` to fall back on,
  and using an empty key fails as `role: guests missing scopes`.
- **Sessions come back as a cookie.** `POST /account/sessions/token` returns 201 with an empty
  `secret` field whatever the platform — the session is in `Set-Cookie: a_session_metube=…`,
  and that is what the client has to replay. (Sending no session means acting as a guest,
  which surfaces confusingly as `Permissions must be one of: (any, guests)` on the first row
  write, not as a 401 on the read.)
- **Required columns need an explicit `"default": null`** in `appwrite.config.json`, or the
  CLI refuses to push the config at all.

## Developing the function

```bash
cd functions/metube-auth
bun install
bun run build     # tsc → dist/main.js, which is the deployed entrypoint
bun run lint      # oxlint + eslint
```

## Checking it by hand

```bash
appwrite functions create-execution --function-id metube-auth \
  --body '{"accessToken":"<a live YouTube token>","accountKey":"<its gaia id>"}'
```

A good token returns `{userId, secret, expire}`; a bad one, or a mismatched `accountKey`,
returns 401.
