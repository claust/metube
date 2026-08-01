import { createHash } from 'node:crypto'
import { Client, Users } from 'node-appwrite'

/// Turns a YouTube OAuth access token into an Appwrite session for the MeTube tvOS app.
///
/// The app has no Appwrite credentials to offer and no keyboard worth typing them on, so the
/// YouTube login it already performs is the only login there is. This function is the bridge:
/// it proves the caller holds a working token for the account they claim, then mints a custom
/// token that the app exchanges for a session.
///
/// Because the caller has no session yet, this function must be executable by `any`. The guard
/// is the YouTube token — an unverifiable claim gets nothing.

/// TVHTML5, copied from the app's `AppConfig.Client.tv`. `accounts_list` answers HTTP 400 for
/// other client identities, so these values are not decorative.
const YT_CLIENT = {
  name: 'TVHTML5',
  version: '7.20260707.07.00',
  nameID: '7',
  userAgent:
    'Mozilla/5.0 (Linux armeabi-v7a; Android 7.1.2; Fire OS 6.0) Cobalt/22.lts.3.306369-gold (unlike Gecko) v8/8.8.278.8-jit gles Starboard/13, Amazon_ATV_mediatek8695_2019/NS6294 (Amazon, AFTMM, Wireless) com.amazon.firetv.youtube/22.3.r2.v66.0',
  referer: 'https://www.youtube.com/tv',
}

interface Context {
  req: {
    bodyRaw: string
    headers: Record<string, string>
    method: string
  }
  res: {
    /// The runtime takes the handler's *return value* as the response — calling this without
    /// returning it produces "Return statement missing" and an HTTP 500.
    json: (body: object, statusCode?: number) => unknown
  }
  log: (message: string) => void
  error: (message: string) => void
}

type Json = Record<string, unknown>

/// Every dictionary under `object` that carries a key named `key` — the app's
/// `findAllRenderers`, which is how anything is found in an InnerTube response.
function findAllRenderers(key: string, object: unknown): Json[] {
  const results: Json[] = []
  const walk = (value: unknown): void => {
    if (Array.isArray(value)) {
      for (const entry of value) walk(entry)
      return
    }
    if (typeof value !== 'object' || value === null) return
    for (const [k, v] of Object.entries(value)) {
      if (k === key && typeof v === 'object' && v !== null && !Array.isArray(v)) {
        results.push(v as Json)
      }
      walk(v)
    }
  }
  walk(object)
  return results
}

/// An InnerTube text object, which is `{simpleText}` or `{runs:[{text}]}` depending on the
/// field and the client's mood.
function innerTubeText(value: unknown): string | undefined {
  if (typeof value !== 'object' || value === null) return undefined
  const dict = value as Json
  if (typeof dict.simpleText === 'string') return dict.simpleText
  if (Array.isArray(dict.runs)) {
    const text = dict.runs
      .map((run) => (typeof run === 'object' && run !== null ? (run as Json).text : undefined))
      .filter((t): t is string => typeof t === 'string')
      .join('')
    return text === '' ? undefined : text
  }
  return undefined
}

/// Everything `accounts_list` says this account could be identified by, in the same order the
/// app's `AccountService.parse` considers them. The app picks one of these as the profile's
/// `accountKey`; this function only has to recognise the pick, so ordering doesn't matter here
/// — but keeping the list identical is what makes the two agree.
function identityCandidates(item: Json): string[] {
  const gaia = findAllRenderers('accountStateToken', item)
    .map((token) => token.obfuscatedGaiaId)
    .find((id): id is string => typeof id === 'string' && id !== '')

  return [
    gaia,
    innerTubeText(item.channelHandle),
    innerTubeText(item.accountByline),
    innerTubeText(item.accountName),
  ].filter((candidate): candidate is string => typeof candidate === 'string' && candidate !== '')
}

interface Account {
  candidates: string[]
  name: string
}

