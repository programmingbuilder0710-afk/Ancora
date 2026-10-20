# Frontend Service Contract — Doer

> Companion to `SPEC.md`. Every public API the Flutter UI may call, exact Dart signatures, data shapes, error taxonomy, retry/quota semantics, and lifecycle rules. Zero invented APIs — each symbol greps to `doer/lib/`.

---

## 1. Error Taxonomy (package:doer/provider/provider.dart)

All LLM/provider errors derive from `LlmProviderException implements Exception`. Catch by concrete type.

| Type | Cause | Retry Guidance | UI Meaning |
|------|-------|----------------|------------|
| `AuthError` | 401/403 from provider (invalid/expired key) | **Never auto-retry**. Prompt user to Settings → fix key. | "Auth failed — check API key in Settings."
| `RateLimitError` | 429 from provider. Backoff handled **inside** `OpenAiCompatibleProvider.complete()` (3 retries: 20s, 40s, 80s). If all exhausted → this error bubbles. | **Do not retry** (already exhausted). User may wait and retry manually later. | "Rate limited — try again in a few minutes."
| `QuotaError` | HTTP 402, or demo-provider 401/403 mapped from `AuthError`. | **Never auto-retry**. User must fix billing/provider configuration. | "Quota exhausted — add credits or switch provider." |
| `SchemaViolationError` | Provider response was not decodable as a JSON object (for example, HTTP body/content shape was invalid). Includes `rawResponse`. Semantic task rows that decode but violate the task contract are instead dropped/normalized without this exception. | `Orchestrator` retries this provider exception once with the validation error appended. A second provider parse failure propagates. | User-triggered retry after repeated failure. |
| `NetworkError` | Transport failure (DNS, no connectivity, or client failure). | No automatic retry in provider or Orchestrator; offer a user-triggered retry. | "Network error — check connection." |
| `ProviderError` | Any other HTTP status (500, 503, etc.). Includes `statusCode`. | No automatic retry in provider or Orchestrator; offer a user-triggered retry. | "Provider error (${statusCode}) — try again." |

**Orchestrator contract:** `decompose()` and `replan()` retry a provider-thrown `SchemaViolationError` once. Decoded-but-semantically-invalid task rows are dropped/normalized; if no valid task remains, a plain `Exception('LLM returned no valid tasks')` is thrown. UI should also catch ordinary `Exception` for local validation, SQLite, file, and calendar failures.

### Provider class interface and construction

```dart
abstract class LlmProvider {
  Future<Map<String, dynamic>> complete({
    required String system,
    required String user,
    required Map<String, dynamic> jsonSchema,
  });
}

OpenAiCompatibleProvider({
  required String apiKey,
  required String baseUrl,
  required String model,
  http.Client? client, // test/injection seam
});

DemoProvider({
  required String apiKey,
  required String baseUrl,
  required String model,
  http.Client? client,
});
```

- `SchemaViolationError.rawResponse` stores the full HTTP body; `ProviderError.statusCode` stores the status. `toString()` on any provider exception returns only its message.
- `complete()` accepts JSON schema in the request but does not run a local JSON-Schema validator. It requires HTTP 200 and decodes outer JSON → `choices[0].message.content` → inner JSON object; any failure becomes `SchemaViolationError`.
- `Uri.parse('$baseUrl/chat/completions')` runs before the POST try block, so an invalid base URL can throw `FormatException` rather than `NetworkError`. The injected/default `http.Client` has no public close method in this class.
- UI normally obtains these adapters through `ProviderConfigService`, not by constructing them directly. Direct construction is mainly useful for tests or a caller implementing an explicit provider seam.

---

## 2. Orchestrator (`doer/lib/orchestration/orchestrator.dart`)

### Construction
```dart
static const int horizonDays = 7;

Orchestrator({
  required DatabaseHelper db,
  required LlmProvider Function() providerFactory,
  required Slotter slotter,
  PlanCalendar? calendar,
})```

- `providerFactory` is **synchronous and non-null**. `decompose()` calls it only after the non-empty input check; `replan()` calls it before database reads. `buildActiveProvider()` is async+nullable and NOT directly compatible — see §11.
- `calendar` optional; if null, device-calendar writes are skipped (useful for tests/previews).

### Public Methods

#### `decompose`
```dart
Future<List<PlacementResult>> decompose({
  required List<Goal> goals,
})```
**Flow:** checks non-empty input → synchronously gets provider → reads `[today, today+7d)` busy blocks, all tasks, and documents sequentially per supplied goal → summarizes context → calls LLM → semantically validates and batch-inserts accepted tasks → rereads **all pending tasks** → Slotter placement → persists placed rows → best-effort calendar rewrite. Supplied goals are context only; `decompose()` does not insert them, and accepted tasks require those goal rows to exist because tasks have a foreign key.

**Returns:** one `PlacementResult` for every pending task read from SQLite, not one per goal. Existing pending work may therefore be included. Each carries:
- `task` — a placed copy, an unchanged non-pending row, or an unscheduled task copy
- `adjusted: bool` — wrapper-level spill/compression/unscheduled flag
- `note: String?` — `'spilled_to_next_day'` | `'compressed'` | `'unscheduled'` | `null`

Implementation details:
- The model's `remaining_free_hours` field is misnamed: it is total placed-task hours, not busy-minus-placed free capacity; task intervals are not clipped per day.
- LLM task IDs are advisory for decomposition; accepted tasks receive fresh UUIDs. Duplicate model IDs are not deduplicated. Malformed rows, unknown goal IDs, duration outside 5–480, unparsable/out-of-horizon dates, and unknown/self prerequisites are dropped; title-length/exact date spelling are not locally checked; cyclic tasks remain with all in-batch prerequisite edges cleared.
- Accepted rows are committed before Slotter/calendar work. Repeated decomposition creates more tasks; this method is not idempotent. A later exception can leave partial SQLite state.
- Only non-null placements are persisted. If an existing scheduled pending task becomes unscheduled, its old SQLite schedule is not cleared. Calendar rewrite can leave stale device IDs after swallowed failures, and returned result tasks do not receive successfully stored device IDs.

**Throws:** typed provider errors; `Exception('LLM returned no valid tasks')`; `TypeError` for missing/wrong `tasks`; SQLite/format/range/plugin exceptions; provider-factory exceptions. Most errors are not translated.

#### `replan`
```dart
Future<ReplanResult> replan()```
**Full re-plan.** Calls the factory first, then reads busy blocks, all tasks, and active+archived goals. “Unfinished” means `pending` or `skipped`. Completed tasks are omitted from mutable input and included only in a completed digest. With no unfinished rows, returns empty without an LLM call. Replan does **not** load documents; replanned work must use task data, not document context.

