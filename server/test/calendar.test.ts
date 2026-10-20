import { afterEach, describe, expect, it, vi } from 'vitest';
import worker, { icsUrl, type ServerEnv } from '../src/index';
import { googleBusy, outlookBusy, readBusy, writeEvents, type Proxy } from '../src/calendars';
const user = '70c54e12-532f-4aad-a79a-df1c725824a1';
const start = '2026-10-16T10:00:00Z', end = '2026-10-16T11:00:00Z';
const env = { PIPEDREAM_CLIENT_ID: 'test', PIPEDREAM_CLIENT_SECRET: 'fake', PIPEDREAM_PROJECT_ID: 'proj_test',
  PIPEDREAM_ENVIRONMENT: 'development', ALLOWED_ORIGINS: 'http://localhost:8787', ASSETS: {} } as ServerEnv;
const request = (path: string, body: unknown) => new Request(`http://localhost:8787/api/${path}`, { method: 'POST',
  headers: { 'Content-Type': 'application/json', Origin: 'http://localhost:8787' }, body: JSON.stringify(body) });
afterEach(() => vi.unstubAllGlobals());

describe('normalization', () => {
  it('normalizes Google offsets and ignores invalid intervals', () => {
    expect(googleBusy({ calendars: { a: { busy: [{ start: '2026-10-16T12:00:00+02:00', end }, { start: end, end: start }] } } }, 'google'))
      .toEqual([{ source: 'google', start: '2026-10-16T10:00:00.000Z', end: '2026-10-16T11:00:00.000Z' }]);
  });
  it('normalizes Outlook UTC responses including all-day events, excluding free/cancelled', () => {
    const event = { start: { dateTime: '2026-10-16T00:00:00.0000000' }, end: { dateTime: '2026-10-17T00:00:00' }, isAllDay: true };
    expect(outlookBusy({ value: [event, { ...event, showAs: 'free' }, { ...event, isCancelled: true }] }, 'outlook'))
      .toEqual([{ source: 'outlook', start: '2026-10-16T00:00:00.000Z', end: '2026-10-17T00:00:00.000Z' }]);
  });
});
it('creates a scoped Connect link using OAuth and the configured environment', async () => {
  const fetch = vi.fn().mockResolvedValueOnce(Response.json({ access_token: 'test-access', expires_in: 3600 }))
    .mockResolvedValueOnce(Response.json({ connect_link_url: 'https://pipedream.com/_static/connect.html?token=test&connectLink=true' }));
  vi.stubGlobal('fetch', fetch);
  const response = await worker.fetch(request('connect-token', { user, app: 'google_calendar' }), env);
  expect(response.status).toBe(200);
  expect((await response.json() as any).url).toContain('&app=google_calendar');
  expect(fetch.mock.calls[0][0]).toBe('https://api.pipedream.com/v1/oauth/token');
  const init = fetch.mock.calls[1][1];
  expect(init.headers['x-pd-environment']).toBe('development');
  expect(JSON.parse(init.body)).toEqual({ external_user_id: user, allowed_origins: ['http://localhost:8787'],
    success_redirect_uri: 'http://localhost:8787/app/?connected=1', error_redirect_uri: 'http://localhost:8787/app/?connect_error=1' });
  expect(response.headers.get('Access-Control-Allow-Origin')).toBe('http://localhost:8787');
});
it('rejects invalid identities/apps and disallowed origins before upstream requests', async () => {
  const fetch = vi.fn(); vi.stubGlobal('fetch', fetch);
  expect((await worker.fetch(request('connect-token', { user: 'bad', app: 'google_calendar' }), env)).status).toBe(400);
  expect((await worker.fetch(request('connect-token', { user, app: 'slack' }), env)).status).toBe(400);
  const req = request('connect-token', { user, app: 'google_calendar' }); req.headers.set('Origin', 'https://evil.example');
  expect((await worker.fetch(req, env)).status).toBe(403); expect(fetch).not.toHaveBeenCalled();
});
it('checks ownership before deleting an account', async () => {
  const fetch = vi.fn().mockResolvedValue(Response.json([])); vi.stubGlobal('fetch', fetch);
  const response = await worker.fetch(new Request(`http://localhost:8787/api/accounts/another?user=${user}`, { method: 'DELETE' }), env);
  expect(response.status).toBe(404);
  expect(fetch.mock.calls.every(c => c[1].method !== 'DELETE')).toBe(true);
});
it('excludes My Plan and pages Outlook busy events with UTC headers', async () => {
  const proxy = vi.fn().mockResolvedValueOnce({ value: [{ id: 'own', name: 'My Plan' }, { id: 'busy', name: 'Work' }] })
    .mockResolvedValueOnce({ value: [{ start: { dateTime: start }, end: { dateTime: end } }], '@odata.nextLink': 'https://graph.microsoft.com/v1.0/next' })
    .mockResolvedValueOnce({ value: [] });
  expect(await readBusy(proxy, { id: 'acct', app: 'microsoft_outlook_calendar', name: 'Me' }, start, end)).toHaveLength(1);
  expect(proxy.mock.calls[1][0]).toContain('/busy/calendarView');
  expect(proxy.mock.calls[1][3]).toEqual({ Prefer: 'outlook.timezone="UTC"' });
  expect(proxy).toHaveBeenCalledTimes(3);
});
it('writes My Plan events best effort and ignores missing deletes', async () => {
  const proxy = vi.fn().mockResolvedValueOnce({ items: [] }).mockResolvedValueOnce({ id: 'plan' })
    .mockRejectedValueOnce({ status: 410 }).mockRejectedValueOnce({ status: 403 })
    .mockResolvedValueOnce({ id: 'created' }).mockRejectedValueOnce({ status: 503 });
  const result = await writeEvents(proxy as Proxy, { id: 'a', app: 'google_calendar', name: 'Me' }, ['gone', 'failed'],
    [{ key: 'ok', title: 'Task', start, end }, { key: 'bad', title: 'Task', start, end }]);
  expect(result.created).toEqual({ ok: 'created' }); expect(result.errors).toHaveLength(2);
  expect(proxy.mock.calls[4][2].description).toBe('Planned by Doer');
});
it('rejects private ICS hosts, redirects and non-calendar responses', async () => {
  for (const host of ['localhost', '127.0.0.1', '10.0.0.1', '192.168.0.1', '172.16.0.1', '169.254.1.1', '[::1]', 'calendar.local', '2130706433']) {
    expect(() => icsUrl(`https://${host}/calendar`)).toThrow();
  }
  expect(icsUrl('webcal://calendar.example/one').protocol).toBe('https:');
  const fetch = vi.fn().mockResolvedValueOnce(new Response(null, { status: 302, headers: { location: 'https://127.0.0.1/private' } }))
    .mockResolvedValueOnce(new Response('not a calendar'));
  vi.stubGlobal('fetch', fetch);
  const req = () => new Request(`http://localhost:8787/api/ics?user=${user}&url=https://calendar.example/one`);
  expect((await worker.fetch(req(), env)).status).toBe(400);
  expect((await worker.fetch(req(), env)).status).toBe(422);
});
it('returns successful busy accounts when another account fails and forwards proxy headers', async () => {
  const fetch = vi.fn(async (input: string, init: RequestInit) => {
    if (input.endsWith('/oauth/token')) return Response.json({ access_token: 'busy-token', expires_in: 3600 });
    if (input.includes('/users/')) return Response.json([
      { id: 'good', name: 'Work', app: { name_slug: 'google_calendar' } },
      { id: 'bad', name: 'Other', app: { name_slug: 'microsoft_outlook_calendar' } },
      { id: 'unsupported', app: { name_slug: 'slack' } },
    ]);
    const url = new URL(input);
    if (url.searchParams.get('account_id') === 'bad') return new Response(null, { status: 403 });
    const encoded = url.pathname.split('/').pop()!.replace(/-/g, '+').replace(/_/g, '/');
    const upstream = atob(encoded);
    expect(url.searchParams.get('external_user_id')).toBe(user);
    expect((init.headers as Record<string, string>)['x-pd-proxy-Content-Type']).toBe('application/json');
    if (upstream.includes('/calendarList')) return Response.json({ items: [{ id: 'plan', summary: 'My Plan' }, { id: 'work', summary: 'Work' }] });
    expect(JSON.parse(init.body as string).items).toEqual([{ id: 'work' }]);
    return Response.json({ calendars: { work: { busy: [{ start, end }] } } });
  });
  vi.stubGlobal('fetch', fetch);
  const response = await worker.fetch(request('busy', { user, start, end }), { ...env, PIPEDREAM_CLIENT_ID: 'busy-test' });
  const data = await response.json() as any;
  expect(response.status).toBe(200);
  expect(data.blocks).toHaveLength(1);
  expect(data.blocks[0].source).toBe('pd:google_calendar:Work');
  expect(data.errors).toEqual([{ account: 'bad', message: 'Could not sync Other' }]);
});
it('caps streamed ICS responses at 5 MB', async () => {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(new Uint8Array(5 * 1024 * 1024 + 1))));
  const response = await worker.fetch(new Request(`http://localhost:8787/api/ics?user=${user}&url=https://calendar.example/large`), env);
  expect(response.status).toBe(413);
});