/// Asks YouTube who a token belongs to. A direct port of the app's `AccountService.loadAccount`
/// — `accounts_list` takes no parameters and describes whoever the Bearer token is.
async function loadAccount(accessToken: string, apiKey: string): Promise<Account | undefined> {
  const response = await fetch(
    `https://www.youtube.com/youtubei/v1/account/accounts_list?key=${apiKey}&prettyPrint=false`,
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`,
        'X-Youtube-Client-Name': YT_CLIENT.nameID,
        'X-Youtube-Client-Version': YT_CLIENT.version,
        'User-Agent': YT_CLIENT.userAgent,
        Referer: YT_CLIENT.referer,
      },
      body: JSON.stringify({
        context: {
          client: {
            clientName: YT_CLIENT.name,
            clientVersion: YT_CLIENT.version,
            hl: 'en',
            gl: 'US',
          },
        },
      }),
    },
  )

  if (!response.ok) return undefined

  const json: unknown = await response.json()
  const items = findAllRenderers('accountItem', json)
  // A device-flow token is bound to one account so this is normally a single entry, but it is
  // a list: `isSelected` names the right one.
  const item = items.find((entry) => entry.isSelected === true) ?? items[0]
  if (item === undefined) return undefined

  const candidates = identityCandidates(item)
  if (candidates.length === 0) return undefined

  return { candidates, name: innerTubeText(item.accountName) ?? candidates[0] }
}

/// The Appwrite user id for a YouTube account. The hash half is exactly what the app's
/// `Profile.id(for:)` computes, so a reinstalled app lands on the user it left behind.
function userIdFor(accountKey: string): string {
  return `yt${createHash('sha256').update(accountKey, 'utf8').digest('hex').slice(0, 16)}`
}

export default async function main(context: Context): Promise<unknown> {
  const { req, res, log, error } = context

  let payload: Json
  try {
    payload = JSON.parse(req.bodyRaw) as Json
  } catch {
    return res.json({ message: 'Body is not JSON' }, 400)
  }

  const accessToken = payload.accessToken
  const accountKey = payload.accountKey
  if (typeof accessToken !== 'string' || accessToken === '') {
    return res.json({ message: 'accessToken is required' }, 400)
  }
  if (typeof accountKey !== 'string' || accountKey === '') {
    return res.json({ message: 'accountKey is required' }, 400)
  }

  const apiKey = process.env.YT_INNERTUBE_API_KEY
  if (apiKey === undefined || apiKey === '') {
    error('YT_INNERTUBE_API_KEY is not set')
    return res.json({ message: 'Function is not configured' }, 500)
  }

  let account: Account | undefined
  try {
    account = await loadAccount(accessToken, apiKey)
  } catch (cause) {
    error(`accounts_list failed: ${String(cause)}`)
    return res.json({ message: 'Could not reach YouTube' }, 502)
  }

  if (account === undefined) {
    return res.json({ message: 'YouTube did not accept those credentials' }, 401)
  }

  // The app decides which candidate is the profile's identity; we only confirm the claim is
  // backed by the token. Re-deriving it here instead would put a second parser in a second
  // language on the critical path of "is this the same user as last time?".
  if (!account.candidates.includes(accountKey)) {
    log(`Claimed ${accountKey}, token identifies ${account.candidates.join(', ')}`)
    return res.json({ message: 'That token belongs to a different account' }, 401)
  }

  const allowed = process.env.ALLOWED_ACCOUNT_KEYS
  if (allowed !== undefined && allowed !== '') {
    const allowList = allowed.split(',').map((entry) => entry.trim())
    if (!account.candidates.some((candidate) => allowList.includes(candidate))) {
      log(`${accountKey} is not on the allow list`)
      return res.json({ message: 'That account is not allowed here' }, 403)
    }
  }

  // The key for this execution arrives as a *header*, minted from the function's `scopes` —
  // there is no long-lived key in the environment to fall back on. Without it the SDK acts as
  // a guest and `users.create` fails with "missing scopes".
  const client = new Client()
    .setEndpoint(process.env.APPWRITE_FUNCTION_API_ENDPOINT ?? '')
    .setProject(process.env.APPWRITE_FUNCTION_PROJECT_ID ?? '')
    .setKey(req.headers['x-appwrite-key'] ?? '')
  const users = new Users(client)

  const userId = userIdFor(accountKey)
  try {
    await users.get({ userId })
  } catch {
    // Either the user doesn't exist yet (first sign-in from any device) or the lookup failed
    // for another reason — in which case `create` fails too and the catch below reports it.
    try {
      await users.create({ userId, name: account.name })
      log(`Created user ${userId}`)
    } catch (cause) {
      // Two devices signing in at once both find no user and both create it; the loser is
      // told so, and that is a success — the user it wanted exists.
      if (!String(cause).includes('already exists')) {
        error(`Could not create ${userId}: ${String(cause)}`)
        return res.json({ message: 'Could not create the account' }, 500)
      }
    }
  }

  try {
    const token = await users.createToken({ userId })
    return res.json({ userId, secret: token.secret, expire: token.expire })
  } catch (cause) {
    error(`Could not mint a token for ${userId}: ${String(cause)}`)
    return res.json({ message: 'Could not create a session' }, 500)
  }
}