**Returns:**
```dart
class ReplanResult {
  final List<PlacementResult> placementResults;
  final List<String> tips;
}
```

Implementation details:
- Matching unfinished task IDs are preserved; unknown response IDs receive temporary UUIDs during validation, then their update loop finds no existing match and does nothing. The validator therefore does not reject every unknown ID before the no-valid-task check.
- Only matching rows are cleared/rebuilt. Model title, duration, recommended day, and prerequisites replace client values; goal ID, status, skip count, device ID, created time, and pinned deadline are restored. Pending tasks omitted by the model keep old scheduling fields but are still passed to Slotter.
- Slotter receives only pending rows to place; scheduled non-pending tasks overlapping the horizon are supplied as synthetic in-memory busy blocks in both decompose and replan. These blocks are not persisted. Null placements are not persisted. Calendar failures are swallowed and do not roll back database changes.
- `tips` is cast/evaluated after database and calendar work. Wrong `tips` type can throw after mutation; element count is not locally enforced even though the request schema says at most three.

**Throws:** typed provider errors, ordinary SQLite/plugin/cast/range errors, and potentially no-valid-task `Exception`. There is no task-not-found guard.

#### `skipTask`
```dart
Future<PlacementResult> skipTask(String taskId)```
**Local re-slot, no LLM.** Accepts pending or already-skipped tasks. Increments `skipCount`, resets status to pending, clears schedule/device ID, treats every other scheduled current task as occupancy, then uses the normal full-then-compression Slotter search from `max(original schedule day, today)`. Compression chooses the globally largest segment, so “nearest” is not guaranteed. SQLite updates first; all calendar failures are swallowed. The returned task still has a null device ID even when a newly created ID was persisted.

**Throws:** `Exception('Task not found: $taskId')`, `Exception('Cannot skip a completed task')`, plus DB errors.

#### `completeTask`
```dart
Future<void> completeTask(String taskId)```
**Monotonic completion.** An already-completed ID is a no-op. Otherwise writes the full task map with completed status, never re-slots, never touches calendar, and does not verify that `updateTask` affected one row.

**Throws:** `Exception('Task not found: $taskId')` plus DB errors.

#### `importIcsFile`
```dart
Future<int> importIcsFile(String filePath, String sourceName)```
Reads/parses the file, deletes every block for the exact `sourceName`, then inserts a non-empty parsed batch; returns parsed count. DELETE and INSERT are not one transaction, so insert failure can leave that source empty.

**Throws:** file/driver errors. Malformed event properties are skipped/tolerated by the parser.

---

### `PlacementResult`, `FreeSegment`, and `Slotter`
```dart
class FreeSegment {
  final DateTime start;
  final DateTime end;
  final int durationMinutes;
  FreeSegment(this.start, this.end)
      : durationMinutes = end.difference(start).inMinutes; // no order validation
}

class PlacementResult {
  final Task task;
  final bool adjusted;
  final String? note;
  PlacementResult(this.task, {this.adjusted = false, this.note});
}

class Slotter {
  final UserPreferences preferences;
  Map<String, Goal> allGoals = {}; // priority + target-date context
  List<Task> allTasks = [];        // external prerequisite-day context only

  Slotter(this.preferences);

  List<PlacementResult> placeTasks({
    required List<Task> tasks,
    required List<BusyBlock> busyBlocks,
    required DateTime horizonStart,
    required int horizonDays,
  });

  PlacementResult reSlotSkippedTask({
    required Task task,
    required List<BusyBlock> busyBlocks,
    required List<Task> currentTasks,
    required DateTime horizonStart,
    required int horizonDays,
  });
}
```

`Slotter` is synchronous, persists nothing, and works on task copies. `allTasks` is **not** occupancy for `placeTasks`; occupancy comes from `busyBlocks` and scheduled tasks in the `tasks` argument. `reSlotSkippedTask` uses its `currentTasks` argument for occupancy. Neither input list is automatically combined with `allTasks`.

**Behavioral details:**
- Work window is `preferences.workStart`–`workEnd` (model defaults 09:00–18:00); inactive weekdays have no segments. Malformed/out-of-range preference times or task dates propagate format/range errors.
- Busy intervals are split by day and merged, then `bufferMinutes` (model default 10) is added on both sides when rebuilding free segments. A block whose start day lies before the horizon map is dropped entirely — `_buildOccupiedByDay` starts iterating at `startDay` and breaks immediately when that day is absent — even if its tail overlaps day 0. Only blocks starting inside the horizon are split across later days.
- Kahn levels use only prerequisites present in the input. Within each level: populated `allGoals` priority, lexical ISO `recommendedDay` (null last), then lexical `createdAt`. Cyclic remainder is appended without logging.
- A known prerequisite imposes only a calendar-day floor; prerequisite and dependent may share a day. In-batch placements override stale `allTasks` days; an unscheduled prerequisite imposes none.
- Latest day is pinned deadline, otherwise goal target date, capped to horizon end. Start is `max(recommendedDay, actual DateTime.now day)`, so `horizonStart` does not make historical dates work.
- Full-duration search is forward/earliest. The spill marker compares only month-day `.day` values, not a full date. Compression scans all eligible segments and chooses the globally largest (earliest tie), then clamps to 15..requested minutes.
- Non-pending tasks supplied to `placeTasks` are returned unchanged and occupy time only if scheduled. Pending tasks, including already scheduled ones, are actively re-placed.

---

## 4. CalendarService (`doer/lib/calendar/calendar_service.dart`)

```dart
class CalendarService {
  CalendarService(String? initialPlanCalendarId, {UserPreferences? preferences});

  /// Resolved IANA zone name ('UTC' when omitted/empty/invalid).
  String get resolvedTimezone;

  /// Resolved tz.Location used by writeTaskEvent.
  tz.Location get timeZone;

  /// Non-null only when UserPreferences.timezone was invalid and fell back to UTC.
  String? get timezoneWarning;

  /// Resolve permissions and the "My Plan" calendar. Timezone is already
  /// resolved at construction and is not touched here.
  Future<void> initialize()

  /// Create one event for a scheduled task (no eventId is passed to the
  /// plugin, so this is not an in-place update). Returns the new device ID.
  Future<String> writeTaskEvent(Task task)

  /// Delete a device event by its ID.
  Future<void> deleteEvent(String deviceEventId)

  /// Best-effort rewrite: delete old mapped events, then create events for
  /// placed tasks. Per-operation failures are swallowed; returns successful IDs.
  Future<Map<String, String>> atomicRewrite(
    List<PlacementResult> placementResults,
    Map<String, String> existingDeviceIds,
  )

  /// Read-only getter after initialize.
  String get planCalendarId
}
```

