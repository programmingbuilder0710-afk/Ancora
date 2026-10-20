import { demoCompletion } from './llm';
import { apps, readBusy, writeEvents, type Account, type Json, type Proxy } from './calendars';

type Secrets = { OPENROUTER_API_KEY?: string; PIPEDREAM_CLIENT_ID: string; PIPEDREAM_CLIENT_SECRET: string; PIPEDREAM_PROJECT_ID: string };
export type ServerEnv = Env & Secrets;
class ApiError extends Error { constructor(public status: number, message: string) { super(message); } }
let token: { client: string; value: string; expires: number } | undefined;
const json = (data: unknown, status = 200) => Response.json(data, { status });
const origins = (env: ServerEnv) => env.ALLOWED_ORIGINS.split(',').map(s => s.trim()).filter(Boolean);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const utc = (s: unknown): s is string => typeof s === 'string' && /^\d{4}-\d\d-\d\dT.*Z$/.test(s) && Number.isFinite(Date.parse(s));

async function accessToken(env: ServerEnv): Promise<string> {
  if (!env.PIPEDREAM_CLIENT_ID || !env.PIPEDREAM_CLIENT_SECRET || !env.PIPEDREAM_PROJECT_ID) throw new ApiError(503, 'Calendar connections are not configured on this server');
  if (token?.client === env.PIPEDREAM_CLIENT_ID && token.expires > Date.now()) return token.value;
  const response = await fetch('https://api.pipedream.com/v1/oauth/token', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(15000),
    body: JSON.stringify({ grant_type: 'client_credentials', client_id: env.PIPEDREAM_CLIENT_ID, client_secret: env.PIPEDREAM_CLIENT_SECRET }),
  });
  if (!response.ok) throw new ApiError(502, 'Calendar service authentication failed');
  const data = await response.json() as Json;
  if (!data.access_token) throw new ApiError(502, 'Calendar service authentication failed');
  token = { client: env.PIPEDREAM_CLIENT_ID, value: data.access_token, expires: Date.now() + (Number(data.expires_in ?? 3600) - 60) * 1000 };
  return token.value;
}
async function pd(env: ServerEnv, path: string, method = 'GET', body?: Json, headers = {}): Promise<any> {
  const response = await fetch(`https://api.pipedream.com/v1/connect/${encodeURIComponent(env.PIPEDREAM_PROJECT_ID)}/${path}`, {
    method, headers: { Authorization: `Bearer ${await accessToken(env)}`, 'x-pd-environment': env.PIPEDREAM_ENVIRONMENT || 'development', 'Content-Type': 'application/json', ...headers },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(20000),
  });
  if (!response.ok) throw new ApiError(response.status, `Calendar request failed (${response.status})`);
  return response.status === 204 ? {} : response.json();
}
async function accounts(env: ServerEnv, user: string): Promise<Account[]> {
  const data = await pd(env, `users/${encodeURIComponent(user)}/accounts?include_credentials=false`);
  return (Array.isArray(data) ? data : data.data ?? []).filter((a: any) => apps.includes(a.app?.name_slug))
    .map((a: any) => ({ id: a.id, app: a.app.name_slug, name: a.name ?? a.email ?? a.app.name }));
}
function proxy(env: ServerEnv, user: string, account: string): Proxy {
  return (url, method = 'GET', body, headers = {}) => {
    const encoded = btoa(Array.from(new TextEncoder().encode(url), b => String.fromCharCode(b)).join('')).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    const query = new URLSearchParams({ external_user_id: user, account_id: account });
    return pd(env, `proxy/${encoded}?${query}`, method, body, {
      'x-pd-proxy-Content-Type': 'application/json',
      ...Object.fromEntries(Object.entries(headers).map(([k, v]) => [`x-pd-proxy-${k}`, v])),
    });
  };
}

