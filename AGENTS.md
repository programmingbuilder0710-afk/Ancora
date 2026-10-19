<arg_value># Repository Guidelines

## Project Overview

**Doer** (`doer/`, packaged as `com.doer.doer`) is an Android and web Flutter app that decomposes user goals into calendar-scheduled tasks via an OpenAI-compatible LLM (demo default: OpenRouter), places those tasks deterministically on-device, and writes them to the device calendar (Android) or a connected calendar (web). A Cloudflare Worker serves the web build and holds Pipedream Connect credentials for Google/Outlook connections and ICS subscriptions. Browser data stays in SQLite/IndexedDB. The LLM performs **semantics only** (task decomposition, `recommended_day`); all datetime math and placement is deterministic Dart.

Two authoritative docs exist at repo root:
- `SPEC.md` — product/architecture spec (invariants, SQLite DDL, LLM schemas, slotter algorithm, degradation matrix)
- `FRONTEND_CONTRACT.md` — generated companion documenting every implemented public API with exact signatures; **regenerate/update when `doer/lib/` changes**

**Current state:** `main.dart` loads `AppServices` and opens the Agenda / Goals / Settings shell. The UI supports goal editing and documents, decomposition, local task actions, re-planning and results, provider setup, schedule preferences, and busy-calendar imports. Calendar initialization is optional; failures keep the local app usable.

## Architecture & Data Flow

```
Goal (SQLite)
  │
  ▼
Orchestrator.decompose(goals)
  │  reads busy blocks + existing tasks + documents
  │  builds per-day summary + goal context
  ▼
LlmProvider.complete()  ← OpenAiCompatibleProvider / DemoProvider
  │  strict JSON-schema response, 429 retried 3× (20/40/80s)
  ▼
Orchestrator._validateAndConvertTasks()
  │  drops malformed rows, fresh UUID per task, remaps prereqs
  │  batch-inserts into SQLite
  ▼
Slotter.placeTasks()  ← deterministic Dart, no LLM
  │  work window + busy blocks + buffer → free segments
  │  Kahn topo sort → within-level: goal priority → recommended_day → createdAt
  │  full-duration search, then compression (15-min floor)
  ▼
CalendarService.atomicRewrite() → device_calendar plugin
  │  best-effort delete+create in "My Plan" calendar
```

Key invariants:
- **LLM does semantics only** — never placement math
- **Monotonic completion** — `status == completed` tasks are never re-edited
- **7-day horizon** — `Orchestrator.horizonDays = 7`; busy-block query `[today, today+7d)`
- **LLM semantics stay separate from scheduling** — built-in demo calls use the Worker `/api/llm/chat/completions` proxy; custom demo and BYOK calls remain direct. The Worker holds OpenRouter/Pipedream secrets and proxies calendars/ICS; no server database.

## Key Directories

| Path | Purpose |
|---|---|
| `doer/lib/models/` | `Goal`, `Task`, `BusyBlock`, `UserPreferences` — pure data classes with `toMap`/`fromMap` |
| `doer/lib/data/` | `DatabaseHelper` — SQLite via sqflite, `PRAGMA foreign_keys = ON`, singleton (file) or `forTest()` (in-memory) |
| `doer/lib/provider/` | `LlmProvider` interface, `OpenAiCompatibleProvider`, `DemoProvider`, `ProviderConfigService` (demo/BYOK modes; keys in `flutter_secure_storage`, never SQLite) |
| `doer/lib/extraction/` | `ExtractionService` — `.txt`/`.md`/`.pdf`/`.docx` text extraction (5000-char cap) + `.ics` parsing (366-occurrence cap) |
| `doer/lib/slotter/` | `Slotter`, `PlacementResult`, `FreeSegment` — synchronous deterministic placement; public `allGoals`/`allTasks` registries must be hydrated by the caller |
| `doer/lib/orchestration/` | `Orchestrator` — decompose/replan/skipTask/completeTask/importIcsFile; the only LLM callers |
| `doer/lib/calendar/` | `PlanCalendar` interface, `ConnectedCalendars`/`PipedreamPlanCalendar` for Worker-backed sync; `CalendarService` — device_calendar writes to "My Plan"; timezone resolved at construction from `UserPreferences.timezone` |
| `doer/lib/main.dart`, `doer/lib/app_services.dart` | Composition root, tab shell, hydrated orchestrators, calendar fallback, provider error messages |
| `doer/lib/ui/agenda/` | Seven-day agenda, completion/skip actions, needs attention, re-plan entry point |
| `doer/lib/ui/goals/` | Active goals and create/edit form, documents, decomposition, archive/delete |
| `doer/lib/ui/settings/` | Schedule preferences, busy-calendar imports, and routed `ProviderSettingsScreen` |
| `doer/lib/ui/replan/`, `doer/lib/ui/dialogs.dart` | Re-plan diff/tips and shared confirmation/progress dialogs |
| `server/` | Cloudflare Worker: static assets, Pipedream Connect calendar API, ICS fetch, Vitest tests |
| `doer/web/` | Flutter web shell and SQLite WASM/shared worker assets |
| `doer/test/` | hermetic + live test suites (see Testing below) |