- Calendar name fixed to **"My Plan"** (green, local account "Doer"). `initialize()` selects the first exact name or creates it; a non-null constructor ID is only an initial hint. The resolved ID is not persisted back into preferences.
- **Android prerequisite:** `READ_CALENDAR` and `WRITE_CALENDAR` are declared in `AndroidManifest.xml`. Without both, the plugin's permission/retrieval path fails before this service can operate.
- Normal setup calls `initialize()`, but a successful permission check that reports not-granted triggers a request, while a failed permission check proceeds to retrieval. `writeTaskEvent`/`deleteEvent` can use a valid non-null constructor ID without initialization. Calendar creation only checks for a non-null returned ID, not plugin success.
- The constructor initializes the timezone database, resolves `UserPreferences.timezone` (null/empty → UTC), stores the resulting `tz.Location`, and calls `tz.setLocalLocation(_location)` on both the valid and fallback paths, so the package-global `tz.local` is synced to the service's zone. On `LocationNotFoundException`, it falls back to UTC, records a human-readable `timezoneWarning` containing the invalid zone, and still syncs `tz.local`. `writeTaskEvent` uses the stored `_location`, so valid-ID writes use the correct zone before/after `initialize()`.
---

## 5. ProviderConfigService (`doer/lib/provider/provider_config_service.dart`)

Manages **two modes**: `demo` (built-in defaults, user-editable) and `byok` (user supplies key + preset/custom endpoint). **Key never stored in SQLite** — only `flutter_secure_storage`.

### Construction
```dart
ProviderConfigService({
  required DatabaseHelper db,
  FlutterSecureStorage? storage, // test seam
})```

### Constants (build-time defaults)
```dart
static const defaultDemoBaseUrl = 'https://openrouter.ai/api/v1';
static const defaultDemoModel = 'qwen/qwen3.8-27b:free';
static const defaultDemoApiKey = '';
```

### Read APIs
```dart
Future<String> getMode() // 'demo' | 'byok' (default 'demo')

Future<({String apiKey, String baseUrl, String model})> getDemoConfig()
  // Secure-storage values; each missing value (null) falls back to defaults.

Future<({String apiKey, String baseUrl, String model})?> getByokConfig()
  // Null unless mode == byok, key is nonempty, and resolved base URL/model
  // are nonempty. Preset may be null/unknown if explicit base_url exists.
```

### Write APIs (called from Settings screen)
```dart
Future<void> saveDemoConfig({
  required String apiKey,
  required String baseUrl,
  required String model,
})

Future<void> saveByokConfig({
  required String preset, // 'openai' | 'anthropic' | 'gemini' | 'openrouter' | 'custom'
  required String apiKey,
  required String model,
  String? baseUrl, // UI requires it for custom; service itself does not validate
})
```
- `saveDemoConfig` / `saveByokConfig` do not trim or validate values. Writes span secure storage then SQLite and are not transactional across stores; a partial failure can leave mixed state.

### Factory (called by UI before constructing a synchronous Orchestrator closure)
```dart
Future<LlmProvider?> buildActiveProvider()
```
- Reads SQLite/secure storage fresh each call. Demo always constructs `DemoProvider`; BYOK returns `OpenAiCompatibleProvider` or null when key/base URL/model are incomplete.
- No URL, key, or model syntax validation occurs. BYOK reads mode/config in separate database calls; rebuild after Settings changes.

### Test Seam
```dart
Future<String?> readKey(String key) => secureStorage.read(key: key);
Future<void> writeKey(String key, String value) => secureStorage.write(key: key, value: value);
```
Override in tests via subclass (see `demo_live_test.dart:86-91` and `live_logic_test.dart:392-397`). (`provider_config_test.dart` uses a different `SpyConfigService implements ProviderConfigService` seam and does not override secure storage.)

---

## 6. DatabaseHelper — Read APIs (`doer/lib/data/database_helper.dart`)

Task queries order by `scheduled_start`; SQLite places null schedules first. Goal queries order by priority then target date. FK enforcement **ON** (`PRAGMA foreign_keys = ON`).

### Goals
```dart
Future<List<Goal>> getAllGoals({bool activeOnly = true})
Future<Goal?> getGoal(String id)
Future<int> insertGoal(Goal goal)
Future<int> updateGoal(Goal goal)
Future<int> deleteGoal(String id) // transactional tasks/documents; child goals block deletion
```

### Tasks
```dart
Future<List<Task>> getAllTasks()
Future<List<Task>> getTasksByGoal(String goalId)
Future<List<Task>> getTasksByStatus(TaskStatus status)
Future<Task?> getTask(String id)
Future<int> insertTask(Task task)
Future<int> insertTasks(List<Task> tasks)
Future<int> updateTask(Task task) // writes full map; null nullable columns are cleared
Future<int> deleteTask(String id) // no calendar cleanup
Future<int> deleteTasksByGoal(String goalId) // no calendar cleanup
Future<int> deleteUnplacedTasks() // deletes every null-scheduled row, including completed/skipped; no calendar cleanup
```

### Documents
```dart
Future<int> insertDocument({required String id, required String goalId, required String filename, required String extractedText})
Future<List<Map<String, dynamic>>> getDocumentsByGoal(String goalId)
```

### Busy Blocks
```dart
Future<int> insertBusyBlock(BusyBlock block)
Future<int> insertBusyBlocks(List<BusyBlock> blocks)
Future<List<BusyBlock>> getBusyBlocksInRange(DateTime start, DateTime end)
  // Overlap query: start < rangeEnd AND end > rangeStart
Future<int> deleteBusyBlocksBySource(String source)
Future<int> clearBusyBlocks()
```

### User Preferences
```dart
Future<int> upsertPreferences(UserPreferences prefs)
Future<UserPreferences?> getPreferences()
```

### Provider Config (SQLite side — key not here)
```dart
Future<int> upsertProviderConfig({required String mode, String? preset, String? baseUrl, String? model})
Future<Map<String, dynamic>?> getProviderConfig()
```

### Lifecycle / connection seam
```dart
Future<Database> get database // lazy; concurrent first access is not coordinated
Future<void> close() // no-op before open; clears cache, then closes; next access reopens
```

---

## 7. ExtractionService (`doer/lib/extraction/extraction.dart`)