export function icsUrl(raw: string): URL {
  let url: URL;
  try { url = new URL(raw.replace(/^webcal:/i, 'https:')); } catch { throw new ApiError(400, 'Invalid calendar URL'); }
  const host = url.hostname.toLowerCase().replace(/\.$/, '');
  // ponytail: hostname SSRF guard only; DNS rebinding needs an outbound allowlist/proxy if exposed at larger scale.
  if (url.protocol !== 'https:' || url.username || url.password || !host.includes('.') ||
    host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host.includes(':') ||
    /^(0|10|127)\./.test(host) || /^(192\.168|169\.254|172\.(1[6-9]|2\d|3[01]))\./.test(host) ||
    /^(22[4-9]|23\d|24\d|25[0-5])\./.test(host)) throw new ApiError(400, 'Calendar URL must use a public HTTPS host');
  return url;
}
async function fetchIcs(raw: string): Promise<Response> {
  let url = icsUrl(raw);
  const signal = AbortSignal.timeout(10000);
  for (let redirects = 0; redirects <= 5; redirects++) {
    const response = await fetch(url, { redirect: 'manual', signal });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      await response.body?.cancel();
      const location = response.headers.get('location');
      if (!location) throw new ApiError(502, 'Invalid calendar redirect');
      url = icsUrl(new URL(location, url).href); continue;
    }
    if (!response.ok || !response.body) throw new ApiError(502, 'Calendar subscription could not be fetched');
    const reader = response.body.getReader(), chunks: Uint8Array[] = []; let size = 0;
    try {
      while (true) {
        const { done, value } = await reader.read(); if (done) break;
        size += value.length;
        if (size > 5 * 1024 * 1024) throw new ApiError(413, 'Calendar exceeds 5 MB');
        chunks.push(value);
      }
    } finally { await reader.cancel(); }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const text = new TextDecoder().decode(bytes);
    if (!text.includes('BEGIN:VCALENDAR')) throw new ApiError(422, 'URL did not return an ICS calendar');
    return new Response(text, { headers: { 'Content-Type': 'text/calendar; charset=utf-8' } });
  }
  throw new ApiError(502, 'Too many calendar redirects');
}
async function route(request: Request, env: ServerEnv): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === '/api/llm/chat/completions' && request.method === 'POST') return demoCompletion(request, env);
  let body: Json = {};
  if (request.method === 'POST') {
    try { body = await request.json(); if (!body || Array.isArray(body) || typeof body !== 'object') throw new Error(); }
    catch { throw new ApiError(400, 'Expected a JSON object'); }
  }
  const user = body.user ?? url.searchParams.get('user');
  if (typeof user !== 'string' || !uuid.test(user)) throw new ApiError(400, 'Invalid user');
  if (request.method === 'GET' && url.pathname === '/api/ics') return fetchIcs(url.searchParams.get('url') ?? '');
  if (request.method === 'POST' && url.pathname === '/api/connect-token') {
    if (!apps.includes(body.app)) throw new ApiError(400, 'Unsupported calendar app');
    const origin = request.headers.get('Origin') ?? origins(env)[0];
    const data = await pd(env, 'tokens', 'POST', { external_user_id: user, allowed_origins: origins(env),
      ...(origin ? { success_redirect_uri: `${origin}/app/?connected=1`, error_redirect_uri: `${origin}/app/?connect_error=1` } : {}),
    });
    const link = new URL(data.connect_link_url); link.searchParams.set('app', body.app);
    return json({ url: link.href });
  }
  if (request.method === 'GET' && url.pathname === '/api/accounts') return json(await accounts(env, user));
  if (request.method === 'DELETE' && /^\/api\/accounts\/[^/]+$/.test(url.pathname)) {
    const id = decodeURIComponent(url.pathname.split('/').pop()!);
    if (!(await accounts(env, user)).some(a => a.id === id)) throw new ApiError(404, 'Account not found');
    await pd(env, `accounts/${encodeURIComponent(id)}`, 'DELETE'); return json({});
  }
  if (request.method === 'POST' && url.pathname === '/api/busy') {
    if (!utc(body.start) || !utc(body.end) || Date.parse(body.end) <= Date.parse(body.start)) throw new ApiError(400, 'Invalid UTC range');
    const blocks = [], errors = [];
    for (const account of await accounts(env, user)) {
      try { blocks.push(...await readBusy(proxy(env, user, account.id), account, body.start, body.end)); }
      catch { errors.push({ account: account.id, message: `Could not sync ${account.name}` }); }
    }
    return json({ blocks, errors });
  }
  if (request.method === 'POST' && url.pathname === '/api/events') {
    if (typeof body.account_id !== 'string' || !Array.isArray(body.delete) || !body.delete.every((id: unknown) => typeof id === 'string' && id.length > 0) ||
      !Array.isArray(body.create) || !body.create.every((e: any) => e && typeof e.key === 'string' && typeof e.title === 'string' && utc(e.start) && utc(e.end) && Date.parse(e.end) > Date.parse(e.start))) throw new ApiError(400, 'Invalid events');
    const account = (await accounts(env, user)).find(a => a.id === body.account_id);
    if (!account) throw new ApiError(404, 'Account not found');
    return json(await writeEvents(proxy(env, user, account.id), account, body.delete, body.create));
  }
  throw new ApiError(404, 'Route not found');
}
export default {
  async fetch(request: Request, env: ServerEnv): Promise<Response> {
    const url = new URL(request.url);
    if (!url.pathname.startsWith('/api/')) return env.ASSETS.fetch(request);
    const origin = request.headers.get('Origin');
    const allowed = origin && origins(env).includes(origin);
    let response: Response;
    try {
      if (origin && origin !== url.origin && !allowed) throw new ApiError(403, 'Origin not allowed');
      response = request.method === 'OPTIONS' ? new Response(null, { status: 204 }) : await route(request, env);
    } catch (e) {
      response = json({ error: e instanceof ApiError ? e.message : 'Calendar service unavailable' }, e instanceof ApiError ? e.status : 502);
    }
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('Vary', 'Origin');
    if (allowed) {
      response.headers.set('Access-Control-Allow-Origin', origin);
      response.headers.set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
      response.headers.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    }
    return response;
  },
};
