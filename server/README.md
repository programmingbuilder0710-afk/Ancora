# Doer web + calendar Worker

Requires Node 22 and Flutter. All app data stays in browser SQLite/IndexedDB; the
Worker holds Pipedream and OpenRouter credentials. Built-in free planning uses
`POST /api/llm/chat/completions`; custom demo endpoints and your own AI key stay
direct from Flutter (the provider must allow CORS on web).

From `doer/`, run `flutter pub get`, `dart run sqflite_common_ffi_web:setup`, then
`flutter build web --release --base-href /app/`. The checked-in SQLite web assets also work without
rerunning setup. From `server/`, run `npm install`, copy `.dev.vars.example` to
`.dev.vars`, and fill in:

- `PIPEDREAM_CLIENT_ID` and `PIPEDREAM_CLIENT_SECRET`: create OAuth client credentials
  in your Pipedream workspace's API settings for your Connect project.
- `PIPEDREAM_PROJECT_ID`: the `proj_...` ID from the Pipedream Connect project.
- `PIPEDREAM_ENVIRONMENT`: `development` initially, `production` when enabled in
  Pipedream; set in `wrangler.jsonc` vars.
- `ALLOWED_ORIGINS`: comma-separated exact browser origins (no trailing slash),
  including the deployed app origin; set in `wrangler.jsonc` vars. These are also
  the Connect token's allowed origins. Native clients need no CORS origin; the
  first configured origin is their OAuth return destination.

Run `npm run build` to assemble `dist/` (landing at `/`, Flutter at `/app/`),
then `npx wrangler dev` and open `http://localhost:8787`. For Flutter hot reload,
use `flutter run -d chrome --web-port=8080 --dart-define=DOER_API_BASE=http://localhost:8787`
and add `http://localhost:8080` to `ALLOWED_ORIGINS`. On Android, pass
`--dart-define=DOER_API_BASE=https://your-worker.example` to enable connections;
plan writes still use the device calendar. Web defaults to the same-origin API.

Checks: `npx tsc --noEmit`, `npx vitest run`, `npx wrangler deploy --dry-run`.
Regenerate binding types after config changes with `npx wrangler types --include-runtime=false --strict-vars=false`.

When ready to deploy (not performed by this implementation), run each of:

```sh
npx wrangler secret put OPENROUTER_API_KEY
npx wrangler secret put PIPEDREAM_CLIENT_ID
npx wrangler secret put PIPEDREAM_CLIENT_SECRET
npx wrangler secret put PIPEDREAM_PROJECT_ID
npx wrangler deploy
```

Pipedream slugs are `google_calendar` and `microsoft_outlook_calendar`. Connect
uses `/v1/connect/{project}/tokens`, the per-user accounts endpoint, and the
URL-safe-base64 API proxy with `x-pd-proxy-` headers. `/api/ics` also requires the
UUID `user` query parameter, like every data route. No UUIDs, subscription URLs,
or upstream response bodies are logged. Treat the locally stored UUID as a
bearer secret; clearing browser storage loses access to that install's connections.
Pipedream's managed Google OAuth client grants `calendar.events` and `calendar.readonly` but
not calendar creation, so Google plans go to an existing writable "My Plan" calendar if the
user has one, otherwise to the primary calendar marked as free time (transparent, so Doer's
own sessions never come back as busy). Outlook gets a created "My Plan" calendar.
Route note: never add a `/api/event…` path while the app is served on `workers.dev` —
EasyPrivacy blocks that prefix for all workers.dev subdomains (uBlock default), which
silently kills the request. Plan writes use `/api/plan-writes`; a custom domain escapes
the whole class.

Development-mode Connect requires being signed into Pipedream in the browser
and supports at most ten external users. Real OAuth/provider tests require your
own configured project. Hostname filtering (including every redirect), 10-second
fetch timeout, and a 5 MB response cap protect ICS fetching; DNS rebinding is
outside this basic hostname guard. Provider paging caps at ten pages and reports
an error on overflow. ICS sources are grouped by host; removing a subscription
clears that host's blocks until the next sync. Partial sync replaces connected
blocks with reachable results; a complete network failure preserves the snapshot.

References: [static assets](https://developers.cloudflare.com/workers/static-assets/),
[Connect Link](https://pipedream.com/docs/connect/managed-auth/connect-link),
[API proxy](https://pipedream.com/docs/connect/api-proxy),
[environments](https://pipedream.com/docs/connect/managed-auth/environments).

## Free planning

Set `OPENROUTER_API_KEY` as a Worker secret, and **set an OpenRouter dashboard
spend limit**. `DEMO_MODEL` defaults to `qwen/qwen3.8-27b:free`; `DEMO_UPSTREAM`
defaults to `https://openrouter.ai/api/v1`. Never put the key in Flutter assets.
The proxy validates the per-install UUID v4 bearer token, forwards only messages,
response format and temperature, forces the model, caps output at 4,000 tokens,
limits input to 200 KB, and times out after 90 seconds. Missing/rejected keys
return 402; throttling returns 429; upstream failures return 502.
The two rate bindings allow 6/user and 20/IP requests per 60 seconds per Cloudflare
location, with eventual consistency. A daily cap would require KV/DO; these limits
are not a spend accounting system. Observability stays disabled.

`node e2e/run.mjs` from repo root runs the local browser verification after a web
build and `npm install` in `e2e/`. It starts/stops the mock and Wrangler, passing
`--env-file ../e2e/.dev.vars.e2e`; it never edits `server/.dev.vars` or uses real
Pipedream credentials. Screenshots are in `.context/shots/final/` and the fresh
agenda images are copied into `landing/images/`. Run `npm run build` again to
assemble the final site. OAuth returns to `/app/?connected=1` or `?connect_error=1`.

Rate binding reference: https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/
