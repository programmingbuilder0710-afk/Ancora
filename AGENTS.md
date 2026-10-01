<arg_value># Repository Guidelines

## Project Overview

**Doer** (`doer/`, packaged as `com.doer.doer`) is an Android-only Flutter app that decomposes user goals into calendar-scheduled tasks via an OpenAI-compatible LLM (demo default: OpenRouter), places those tasks deterministically on-device, and writes them to the device calendar. The LLM performs **semantics only** (task decomposition, `recommended_day`); all datetime math and placement is deterministic Dart.

Two authoritative docs exist at repo root:
- `SPEC.md` — product/architecture spec (invariants, SQLite DDL, LLM schemas, slotter algorithm, degradation matrix)
- `FRONTEND_CONTRACT.md` — generated companion documenting every implemented public API with exact signatures; **regenerate/update when `doer/lib/` changes**

**Current state:** `doer/lib/main.dart` is still the Flutter counter demo. No composition root exists. Only `ProviderSettingsScreen` is implemented and unrouted. `lib/ui/agenda/` and `lib/ui/goals/` are empty.

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
- **No backend/proxy** — Flutter calls the LLM provider directly (OpenAI-compatible; demo key or BYOK)

## Key Directories

| Path | Purpose |
|---|---|
| `doer/lib/models/` | `Goal`, `Task`, `BusyBlock`, `UserPreferences` — pure data classes with `toMap`/`fromMap` |
| `doer/lib/data/` | `DatabaseHelper` — SQLite via sqflite, `PRAGMA foreign_keys = ON`, singleton (file) or `forTest()` (in-memory) |
| `doer/lib/provider/` | `LlmProvider` interface, `OpenAiCompatibleProvider`, `DemoProvider`, `ProviderConfigService` (demo/BYOK modes; keys in `flutter_secure_storage`, never SQLite) |
| `doer/lib/extraction/` | `ExtractionService` — `.txt`/`.md`/`.pdf`/`.docx` text extraction (5000-char cap) + `.ics` parsing (366-occurrence cap) |
| `doer/lib/slotter/` | `Slotter`, `PlacementResult`, `FreeSegment` — synchronous deterministic placement; public `allGoals`/`allTasks` registries must be hydrated by the caller |
| `doer/lib/orchestration/` | `Orchestrator` — decompose/replan/skipTask/completeTask/importIcsFile; the only LLM callers |
| `doer/lib/calendar/` | `CalendarService` — device_calendar writes to "My Plan"; timezone resolved at construction from `UserPreferences.timezone` |
| `doer/lib/ui/settings/` | `ProviderSettingsScreen` — only implemented frontend screen (unrouted) |
| `doer/test/` | hermetic + live test suites (see Testing below) |

## Development Commands

All commands run from `doer/`.

```bash
# Run the app
flutter run

# Static analysis (flutter_lints 6 defaults; excludes build/** and android/**)
flutter analyze

# Run all tests
flutter test

# Run a focused suite
flutter test test/orchestrator_test.dart
flutter test test/slotter_test.dart
flutter test test/calendar_timezone_test.dart

# Hermetic suites only (no network)
flutter test test/regression_test.dart test/file_input_test.dart test/provider_config_test.dart test/rrule_test.dart test/widget_test.dart

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
| `doer/lib/ui/settings/provider_settings_screen.dart` | Only frontend screen; caller must load initial values before construction |
| `doer/pubspec.yaml` | Dependencies, SDK constraints |
| `doer/analysis_options.yaml` | Lint config (flutter_lints 6, excludes build/android) |

**Stale backups — do not read or copy:** `SPEC.md~`, `doer/lib/provider/provider_config_service.dart~` contain different (older) defaults.

## Runtime/Tooling Preferences

- **Runtime:** Flutter ≥3.44.0, Dart SDK ^3.13.4 (`pubspec.lock`)
- **Platform:** Android-only. `com.doer.doer`, Java 17, Kotlin 2.4.0 (`doer/android/app/build.gradle.kts`), Gradle 9.3.1 (`doer/android/gradle/wrapper/gradle-wrapper.properties`), AGP 9.1.0 (`doer/android/settings.gradle.kts`)
- **Android permissions:** main manifest (`doer/android/app/src/main/AndroidManifest.xml`) declares `READ_CALENDAR` + `WRITE_CALENDAR` (required by `device_calendar`); normal Flutter debug/profile manifests add `INTERNET` for dev tooling
- **Build output:** redirected to repo-root `build/` via `doer/android/build.gradle.kts`
- **Release signing:** uses debug keys (no release signing configured — explicit TODO)
- **No scripts/CI/Makefile/justfile** exist; use `flutter`/`dart` CLI directly from `doer/`
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
- `test/widget_test.dart` — placeholder

**Live suites** (real OpenRouter, 4–10 min, budget-hungry):
- `test/demo_live_test.dart` — end-to-end decompose
- `test/live_logic_test.dart` — multi-scenario decompose/replan/skip/multi-goal audits

**Known brittleness:** several suites hardcode `2026-09-28/29` fixtures against `DateTime.now()`; they fail once the clock passes that window. This needs a clock seam (injectable `now`) — do not rewrite fixture dates to mask it.

**Expectations:** run `flutter analyze` and the relevant focused suite before handing off. Full-suite green is not currently achievable due to the clock-brittleness issue above.
