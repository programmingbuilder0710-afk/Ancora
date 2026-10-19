import { afterEach, expect, it, vi } from 'vitest';
import worker, { type ServerEnv } from '../src/index';
const user = '70c54e12-532f-4aad-a79a-df1c725824a1';
function env() { return { ALLOWED_ORIGINS: '', OPENROUTER_API_KEY: 'test', DEMO_MODEL: 'forced', DEMO_UPSTREAM: 'https://mock.example/v1',
  DEMO_USER_LIMIT: { limit: vi.fn().mockResolvedValue({ success: true }) },
  DEMO_IP_LIMIT: { limit: vi.fn().mockResolvedValue({ success: true }) } } as unknown as ServerEnv; }
function request(body: unknown = { messages: [] }, auth = `Bearer ${user}`) {
  return new Request('https://doer.example/api/llm/chat/completions', { method: 'POST',
    headers: { Authorization: auth, 'CF-Connecting-IP': '192.0.2.1' }, body: JSON.stringify(body) });
}
afterEach(() => vi.unstubAllGlobals());
it('rejects malformed and non-v4 authorization', async () => {
  for (const auth of ['', 'Bearer bad', `Bearer ${user.replace('-4aad-', '-1aad-')}`])
    expect((await worker.fetch(request({}, auth), env())).status).toBe(401);
});
it('maps missing keys and rejected upstream credentials to 402', async () => {
  expect((await worker.fetch(request(), { ...env(), OPENROUTER_API_KEY: '' })).status).toBe(402);
  for (const status of [401, 402, 403]) {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(null, { status })));
    const response = await worker.fetch(request(), env());
    expect(response.status).toBe(402);
    expect(await response.json()).toEqual({ error: "Free planning isn't available right now" });
  }
});
it('reduces the body, forces model, caps tokens and passes 200 through', async () => {
  const fetch = vi.fn().mockResolvedValue(new Response('{"choices":[]}')); vi.stubGlobal('fetch', fetch);
  const allowed = { messages: [{ role: 'user', content: 'goal' }], response_format: { type: 'json_object' }, temperature: 0.2 };
  const response = await worker.fetch(request({ ...allowed, model: 'expensive', max_tokens: 9000, stream: true, tools: [] }), env());
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ ...allowed, model: 'forced', max_tokens: 4000 });
  expect(await response.text()).toBe('{"choices":[]}');
});
it('checks limits and rejects oversized and malformed input', async () => {
  const bindings = env(); vi.mocked(bindings.DEMO_USER_LIMIT.limit).mockResolvedValue({ success: false });
  expect((await worker.fetch(request(), bindings)).status).toBe(429);
  expect(bindings.DEMO_IP_LIMIT.limit).toHaveBeenCalledWith({ key: '192.0.2.1' });
  expect((await worker.fetch(request({ messages: ['x'.repeat(205000)] }), env())).status).toBe(413);
  expect((await worker.fetch(request([]), env())).status).toBe(400);
});
it('maps throttling, upstream failures and timeouts', async () => {
  for (const [upstream, expected] of [[429,429],[500,502],[503,502]]) {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(null, { status: upstream })));
    expect((await worker.fetch(request(), env())).status).toBe(expected);
  }
  vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('timeout')));
  expect((await worker.fetch(request(), env())).status).toBe(502);
});