## Development Commands

All commands run from `doer/`.

```bash
# Run the app
flutter run
flutter run -d chrome
flutter build web --release --base-href /app/

# Worker (after building web)
(cd ../server && npm install && npm run build && npx wrangler dev)
(cd ../server && npx tsc --noEmit && npx vitest run)
(cd ../server && npx wrangler deploy --dry-run)
# Deployment, only when explicitly requested; configure secrets per server/README.md
(cd ../server && npx wrangler deploy)

# Static analysis (flutter_lints 6 defaults; excludes build/** and android/**)
flutter analyze

# Run all tests
flutter test

# Run a focused suite
flutter test test/orchestrator_test.dart
flutter test test/slotter_test.dart
flutter test test/calendar_timezone_test.dart

# Hermetic suites only (no network)
flutter test test/regression_test.dart test/file_input_test.dart test/provider_config_test.dart test/rrule_test.dart test/ui_test.dart

# Live tests (real OpenRouter endpoint, 4–10 min, require network)
flutter test test/demo_live_test.dart
flutter test test/live_logic_test.dart

# Add a dependency
flutter pub add <package>
```

## Code Conventions & Common Patterns

**Formatting/naming:** standard Dart/Flutter. `flutter_lints` 6 defaults apply; no custom rules. Classes are PascalCase, private members `_camelCase`.

**Async/error handling:**
- All DB, provider, calendar, and orchestrator methods are `Future`-based; `Slotter` placement and ICS parsing are synchronous
- Typed provider errors: `AuthError`, `RateLimitError`, `QuotaError`, `NetworkError`, `SchemaViolationError`, `ProviderError` — all extend `LlmProviderException`
- `Orchestrator.decompose`/`replan` retry `SchemaViolationError` **once** with the validation error appended; a second parse failure propagates
- Semantic task-row violations are silently dropped/normalized; if no valid task remains: `Exception('LLM returned no valid tasks')`
- Calendar failures in `atomicRewrite`/`skipTask` are swallowed; `writeTaskEvent`/`deleteEvent` throw plain `Exception`

**Dependency injection:** constructor injection everywhere.
```dart
final orchestrator = Orchestrator(
  db: helper,
  providerFactory: () => provider!,  // sync, non-null
  slotter: slotter,
  calendar: calendar,  // optional
);
```
`providerFactory` is **synchronous** (`LlmProvider Function()`); `ProviderConfigService.buildActiveProvider()` is `Future<LlmProvider?>` and must be awaited at the composition root, then wrapped in a cached non-null closure.

**State management:** none. No streams, no `ChangeNotifier`. UI is expected to reload SQLite-backed lists after each successful mutation.

**Test seams:**
- `DatabaseHelper.forTest()` — fresh `:memory:` DB per instance
- `ProviderConfigService.readKey`/`writeKey` — override via subclass (see `demo_live_test.dart:86-91`)
- `Orchestrator.providerFactory: () => throw StateError('unreachable')` — valid for local-only operations (`skipTask`, `completeTask`, `importIcsFile` never call the factory)

**Calendar timezone:** `CalendarService(planCalendarId, preferences: prefs)` resolves `UserPreferences.timezone` into a stored `tz.Location` at construction, calls `tz.setLocalLocation`, exposes `resolvedTimezone`/`timeZone`/`timezoneWarning`, and falls back to UTC with a surfaced warning on `LocationNotFoundException`. Writes use the stored `_location`.

## Important Files