```dart
class ExtractionService {
  static const int maxCharsPerDoc = 5000;
  static const int maxOccurrences = 366;

  /// txt/md: read as text; pdf/docx: tolerant UTF-8 bytes, not structural parsing.
  Future<String> extractText(File file)

  /// Supports DAILY/WEEKLY/MONTHLY, INTERVAL, COUNT, inclusive UNTIL,
  /// and weekly BYDAY. Returns at most maxOccurrences occurrences.
  List<BusyBlock> parseIcsContent(String content, String sourceName)
}
```

- `extractText`: txt/md I/O/decode failures propagate; pdf/docx catches all failures and returns empty; unsupported/no-extension paths return empty without reading. Truncation is by Dart code units at 5000, not grapheme-aware.
- `parseIcsContent`: lines/property names are case-sensitive; folded physical lines are not reconstructed. An unparsable DTEND is treated as missing (not as an event rejection) and falls back to DTSTART+1h; a missing/invalid DTSTART causes no event. Non-positive event duration is skipped. COUNT/UNTIL are independent upper bounds; `COUNT<=0` or `UNTIL` before DTSTART can still emit DTSTART. Numeric ICS dates may normalize through Dart `DateTime`; offsets other than terminal `Z` are ignored; month-end recurrence can drift.

---

## 8. Data Shapes (`doer/lib/models/models.dart`)

### Goal
```dart
class Goal {
  final String id;
  final String? parentGoalId;
  final String title;
  final String description;
  final GoalPriority priority; // P1 | P2 | P3
  final String targetDate; // YYYY-MM-DD
  final GoalStatus status; // active | archived
  final String createdAt; // ISO 8601
}
```

### Task
```dart
class Task {
  final String id;
  final String goalId;
  final String title;
  final int durationMinutes; // 5–480
  final String? recommendedDay; // YYYY-MM-DD (LLM-assigned)
  final String? pinnedDeadline; // YYYY-MM-DD (hard ceiling)
  final List<String> prerequisiteIds; // other task_ids in same batch
  final String? scheduledStart; // ISO 8601 local, set by Slotter
  final String? scheduledEnd;
  final TaskStatus status; // pending | completed | skipped
  final bool adjusted; // Slotter sets true on spill/compression; unscheduled PlacementResult is adjusted even if this field is unchanged
  final int skipCount; // incremented by skipTask
  final String? deviceEventId; // calendar event ID
  final String createdAt; // ISO 8601

  Task copyWith({...
    bool clearSchedule = false,
    bool clearDeviceEventId = false,
    bool clearPinnedDeadline = false,
  })
}
```

**Monotonic completion contract:** `status == completed` ⇒ completed tasks are never edited by `replan()`, `skipTask()`, or `completeTask()` again. `Slotter` freezes a non-pending task only when that task is included in its `tasks` argument and already has a schedule; `Orchestrator.decompose()`/`replan()` pass pending tasks for placement and add scheduled non-pending tasks overlapping the horizon as synthetic in-memory busy blocks, so completed slots remain occupied.

### BusyBlock
```dart
class BusyBlock {
  final String id;
  final String source; // e.g., "work", "cal.ics", "manual"
  final DateTime start;
  final DateTime end;
}
```

### UserPreferences
```dart
class UserPreferences {
  final String workStart; // 'HH:mm' 24h
  final String workEnd;
  final int bufferMinutes; // default 10
  final List<String> activeDays; // subset of ['mon'..'sun']
  final String timezone; // IANA, e.g., 'America/Los_Angeles'
  final String? planCalendarId;
}
```

---

## 9. Lifecycle Rules

| Component | Rule |
|-----------|------|
| `DatabaseHelper` | Singleton per app (one file DB). `forTest()` → fresh `:memory:` per instance (`singleInstance: false`). Call `close()` on teardown (idempotent). |
| `ProviderConfigService` | One instance per app. Call `await buildActiveProvider()` before constructing/caching a synchronous provider closure for `decompose`/`replan`; rebuild after settings changes. |
| `CalendarService` | One instance. Normal flow calls `initialize()` after construction; Android permissions (`READ_CALENDAR`/`WRITE_CALENDAR`) are declared in the manifest. The constructor resolves `UserPreferences.timezone` into a stored `tz.Location`, syncs the package-global `tz.local` via `setLocalLocation`, exposes `resolvedTimezone`/`timeZone`/`timezoneWarning`, and falls back to UTC with a surfaced warning on `LocationNotFoundException`. Writes use the stored location without `initialize()`. |
| `Slotter` | Public `allGoals`/`allTasks` registries exist for priority/deadline/prerequisite context, hydrated by `AppServices.orchestrator()` before each operation. Without caller hydration, priority and target-deadline lookup silently fall back and external prerequisite placements may be invisible. |
| `Orchestrator` | Short-lived per operation (or cached with a synchronous factory). Holds `db`, `slotter`, optional `calendar`. The factory is called only by `decompose`/`replan`; local operations do not need a working provider. |

**Async pattern:** database, provider configuration/build, calendar, and Orchestrator methods are asynchronous; `Slotter` placement and ICS parsing are synchronous. UI must `await` asynchronous calls, handle typed provider errors (section 1), and refresh SQLite-backed lists after a successful mutation. There are no streams.

---

## 10. Grep Cross-Reference (verification)

Run these to confirm every documented symbol exists:

```bash
# Orchestrator
grep -n "decompose\|replan\|skipTask\|completeTask\|importIcsFile" doer/lib/orchestration/orchestrator.dart

# ProviderConfigService
grep -n "getMode\|getDemoConfig\|getByokConfig\|saveDemoConfig\|saveByokConfig\|buildActiveProvider" doer/lib/provider/provider_config_service.dart

# CalendarService
grep -n "initialize\|writeTaskEvent\|deleteEvent\|atomicRewrite" doer/lib/calendar/calendar_service.dart

# DatabaseHelper reads
grep -n "getAllGoals\|getGoal\|getAllTasks\|getTasksByGoal\|getTasksByStatus\|getTask\|getDocumentsByGoal\|getBusyBlocksInRange\|getPreferences\|getProviderConfig" doer/lib/data/database_helper.dart

# ExtractionService
grep -n "extractText\|parseIcsContent" doer/lib/extraction/extraction.dart

# Slotter
grep -n "placeTasks\|reSlotSkippedTask" doer/lib/slotter/slotter.dart

# Error classes
grep -n "class.*Error.*extends LlmProviderException" doer/lib/provider/provider.dart

# Model classes
grep -n "^class Goal\|^class Task\|^class BusyBlock\|^class UserPreferences" doer/lib/models/models.dart
```

All should return ≥1 line each. `flutter analyze` must stay clean (this doc touches no code).

---

## 11. Composition & Class Usage

