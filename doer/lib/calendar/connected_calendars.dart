import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../data/database_helper.dart';
import '../extraction/extraction.dart';
import '../models/models.dart';
import '../slotter/slotter.dart';
import 'plan_calendar.dart';

const apiBase = String.fromEnvironment('DOER_API_BASE');

class CalendarAccount {
  final String id;
  final String app;
  final String name;
  const CalendarAccount({
    required this.id,
    required this.app,
    required this.name,
  });
}

class ConnectedCalendars {
  final http.Client _client;
  final DatabaseHelper _db;
  final String _baseUrl;
  final _storage = const FlutterSecureStorage();
  Future<String>? _identity;

  ConnectedCalendars({
    required this._client,
    required this._db,
    this._baseUrl = apiBase,
  });

  Future<String?> readKey(String key) => _storage.read(key: key);
  Future<void> writeKey(String key, String? value) => value == null
      ? _storage.delete(key: key)
      : _storage.write(key: key, value: value);

  Future<String> userId() => _identity ??= _loadIdentity();
  Future<String> _loadIdentity() async {
    try {
      var id = await readKey('pd_external_user_id');
      if (id == null) {
        id = const Uuid().v4();
        await writeKey('pd_external_user_id', id);
      }
      return id;
    } catch (_) {
      _identity = null;
      rethrow;
    }
  }

  Uri _uri(String path, Map<String, String> query) =>
      (_baseUrl.isEmpty ? Uri.base : Uri.parse(_baseUrl))
          .resolve('/api/$path')
          .replace(queryParameters: query.isEmpty ? null : query);