| File | Role |
|---|---|
| `SPEC.md` | Authoritative product/architecture spec. Read before designing features. |
| `FRONTEND_CONTRACT.md` | Authoritative implemented-API contract. Update when `doer/lib/` changes. |
| `doer/lib/orchestration/orchestrator.dart` | All LLM-calling entry points; task validation; placement flow |
| `doer/lib/slotter/slotter.dart` | Deterministic placement; `FreeSegment`, `PlacementResult` |
| `doer/lib/provider/provider.dart` | `LlmProvider`, `OpenAiCompatibleProvider`, `DemoProvider`, error taxonomy |
| `doer/lib/provider/provider_config_service.dart` | Demo/BYOK config; embedded demo defaults (`qwen/qwen3.8-27b:free`) |
| `doer/lib/data/database_helper.dart` | SQLite schema, CRUD, FK enforcement, cascade delete |
| `doer/lib/calendar/calendar_service.dart` | Device-calendar writes; "My Plan" find-or-create; timezone resolution |
| `doer/lib/models/models.dart` | All data shapes; `UserPreferences.timezone` is IANA (e.g. `'America/Los_Angeles'`) |
| `doer/lib/ui/settings/provider_settings_screen.dart` | Provider configuration screen; Settings loads initial values before routing |
| `doer/pubspec.yaml` | Dependencies, SDK constraints |
| `doer/analysis_options.yaml` | Lint config (flutter_lints 6, excludes build/android) |

**Stale backups — do not read or copy:** `SPEC.md~`, `doer/lib/provider/provider_config_service.dart~` contain different (older) defaults.

## Runtime/Tooling Preferences

- **Runtime:** Flutter ≥3.44.0, Dart SDK ^3.13.4 (`pubspec.lock`)
- **Platform:** Android + Flutter Web (SQLite WASM/IndexedDB). Android: `com.doer.doer`, Java 17, Kotlin 2.4.0 (`doer/android/app/build.gradle.kts`), Gradle 9.3.1 (`doer/android/gradle/wrapper/gradle-wrapper.properties`), AGP 9.1.0 (`doer/android/settings.gradle.kts`)
- **Android permissions:** main manifest (`doer/android/app/src/main/AndroidManifest.xml`) declares `READ_CALENDAR` + `WRITE_CALENDAR` (required by `device_calendar`); normal Flutter debug/profile manifests add `INTERNET` for dev tooling
- **Build output:** redirected to repo-root `build/` via `doer/android/build.gradle.kts`
- **Release signing:** uses debug keys (no release signing configured — explicit TODO)
- **Tooling:** use `flutter`/`dart` CLI from `doer/`; Worker npm scripts and Wrangler run from `server/`.
- **`doer/README.md`** is stock Flutter boilerplate — ignore it; this document is the authoritative guide

## Testing & QA

**Frameworks:** `flutter_test` + `sqflite_common_ffi` for host-side SQLite.

**Run commands:** see Development Commands above.

**Hermetic suites** (no network, fast):
- `test/orchestrator_test.dart` — decompose validation, persistence, monotonic replan
- `test/regression_test.dart` — FK enforcement, cycle handling, provider error mapping, ICS import
- `test/file_input_test.dart` — `.ics` edge cases, extraction, storage integrity, slotter boundaries, 100-task stress
- `test/calendar_timezone_test.dart` — constructor timezone resolution, UTC fallback, warning surfacing
- `test/rrule_test.dart` — ICS recurrence expansion
- `test/provider_config_test.dart` — BYOK/Demo settings screen
- `test/slotter_test.dart` — placement ordering, compression, stress
- `test/ui_test.dart` — hermetic composition, agenda, goal editing, planning, and settings tests

**Live suites** (real OpenRouter, 4–10 min, budget-hungry):
- `test/demo_live_test.dart` — end-to-end decompose
- `test/live_logic_test.dart` — multi-scenario decompose/replan/skip/multi-goal audits

**Known brittleness:** several suites hardcode `2026-09-28/29` fixtures against `DateTime.now()`; they fail once the clock passes that window. This needs a clock seam (injectable `now`) — do not rewrite fixture dates to mask it.

**Expectations:** run `flutter analyze` and the relevant focused suite before handing off. Full-suite green is not currently achievable due to the clock-brittleness issue above.

## Landing, onboarding, and demo planning

- Onboarding and Settings share availability presets; pending-session actions depend on start/end time, and session details support rename/delete.

- `/` serves `server/landing/`; `/app/` serves Flutter built with `--base-href /app/`.
- `npm run build` in `server/` assembles `dist/` from landing assets and `doer/build/web`; it does not run Flutter.
- First-run onboarding persists `onboarding_done` in secure storage; existing goals bypass it.
- Demo proxy secret: `OPENROUTER_API_KEY`; vars: `DEMO_MODEL`, `DEMO_UPSTREAM`. Set an OpenRouter dashboard spend limit before enabling it.
- UUID v4 bearer identity and rate bindings limit demo requests to 6/user and 20/IP per minute per Cloudflare location.
- E2E: install `e2e/` dependencies, build Flutter, then `node e2e/run.mjs` from root. Local mock credentials are isolated in `e2e/.dev.vars.e2e`.