### Concrete production wiring today

`main()` loads `AppServices` and opens `MyApp` / `AppShell`. `AppServices` owns the graph below and awaits `ProviderConfigService.buildActiveProvider()` for provider-backed operations. Settings routes to `ProviderSettingsScreen` after loading its initial values. See §13 for the UI API.

### Ownership & lifetime

| Component | Owner | Lifetime | Construction |
|-----------|-------|----------|--------------|
| `DatabaseHelper` | Composition root / `ProviderConfigService` | App-wide singleton (`factory DatabaseHelper()` returns `_instance`) | `DatabaseHelper()` |
| `ProviderConfigService` | Composition root / Settings screen | App-wide (holds `db` + secure storage) | `ProviderConfigService(db: db)` |
| `Slotter` | Composition root / Orchestrator caller | Per operation batch or app-wide (mutable registries) | `Slotter(prefs)` |
| `CalendarService` | Composition root | App-wide once initialized | `CalendarService(initialPlanCalendarId)` |
| `Orchestrator` | Composition root per screen action | Short-lived per operation or cached with a synchronous factory | `Orchestrator(db: ..., providerFactory: ..., slotter: ...)` |
| `LlmProvider` (`DemoProvider` / `OpenAiCompatibleProvider`) | `ProviderConfigService.buildActiveProvider()` | Fresh per config build; normally cached by a synchronous Orchestrator closure | Built inside config service, not directly by UI |

### `providerFactory` — real type contract (must-fix wiring note)

```dart
final LlmProvider Function() providerFactory; // synchronous, non-null
```

`Orchestrator` invokes it synchronously (`orchestrator.dart:123,239`). **`ProviderConfigService.buildActiveProvider()` is `Future<LlmProvider?>` and is NOT directly type-compatible** — the naive `() => providerConfigService.buildActiveProvider()` closure is a type error. Two supported patterns:

**Pattern A — await the config service once, then return a cached non-null provider (used by provider-backed live tests):**
```dart
final provider = await configService.buildActiveProvider();
if (provider == null) {
  // BYOK incomplete → route user to ProviderSettingsScreen before scheduling.
  throw StateError('Provider not configured');
}
final orchestrator = Orchestrator(
  db: helper,
  providerFactory: () => provider!, // cached non-null, synchronous closure
  slotter: slotter,
  calendar: calendar, // optional
);
```
This is the config-service-compatible pattern. Tests may also pass a known non-null fake directly (`orchestrator_test.dart:90-96`). Mid-session Settings changes require rebuilding the `Orchestrator` or at least rebuilding `provider`; the cached closure does NOT re-read config.

**Pattern B — no provider for local-only operations (used by file_input tests):**
```dart
final orchestrator = Orchestrator(
  db: helper,
  providerFactory: () => throw StateError('unreachable'), // never called
  slotter: Slotter(prefs),
);
```
`skipTask`, `completeTask`, and `importIcsFile` never invoke the factory, so this is safe for screens that only mutate local state. Consequence: `decompose`/`replan` on this instance will throw.

### Full setup example (mirrors `demo_live_test.dart:12-90` and `live_logic_test.dart:setup`)

```dart
// 1. Database
final helper = DatabaseHelper(); // production singleton

// 2. Preferences (caller must load or insert defaults first)
final storedPrefs = await helper.getPreferences();
final prefs = storedPrefs ?? UserPreferences(
  workStart: '09:00',
  workEnd: '18:00',
  bufferMinutes: 10,
  activeDays: ['mon','tue','wed','thu','fri','sat','sun'],
  timezone: 'America/Los_Angeles', // supply the app/device's IANA zone
);
if (storedPrefs == null) await helper.upsertPreferences(prefs);

// 3. Provider (await once, then cache a synchronous non-null closure)
final configService = ProviderConfigService(db: helper);
final provider = await configService.buildActiveProvider();
if (provider == null) throw StateError('Provider not configured');

// 4. Calendar — truly optional; failure must not prevent local scheduling.
CalendarService? calendar;
try {
  final candidate = CalendarService(prefs.planCalendarId, preferences: prefs);
  await candidate.initialize();
  calendar = candidate;
} on Exception {
  calendar = null; // Or set a banner; skip device-calendar writes.
}

// 5. Slotter registries. Hydrate before EVERY decompose/replan/skip action.
final slotter = Slotter(prefs);
final goals = await helper.getAllGoals(activeOnly: false);
slotter.allGoals = {for (final g in goals) g.id: g};
slotter.allTasks = await helper.getAllTasks();

// 6. Orchestrator
final orchestrator = Orchestrator(
  db: helper,
  providerFactory: () => provider!,
  slotter: slotter,
  calendar: calendar,
);
```

Platform/timezone notes:
- Android requires `READ_CALENDAR`/`WRITE_CALENDAR`; both are declared in the checked-in manifest.
- `CalendarService(prefs.planCalendarId, preferences: prefs)` resolves the timezone package location from `UserPreferences.timezone` at construction; without `preferences`, writes use UTC. This works for valid-ID writes before `initialize()` as well.
- Refresh `slotter.allGoals` and `slotter.allTasks` immediately before every decompose/replan/skip action, because neither `Orchestrator` nor `DatabaseHelper` mutates them.

### Slotter registry effect on behavior (source-verified)

`slotter.allGoals` / `slotter.allTasks` are public mutable fields (`slotter.dart:25-26`). `AppServices.orchestrator()` assigns them before every UI operation; the backend itself does not. Caller responsibilities:
- `allGoals`: same-level priority and goal target-date ceiling. Hydrate with active + archived goals relevant to current/replanned work.
- `allTasks`: external prerequisite calendar-day context only. It does not make completed/skipped tasks occupancy in `placeTasks`.
- `reSlotSkippedTask` occupancy comes from its `currentTasks` argument, not `allTasks`.
- A cached Slotter must be refreshed before use because Orchestrator does not mutate these registries.

```dart
slotter.allGoals = {for (final g in goals) g.id: g};
slotter.allTasks = await db.getAllTasks();
```

### `CalendarService` constructor — exact signature

