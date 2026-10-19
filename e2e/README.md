Install dependencies: `(cd server && npm install) && (cd e2e && npm install)`.
Build Flutter: `cd doer && ~/development/flutter/bin/flutter build web --release --base-href /app/`.
From the repo root run `node e2e/run.mjs` (set `CHROME_PATH` if Chrome is elsewhere).
The runner assembles assets, starts local Wrangler and the mock, uses a fresh browser profile, and stops both servers.
Screenshots and failure details go to `.context/shots/final/`; E2E credentials live only in `e2e/.dev.vars.e2e`.