  Future<http.Response> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String> query = const {},
  }) async {
    final user = await userId();
    final uri = _uri(path, method == 'POST' ? query : {...query, 'user': user});
    final request = http.Request(method, uri);
    if (method == 'POST') {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode({...?body, 'user': user});
    }
    late http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 60));
    } catch (_) {
      // ClientException can contain the bearer identity in its URL.
      throw Exception('Calendar network error — check your connection.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = 'Calendar request failed (${response.statusCode})';
      try {
        message =
            (jsonDecode(response.body) as Map)['error'] as String? ?? message;
      } catch (_) {}
      throw Exception(message);
    }
    return response;
  }

  Future<Uri> connectUrl(String app) async {
    final response = await _request(
      'connect-token',
      method: 'POST',
      body: {'app': app},
    );
    return Uri.parse(jsonDecode(response.body)['url'] as String);
  }

  Future<List<CalendarAccount>> accounts() async {
    final response = await _request('accounts');
    return (jsonDecode(response.body) as List)
        .map(
          (a) => CalendarAccount(
            id: a['id'] as String,
            app: a['app'] as String,
            name: a['name'] as String,
          ),
        )
        .toList();
  }

  Future<void> disconnect(String accountId) async {
    await _request(
      'accounts/${Uri.encodeComponent(accountId)}',
      method: 'DELETE',
    );
    if (await planAccountId() == accountId) await setPlanAccountId(null);
  }

  Future<List<String>> icsUrls() async =>
      (jsonDecode(await readKey('ics_subscriptions') ?? '[]') as List)
          .cast<String>();

  Future<String> _ics(String url) async =>
      (await _request('ics', query: {'url': url})).body;

  Future<void> addIcsUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !['https', 'webcal'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw Exception('Enter an HTTPS or webcal calendar link.');
    }
    final normalized = uri.replace(scheme: 'https').toString();
    final content = await _ics(normalized);
    if (!content.contains('BEGIN:VCALENDAR')) {
      throw Exception('Not an ICS calendar.');
    }
    final urls = await icsUrls();
    if (!urls.contains(normalized)) {
      await writeKey('ics_subscriptions', jsonEncode([...urls, normalized]));
    }
  }

  Future<void> removeIcsUrl(String url) async {
    final urls = await icsUrls()
      ..remove(url);
    await writeKey('ics_subscriptions', jsonEncode(urls));
    // ponytail: ICS sources are grouped by host; the next sync restores other subscriptions on that host.
    await _db.deleteBusyBlocksBySource('ics:${Uri.parse(url).host}');
  }

  Future<String?> planAccountId() => readKey('plan_account_id');
  Future<void> setPlanAccountId(String? id) => writeKey('plan_account_id', id);

  Future<String?> syncBusy(DatabaseHelper db) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = DateTime(now.year, now.month, now.day + 7);
    final blocks = <BusyBlock>[];
    final warnings = <String>[];
    var pdReached = false;
    var icsReached = false;
    final icsFailed = <String>{};
    try {
      final response = await _request(
        'busy',
        method: 'POST',
        body: {
          'start': start.toUtc().toIso8601String(),
          'end': end.toUtc().toIso8601String(),
        },
      );
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      for (final b in data['blocks'] as List) {
        blocks.add(
          BusyBlock(
            id: const Uuid().v4(),
            source: b['source'] as String,
            start: DateTime.parse(b['start'] as String).toLocal(),
            end: DateTime.parse(b['end'] as String).toLocal(),
          ),
        );
      }
      pdReached = true;
      if ((data['errors'] as List).isNotEmpty) {
        warnings.add('Some connected calendars could not sync.');
      }
    } catch (_) {
      warnings.add('Connected calendars could not sync.');
    }
    for (final url in await icsUrls()) {
      try {
        final content = await _ics(url);
        if (!content.contains('BEGIN:VCALENDAR')) {
          throw const FormatException('Invalid ICS');
        }
        final parsed = ExtractionService().parseIcsContent(
          content,
          'ics:${Uri.parse(url).host}',
        );
        blocks.addAll(
          parsed
              .map(
                (b) => BusyBlock(
                  id: b.id,
                  source: b.source,
                  start: b.start.toLocal(),
                  end: b.end.toLocal(),
                ),
              )
              .where((b) => b.start.isBefore(end) && b.end.isAfter(start)),
        );
        icsReached = true;
      } catch (_) {
        icsFailed.add('ics:${Uri.parse(url).host}');
        warnings.add('A calendar subscription could not sync.');
      }
    }
    if (!pdReached && !icsReached) {
      throw Exception('Calendars could not be reached. Try again later.');
    }
    // Replace in one transaction so a failed database write cannot erase the previous snapshot.
    // Only sources that synced are replaced; failed ones keep their last snapshot.
    final database = await db.database;
    await database.transaction((txn) async {
      if (pdReached) {
        await txn.delete('busy_blocks', where: "substr(source, 1, 3) = 'pd:'");
      }
      await txn.delete(
        'busy_blocks',
        where:
            "substr(source, 1, 4) = 'ics:' AND source NOT IN (${List.filled(icsFailed.length, '?').join(',')})",
        whereArgs: icsFailed.toList(),
      );
      for (final block in blocks) {
        await txn.insert('busy_blocks', block.toMap());
      }
    });
    return warnings.isEmpty ? null : warnings.toSet().join(' ');
  }

  Future<Map<String, dynamic>> _events(
    String account,
    List<String> deletes,
    List<Task> creates,
  ) async {
    final response = await _request(
      'plan-writes',
      method: 'POST',
      body: {
        'account_id': account,
        'delete': deletes,
        'create': [
          for (final task in creates)
            {
              'key': task.id,
              'title': task.title,
              'start': DateTime.parse(task.scheduledStart!)
                  .toUtc()
                  .toIso8601String(),
              'end': DateTime.parse(task.scheduledEnd!)
                  .toUtc()
                  .toIso8601String(),
            },
        ],
      },
    );
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

class PipedreamPlanCalendar implements PlanCalendar {
  final ConnectedCalendars connected;
  PipedreamPlanCalendar(this.connected);

  (String, String)? _deviceId(String id) {
    if (!id.startsWith('pd:')) return null;
    final split = id.indexOf(':', 3);
    return split <= 3 || split == id.length - 1
        ? null
        : (id.substring(3, split), id.substring(split + 1));
  }

  @override
  Future<Map<String, String>> atomicRewrite(
    List<PlacementResult> placementResults,
    Map<String, String> existingDeviceIds,
  ) async {
    final ids = <String, String>{};
    final deletes = <String, List<String>>{};
    final creates = <String, List<Task>>{};
    String? target;
    try {
      target = await connected.planAccountId();
    } catch (_) {
      return ids;
    }
    for (final result in placementResults) {
      final old = existingDeviceIds[result.task.id];
      final parts = old == null ? null : _deviceId(old);
      if (parts != null) (deletes[parts.$1] ??= []).add(parts.$2);
      if (target != null &&
          result.task.scheduledStart != null &&
          result.task.scheduledEnd != null) {
        (creates[target] ??= []).add(result.task);
      }
    }
    for (final account in {...deletes.keys, ...creates.keys}) {
      try {
        final result = await connected._events(
          account,
          deletes[account] ?? [],
          creates[account] ?? [],
        );
        final created = result['created'] as Map<String, dynamic>;
        for (final task in creates[account] ?? <Task>[]) {
          final id = created[task.id];
          if (id is String) ids[task.id] = 'pd:$account:$id';
        }
      } catch (_) {
        /* Calendar projection is best effort, as on Android. */
      }
    }
    return ids;
  }

  @override
  Future<String> writeTaskEvent(Task task) async {
    final target = await connected.planAccountId();
    if (target == null) throw Exception('Choose a plan calendar in Settings.');
    if (task.scheduledStart == null || task.scheduledEnd == null) {
      throw Exception('Task has no scheduled time');
    }
    final result = await connected._events(target, [], [task]);
    final id = (result['created'] as Map)[task.id];
    if (id is! String) throw Exception('Could not write calendar event.');
    return 'pd:$target:$id';
  }

  @override
  Future<void> deleteEvent(String deviceEventId) async {
    final parts = _deviceId(deviceEventId);
    if (parts == null) return;
    final result = await connected._events(parts.$1, [parts.$2], []);
    if ((result['errors'] as List).isNotEmpty) {
      throw Exception('Could not delete calendar event.');
    }
  }
}