CalendarService(this._planCalendarId, {this.preferences}); // REQUIRED positional id, optional preferences
```

Caller must supply a `String?` position. A non-null value is a starting ID; `initialize()` overwrites it by finding "My Plan" or creating the calendar. `planCalendarId` throws only when the current field is null, so initialize is not required after a valid non-null constructor ID. `preferences` is optional; construction resolves the calendar timezone from `UserPreferences.timezone` (UTC when omitted).

### `ProviderSettingsScreen` — concrete frontend screen (routed from Settings)

```dart
ProviderSettingsScreen({
  required ProviderConfigService configService,
  required String initialMode,       // 'demo' | 'byok'
  required String initialDemoApiKey,
  required String initialDemoBaseUrl,
  required String initialDemoModel,
  String? initialByokApiKey,
  String? initialByokBaseUrl,
  String? initialByokModel,
})
```
- **Caller must load all initial values BEFORE construction** (avoids async-in-initState).
- Internally detects BYOK preset from base URL host substring (`_presetHost`, line 85-98).
- Save buttons call `saveDemoConfig`/`saveByokConfig` on the injected service; BYOK key is written to secure storage only, never SQLite.

---

### Practical Flutter class recipes

The following recipes are composition templates, not new library APIs. Names of private widgets/helpers may vary.

#### `ProviderSettingsScreen`: load before route push, then show after save

```dart
Future<void> openProviderSettings(BuildContext context) async {
  final db = DatabaseHelper();
  final config = ProviderConfigService(db: db);

  // Read all values before constructing the screen. The widget initializes
  // TextEditingControllers synchronously in initState.
  final mode = await config.getMode();
  final demo = await config.getDemoConfig();
  // BYOK values are returned only while mode == byok. Switching to demo
  // replaces the single provider_config row, so inactive BYOK fields are
  // not restored and must be re-entered.
  final byok = await config.getByokConfig();

  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ProviderSettingsScreen(
        configService: config,
        initialMode: mode,
        initialDemoApiKey: demo.apiKey,
        initialDemoBaseUrl: demo.baseUrl,
        initialDemoModel: demo.model,
        initialByokApiKey: byok?.apiKey,
        initialByokBaseUrl: byok?.baseUrl,
        initialByokModel: byok?.model,
      ),
    ),
  );
}
```

#### `DatabaseHelper`: direct CRUD patterns

```dart
final db = DatabaseHelper();

final goal = Goal(
  id: 'goal-id',
  title: 'Goal title',
  priority: GoalPriority.P1,
  targetDate: '2026-10-07',
  createdAt: DateTime.now().toIso8601String(),
  description: 'Optional',
);
final goalRowId = await db.insertGoal(goal);

final activeGoals = await db.getAllGoals();               // default activeOnly=true
final everyGoal = await db.getAllGoals(activeOnly: false);
final goalRows = await db.getTasksByGoal(goal.id);

final documents = await db.getDocumentsByGoal(goal.id);
final rangeStart = DateTime.now();
final rangeEnd = rangeStart.add(const Duration(days: 7));
final busy = await db.getBusyBlocksInRange(rangeStart, rangeEnd);
```

- Single inserts and update/delete methods return SQLite row IDs/counts; batch inserts return the input list length.
- `getAllTasks`, `getTasksByGoal`, and `getTasksByStatus` order by `scheduled_start`; unscheduled tasks therefore appear first in SQLite's null ordering. Filter client-side when a screen needs a day/status view.
- `getBusyBlocksInRange(start,end)` uses overlap semantics: `block.start < end && block.end > start`; touching boundaries do not overlap.
- `upsertPreferences` and `upsertProviderConfig` use replace semantics (fixed singleton row for provider config). Use `ProviderConfigService` for provider writes so the key remains in secure storage.
- A successful `insertGoal` does not mean the whole scheduling operation succeeded. Because decomposition persists accepted tasks before Slotter/calendar work, a later failure can leave partial state; there is no orchestrator-wide transaction. Repeated calls for even one goal can create duplicate task rows.

#### `Orchestrator.decompose`: goal insertion happens before the call
```dart
Future<List<PlacementResult>> scheduleGoals(
  DatabaseHelper db,
  Orchestrator orchestrator,
  List<Goal> newGoals,
) async {
  try {
    for (final goal in newGoals) {
      await db.insertGoal(goal); // goal must exist before accepted tasks insert
    }

    // Hydrate registries after the insert: Orchestrator never does this.
    final goals = await db.getAllGoals(activeOnly: false);
    orchestrator.slotter.allGoals = {for (final g in goals) g.id: g};
    orchestrator.slotter.allTasks = await db.getAllTasks();

    return await orchestrator.decompose(goals: newGoals);
  } finally {
    // Reload after success OR failure: later phases may have partially committed.
    await db.getAllTasks();
  }
}

Implementation details:
- Empty `goals` returns `[]` before calling `providerFactory`. Supplied goals are context only; the method does not insert them.
- The busy-block query range is `[local midnight today, today+7d)`. Slotter searches seven dates ending today+6.
- Documents are included for `decompose()` only. Existing pending scheduled tasks are sent as a digest; `remaining_free_hours` is actually placed-task hours and does not subtract busy time.
- Accepted rows are committed before Slotter/calendar work. Repeated calls create duplicates. Only non-null placements are persisted. An existing pending task that becomes unscheduled can therefore leave SQLite/calendar divergence: its result is null-scheduled, its old SQLite schedule stays, `atomicRewrite` may delete its old event, and the row retains a stale `deviceEventId`.

#### `Orchestrator.replan`: explicit user action with completed freeze

```dart
final result = await orchestrator.replan();
for (final placement in result.placementResults) {
  final task = placement.task;
  render(placement.adjusted, placement.note, task.scheduledStart);
}
for (final tip in result.tips) showTip(tip);
```

- No unfinished row returns empty after the factory ran, without an LLM call. Replan does not read documents.
- Both decompose and replan preserve scheduled non-pending slots as occupancy (SPEC §5.1): the pre-plan task snapshot supplies synthetic busy blocks for intervals overlapping the horizon. These blocks are passed only to Slotter, never persisted or added to the LLM summary a second time.
- The prompt asks the model to echo unfinished UUIDs. Matching returned IDs are preserved and rebuilt; omitted unfinished rows are left unchanged; unknown response IDs create temporary tasks but update no SQLite row. Returned skipped rows keep `skipped` and can therefore be cleared/persisted but excluded from the pending-only Slotter pass.
- Matching rows are cleared and persisted one at a time. Null placements are not persisted; calendar changes are best-effort and not rolled back.
- `tips` parsing happens after database/calendar work. Wrong type can throw after mutation; more than three elements are not locally rejected.

#### `Orchestrator.skipTask` and `completeTask`: local actions
- `skipTask` accepts pending/skipped tasks, treats every other scheduled task as occupancy, and searches from `max(original day,today)`. Global-largest compression can move it beyond the nearest day. Calendar failures are swallowed; the returned task has no new device ID.
- `completeTask` is idempotent for completed rows, updates SQLite only, and does not touch calendar.
- Both methods never call `providerFactory`; a throwing local-only factory is valid.

