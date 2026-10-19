import type { ServerEnv } from './index';
const unavailable = "Free planning isn't available right now";
const error = (status: number, message: string) => Response.json({ error: message }, { status });
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function demoCompletion(request: Request, env: ServerEnv): Promise<Response> {
  const user = request.headers.get('Authorization')?.match(/^Bearer (.+)$/)?.[1];
  if (!user || !uuid.test(user)) return error(401, 'Invalid authorization');
  if (!env.OPENROUTER_API_KEY) return error(402, unavailable);
  // ponytail: a daily per-user cap needs KV/DO; the real spend cap is the OpenRouter dashboard limit.
  const limits = await Promise.all([
    env.DEMO_USER_LIMIT.limit({ key: user.toLowerCase() }),
    env.DEMO_IP_LIMIT.limit({ key: request.headers.get('CF-Connecting-IP') ?? 'unknown' }),
  ]);
  if (limits.some(limit => !limit.success)) return error(429, 'Please try again in a minute');
  const cap = 200 * 1024;
  if (Number(request.headers.get('Content-Length')) > cap) return error(413, 'Request too large');
  const reader = request.body?.getReader();
  if (!reader) return error(400, 'Expected a JSON object');
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > cap) return error(413, 'Request too large');
      chunks.push(value);
    }
  } finally { await reader.cancel(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  let body;
  try {
    body = JSON.parse(new TextDecoder().decode(bytes));
    if (!body || Array.isArray(body) || typeof body !== 'object' || !Array.isArray(body.messages)) throw new Error();
  } catch { return error(400, 'Expected messages in a JSON object'); }
  try {
    const response = await fetch(`${(env.DEMO_UPSTREAM || 'https://openrouter.ai/api/v1').replace(/\/$/, '')}/chat/completions`, {
      method: 'POST', signal: AbortSignal.timeout(90000),
      headers: { Authorization: `Bearer ${env.OPENROUTER_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages: body.messages, response_format: body.response_format,
        temperature: body.temperature, model: env.DEMO_MODEL || 'qwen/qwen3.8-27b:free',
        max_tokens: typeof body.max_tokens === 'number' && Number.isFinite(body.max_tokens)
          ? Math.max(1, Math.min(4000, Math.floor(body.max_tokens))) : 4000 }),
    });
    if (response.status === 200) return new Response(response.body, { headers: { 'Content-Type': 'application/json' } });
    await response.body?.cancel();
    if ([401, 402, 403].includes(response.status)) return error(402, unavailable);
    if (response.status === 429) return error(429, 'Please try again in a minute');
    return error(502, unavailable);
  } catch { return error(502, unavailable); }
}