#### `CalendarService`: optional but best initialized once

```dart
final calendar = CalendarService(savedCalendarId);
try {
  await calendar.initialize();
  final eventId = await calendar.writeTaskEvent(placedTask);
  await db.updateTask(placedTask.copyWith(deviceEventId: eventId));
} on Exception {
  // Permission denied, no writable calendar, or event creation failed.
}
```

- Constructor ID is a starting hint. `initialize()` finds the first exact `My Plan` or creates one; a successful permission check that reports not-granted triggers a request, while a failed permission check proceeds to retrieval. Calendar creation only checks a non-null returned ID, not plugin success.
- `writeTaskEvent` creates (not in-place updates) with description `Goal: <goalId>`, the constructor-resolved `tz.Location` (from `UserPreferences.timezone`; UTC when omitted), and `allDay:false`; missing schedule/plugin failure throws.
- `atomicRewrite` deletes only old IDs matched to `placementResults`, ignoring old-map entries for omitted/completed tasks. It can leave old IDs after swallowed delete/write failures and is neither calendar- nor database-transaction atomic.
- Completed events survive only incidentally because completed tasks are absent from `placementResults`; old-map entries without a matching result are ignored.

#### `ExtractionService` and `.ics` import

```dart
try {
  final text = await ExtractionService().extractText(file);
  await db.insertDocument(
    id: const Uuid().v4(),
    goalId: goal.id,
    filename: file.path.split(Platform.pathSeparator).last,
    extractedText: text,
  );
} on FileSystemException {
  showError('File could not be read.');
}

final count = await orchestrator.importIcsFile(path, stableSourceName);
```

- PDF/DOCX are tolerant UTF-8 byte reads, not structural parsers; txt/md read errors propagate. Empty text can mean unsupported/empty/caught failure.
- `importIcsFile` is DELETE→INSERT without one transaction. Parser lines/properties are case-sensitive; folded lines are not reconstructed. COUNT and UNTIL independently cap output; count<=0 or past UNTIL can still emit DTSTART; numeric dates can normalize, offsets other than terminal `Z` are ignored, and month-end recurrence can drift.

---

### Implementation semantics that affect UI decisions

#### Provider construction and request lifecycle

- Demo secure-storage defaults apply only when a stored value is null; blank values remain blank. BYOK completeness is mode + nonempty key + nonempty resolved base URL/model; explicit base URL can work without a preset.
- Config writes are sequential across secure storage and SQLite; custom requirements and syntax are caller responsibilities.
- `buildActiveProvider` returns a fresh adapter; invalid base URLs can throw `FormatException`, and BYOK mode/config are separate DB reads.
- `OpenAiCompatibleProvider` appends `/chat/completions`, sends strict JSON-schema response format at temperature 0.2, and retries only 429 (20/40/80s). `DemoProvider` maps 401/403 `AuthError` to `QuotaError`; 402 is inherited quota behavior.
- Reload SQLite-backed state after every orchestration attempt because earlier phases may already have committed. Do not automatically retry typed provider failures; rate-limit retries are exhausted and auth/quota require configuration.

#### Slotter ordering and search

- DB range retrieval can return blocks outside the horizon. Slotter drops any block whose start day precedes the horizon map, even when its tail overlaps day 0; only in-horizon-starting blocks are split forward.
- Busy intervals are split/merged, buffered, and consumed immediately. Inactive weekdays have no segments.
- `allGoals` supplies priority/deadline; `allTasks` supplies only external prerequisite days. Within levels: priority, ISO recommended day, ISO created time. Prerequisites only impose a day floor and may share a day.
- Full placement uses max(recommended day, actual today) and actual today rather than historical `horizonStart` for its lower bound. Latest day is pinned deadline → goal target → horizon end.
- Full search is earliest; compression chooses the globally largest eligible segment. Spill metadata compares only month-day `.day`. Unscheduled and non-pending handling follows §3.

#### Database and transactional boundaries

- Opening is lazy and concurrent first access is not coordinated. Closing clears the cached handle; file DB reopens, while test memory DB reopens empty.
- FKs cover task/document→goal and goal parent→goal, not busy blocks, prerequisite JSON, or calendar IDs. Direct goal/task deletion does not clean device events; a child goal blocks `deleteGoal` and rolls the transaction back.
- `deleteUnplacedTasks` includes completed/skipped rows. Busy block inserts do not validate intervals/overlaps. Batch inserts return input length, not verified SQLite count.
- Enum/constraint/serialization, driver, secure-storage, plugin, cast, format, and range errors generally propagate unchanged.

---
## 12. Quick-Start Checklist for UI Screens


| Screen | Must Call First | Typical Flow |
|--------|-----------------|--------------|
| Settings (Provider) | `ProviderConfigService.getMode()`, `getDemoConfig()`/`getByokConfig()` | Toggle mode → `saveDemoConfig()` / `saveByokConfig()` |
| Goals list | `DatabaseHelper.getAllGoals()` | `insertGoal()` → `Orchestrator.decompose()` |
| Agenda / Today | `DatabaseHelper.getAllTasks()` (or `getTasksByStatus(pending)`) | `skipTask()` → `completeTask()` |
| Re-plan button | `await configService.buildActiveProvider()` once → if null route to Settings → build `Orchestrator(providerFactory: () => provider!, ...)` | `Orchestrator.replan()` → refresh lists |
| .ics Import | `Orchestrator.importIcsFile(path, sourceName)` | Refresh agenda (busy blocks updated) |
| Document attach | `ExtractionService.extractText(file)` → `DatabaseHelper.insertDocument()` | Included by the next `decompose()`; `replan()` does not read documents |

---
*Generated from `doer/lib/` source. Keep in sync with SPEC.md.*

## 13. UI layer

`AppServices` is loaded once; screens receive it by constructor. Tab switches recreate the visible screen and reload SQLite. `flutter_timezone` resolves the device/browser IANA zone for default preferences (UTC fallback).

```dart
// lib/app_services.dart
static Future<AppServices> AppServices.load({DatabaseHelper? db,
  ProviderConfigService? config, bool initCalendar = true});
// Fields: final DatabaseHelper db; final ProviderConfigService config;
// UserPreferences prefs; CalendarService? calendar; String? calendarError;
// ConnectedCalendars? connected; String? lastSyncWarning;
Future<Orchestrator> orchestrator({bool needsProvider = false});
Future<void> reloadPrefs();
Future<void> deleteGoal(Goal goal);
Future<void> renameTask(Task task, String title);
Future<void> deleteTask(Task task);
Future<bool> usesBuiltInDemo();
Future<bool> needsOnboarding();
Future<void> finishOnboarding();
const String freePlanningUnavailable = 'Free planning is unavailable right now — add your own AI key in Settings.';
ProviderNotConfigured(); // implements Exception; final String message
String providerErrorMessage(Object e, {required bool demoMode});
bool isDemoExhausted(Object e, bool demoMode);

// All widget constructors also accept Key? key.
MyApp({required AppServices services});
AppShell({required AppServices services});
AgendaScreen({required AppServices services,
  required void Function(Object) onProviderError, required VoidCallback onAddGoal,
  DateTime? initialDay});
GoalsScreen({required AppServices services, required void Function(Object) onProviderError,
  void Function(DateTime?, String?)? onPlanned});
GoalEditScreen({required AppServices services, Goal? goal,
  required void Function(Object) onProviderError});
SettingsScreen({required AppServices services});
ReplanResultScreen({required Map<String, String?> before,
  required ReplanResult result, required List<Task> tasks, required List<Goal> goals});

// lib/ui/widgets.dart
String clock(BuildContext context, DateTime time);
String dayClock(BuildContext context, DateTime time);

// lib/ui/task_details.dart
Future<String?> showTaskDetails(BuildContext context, AppServices services,
  Goal goal, Task task);

// lib/ui/dialogs.dart
Future<bool> confirmAction(BuildContext context, String message);
Future<T> withProgress<T>(BuildContext context, Future<T> Function() action,
  {String label = 'Planning your week…'});
```


```dart
// lib/calendar/plan_calendar.dart (CalendarService implements PlanCalendar)
abstract interface class PlanCalendar {
  Future<Map<String, String>> atomicRewrite(List<PlacementResult> placementResults,
    Map<String, String> existingDeviceIds);
  Future<String> writeTaskEvent(Task task);
  Future<void> deleteEvent(String deviceEventId);
}
// Orchestrator constructor: calendar parameter/field is now PlanCalendar?.

// lib/calendar/connected_calendars.dart
const apiBase = String.fromEnvironment('DOER_API_BASE');
CalendarAccount({required String id, required String app, required String name});
// final String id; final String app; final String name;
ConnectedCalendars({required http.Client client, required DatabaseHelper db,
  String baseUrl = apiBase});
Future<String?> readKey(String key);
Future<void> writeKey(String key, String? value);
Future<String> userId();
Future<Uri> connectUrl(String app);
Future<List<CalendarAccount>> accounts();
Future<void> disconnect(String accountId);
Future<List<String>> icsUrls();
Future<void> addIcsUrl(String url);
Future<void> removeIcsUrl(String url);
Future<String?> planAccountId();
Future<void> setPlanAccountId(String? id);
Future<String?> syncBusy(DatabaseHelper db);
PipedreamPlanCalendar(ConnectedCalendars connected); // implements PlanCalendar
// final ConnectedCalendars connected;
Future<Map<String, String>> atomicRewrite(List<PlacementResult> placementResults,
  Map<String, String> existingDeviceIds);
Future<String> writeTaskEvent(Task task);
Future<void> deleteEvent(String deviceEventId);

// New APIs on existing classes
Future<String> ExtractionService.extractTextFromBytes(String filename, List<int> bytes);
Future<int> Orchestrator.importIcsContent(String content, String sourceName);
```


### UI presentation and shared components

`MyApp` uses Material 3 with bundled Inter (`google_fonts`), teal seed light/dark themes,
and `ThemeMode.system`. `AppShell` switches from bottom navigation to an extended
rail at 840 logical pixels. Screen content is centered at a maximum width of 720.

```dart
// lib/ui/theme.dart
ThemeData doerTheme(Brightness brightness);

// lib/ui/widgets.dart — all widgets also accept Key? key
PriorityBadge(GoalPriority priority, {bool compact = false});
SectionHeader(String title, {Widget? trailing});
EmptyState(IconData icon, String title, String message, {Widget? action});
SectionCard({required List<Widget> children});
Pill(String label, {IconData? icon, Color? color});
ContentWidth({required Widget child});
Notice(String message, {bool error = false});
String taskDuration(int minutes);
```

Agenda groups day tasks by goal, summarizes completion, and expands unscheduled
work in a needs-attention card. Done is optimistic for five seconds with Undo; completion becomes irreversible
when the snackbar closes or the app hides/pauses or Agenda disposes. `GoalEditScreen` exposes the existing decomposition flow
as “Plan tasks”, with sticky Save/Plan actions and archive/delete in its menu.

Settings saves each valid schedule change immediately, preserving the plan
calendar ID and reloading preferences. Invalid changes stay visible with an
inline error and do not overwrite the last valid preferences. Only timezone
saves show “Saved”. Calendar connections and ICS URL entry use a modal sheet;
missing server connection configuration is informational and keeps link/file
imports available. Provider settings retain their existing text and persistence
contract. Re-plan results show counts, coaching tips, moved times and unfinished
unscheduled tasks, with “Back to agenda” returning to the refreshed home screen.

Agenda places Re-plan beside its title and hides Re-plan
and the empty summary when no goals exist. Task cards retain time columns for
completed rows, with a trailing completion indicator; pending rows use the Done
icon button (tooltip `Done`); Didn't start appears once the start time passes,
and Missed? appears after the end time. Schedule values
share bodyLarge styling. Empty-state icons, the provider avatar and the Goals FAB
use secondaryContainer colors. Unconfigured connect options remain disabled with
`Not set up on this server` subtitles.

```dart
// lib/ui/onboarding_screen.dart
OnboardingScreen({Key? key, required AppServices services,
  required void Function(DateTime? day, String? message) onFinished});
// lib/ui/schedule_fields.dart
String? scheduleError(String start, String end, Set<String> days);
WorkHours({Key? key, required String start, required String end,
  bool enabled = true, required void Function(String, String) onChanged});
ActiveDays({Key? key, required Set<String> days, bool enabled = true,
  required ValueChanged<Set<String>> onChanged});
static const List<String> ActiveDays.week = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
static const List<String> ActiveDays.names = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
// lib/ui/calendar_connect.dart
Future<void> showCalendarConnect(BuildContext context, AppServices services,
  {bool notConfigured = false, bool initialLink = false});
Future<void> connectCalendar(BuildContext context, AppServices services, String app);
// lib/ui/provider_settings.dart
Future<void> openProviderSettings(BuildContext context, AppServices services,
  {bool ownKey = false});
// lib/ui/tab_location.dart (conditional web/native implementation)
void installTabRouting();
int readTab();
void writeTab(int tab);
void Function() listenTab(void Function(int) changed);
```
