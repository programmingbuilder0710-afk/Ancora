import 'dart:async';
import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/material.dart' show Color;
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import 'plan_calendar.dart';
import '../slotter/slotter.dart';

/// Implements the PlanCalendar interface so Orchestrator accepts it
/// interchangeably with the web PipedreamPlanCalendar.
class CalendarService implements PlanCalendar {
  final DeviceCalendarPlugin _deviceCalendarPlugin = DeviceCalendarPlugin();
  final String _calendarName = 'My Plan';
  String? _planCalendarId;

  CalendarService(this._planCalendarId, {this.preferences})
      : _resolvedTimezone = preferences?.timezone == null ||
              preferences!.timezone.isEmpty
          ? 'UTC'
          : preferences.timezone {
    tzdata.initializeTimeZones();
    try {
      _location = tz.getLocation(_resolvedTimezone);
      tz.setLocalLocation(_location);
    } on LocationNotFoundException catch (e) {
      _timezoneWarning = 'Invalid timezone "$_resolvedTimezone" from '
          'UserPreferences.timezone; falling back to UTC. ($e)';
      _resolvedTimezone = 'UTC';
      _location = tz.getLocation('UTC');
      tz.setLocalLocation(_location);
    }
  }
  final UserPreferences? preferences;
  String _resolvedTimezone;
  late final tz.Location _location;
  String? _timezoneWarning;
  String get resolvedTimezone => _resolvedTimezone;
  tz.Location get timeZone => _location;
  String? get timezoneWarning => _timezoneWarning;

  Future<void> initialize() async {
    final permissionsGranted = await _deviceCalendarPlugin.hasPermissions();
    if (permissionsGranted.isSuccess && !permissionsGranted.data!) {
      final requestResult = await _deviceCalendarPlugin.requestPermissions();
      if (!requestResult.isSuccess || !requestResult.data!) {
        throw Exception('Calendar permissions denied');
      }
    }

    final calendarsResult = await _deviceCalendarPlugin.retrieveCalendars();
    if (!calendarsResult.isSuccess || calendarsResult.data == null) {
      throw Exception('Failed to retrieve calendars: ${calendarsResult.errors}');
    }

    for (final calendar in calendarsResult.data!) {
      if (calendar.name == _calendarName) {
        _planCalendarId = calendar.id;
        return;
      }
    }

    final createResult = await _deviceCalendarPlugin.createCalendar(
      _calendarName,
      calendarColor: const Color(0xFF4CAF50),
      localAccountName: 'Doer',
    );
    final createdId = createResult.data;
    if (createdId == null) {
      throw Exception('Failed to create calendar: ${createResult.errors}');
    }
    _planCalendarId = createdId;
  }

  String get planCalendarId {
    final id = _planCalendarId;
    if (id == null) {
      throw Exception('Calendar not initialized. Call initialize() first.');
    }
    return id;
  }

  /// Read busy events from every device calendar EXCEPT "My Plan"
  /// (invariant: this app never treats its own plan as busy input to
  /// itself) in [start, end). All-day events expand to the full work
  /// window of each covered day (SPEC 7.2), matching the .ics handling
  /// in ExtractionService. Returns blocks ready for the busy_blocks
  /// table; the caller owns upserts.
  Future<List<BusyBlock>> readBusyBlocks(
    DateTime start,
    DateTime end, {
    required String workStart,
    required String workEnd,
  }) async {
    final calendarsResult = await _deviceCalendarPlugin.retrieveCalendars();
    if (!calendarsResult.isSuccess || calendarsResult.data == null) {
      throw Exception(
          'Failed to retrieve calendars: ${calendarsResult.errors}');
    }
    final blocks = <BusyBlock>[];
    final uuid = const Uuid();
    final startDay = DateTime(start.year, start.month, start.day);
    final endDay = DateTime(end.year, end.month, end.day);
    for (final calendar in calendarsResult.data!) {
      if (calendar.id == _planCalendarId ||
          calendar.name == _calendarName ||
          calendar.id == null) {
        continue;
      }
      final eventsResult = await _deviceCalendarPlugin.retrieveEvents(
        calendar.id,
        RetrieveEventsParams(startDate: start, endDate: end),
      );
      if (!eventsResult.isSuccess || eventsResult.data == null) continue;
      final source = 'device:${calendar.id}:${calendar.name ?? ''}';
      for (final event in eventsResult.data!) {
        final evStart = event.start;
        final evEnd = event.end;
        if (evStart == null || evEnd == null) continue;
        if (event.allDay == true) {
          // device_calendar (Android) shifts all-day events to midnight UTC
          // and subtracts a day from end — a 1-day event arrives with
          // start == end. Rebuild the true span from wall components:
          // evStart's Y/M/D is the first covered day; the last covered day
          // is evEnd's Y/M/D after re-adding the subtracted day.
          final firstDay = DateTime(evStart.year, evStart.month, evStart.day);
          var lastDay = DateTime(evEnd.year, evEnd.month, evEnd.day);
          if (!lastDay.isAfter(firstDay)) {
            lastDay = firstDay; // 1-day event collapsed by the plugin
          }
          final ws = _hhmmMinutes(workStart);
          final we = _hhmmMinutes(workEnd);
          var day = firstDay;
          while (!day.isAfter(lastDay)) {
            if (!day.isBefore(startDay) && !day.isAfter(endDay)) {
              blocks.add(BusyBlock(
                id: uuid.v4(),
                source: source,
                title: event.title,
                start: day.add(Duration(minutes: ws)),
                end: day.add(Duration(minutes: we)),
              ));
            }
            day = day.add(const Duration(days: 1));
          }
        } else {
          // device_calendar returns TZDateTime; normalize to naive local
          // wall time — every other busy_blocks producer (slotter, .ics
          // import) stores naive strings, and the slotter buckets by wall
          // components. An offset-suffixed value would shift evening
          // events into the next day's bucket.
          final s = DateTime(
              evStart.year, evStart.month, evStart.day, evStart.hour,
              evStart.minute, evStart.second);
          final e = DateTime(evEnd.year, evEnd.month, evEnd.day, evEnd.hour,
              evEnd.minute, evEnd.second);
          if (s.isBefore(end) && e.isAfter(start)) {
            // Clamp to the horizon: the slotter drops blocks whose start
            // day precedes it, so an in-progress event (trip started
            // yesterday) would otherwise be invisible and get double-
            // booked. Store the remainder inside the horizon.
            final clampedStart = s.isBefore(start) ? start : s;
            blocks.add(BusyBlock(
              id: uuid.v4(),
              source: source,
              title: event.title,
              start: clampedStart,
              end: e,
            ));
          }
        }
      }
    }
    return blocks;
  }

  /// All events currently in "My Plan" — used by the orphan reconcile and
  /// the external-edit import. Wide window: events can carry any
  /// (re)placed date, including past.
  Future<List<Event>> readPlanEvents(String calendarId) async {
    final now = DateTime.now();
    final result = await _deviceCalendarPlugin.retrieveEvents(
      calendarId,
      RetrieveEventsParams(
        startDate: now.subtract(const Duration(days: 366)),
        endDate: now.add(const Duration(days: 366)),
      ),
    );
    if (!result.isSuccess || result.data == null) {
      throw Exception('Failed to read plan events: ${result.errors}');
    }
    return result.data!;
  }

  static int _hhmmMinutes(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  @override
  Future<String> writeTaskEvent(Task task) async {
    if (task.scheduledStart == null || task.scheduledEnd == null) {
      throw Exception('Task has no scheduled time');
    }

    final start = DateTime.parse(task.scheduledStart!);
    final end = DateTime.parse(task.scheduledEnd!);
    final event = Event(
      planCalendarId,
      title: task.title,
      description: 'Goal: ${task.goalId}',
      start: TZDateTime.from(start, _location),
      end: TZDateTime.from(end, _location),
      allDay: false,
    );

    final result = await _deviceCalendarPlugin.createOrUpdateEvent(event);
    final eventId = result?.data;
    if (result == null || !result.isSuccess || eventId == null) {
      throw Exception('Failed to write event: ${result?.errors}');
    }
    return eventId;
  }

  @override
  Future<void> deleteEvent(String deviceEventId) async {
    final result = await _deviceCalendarPlugin.deleteEvent(planCalendarId, deviceEventId);
    if (!result.isSuccess) {
      throw Exception('Failed to delete event: ${result.errors}');
    }
  }

  @override
  Future<Map<String, String>> atomicRewrite(
    List<PlacementResult> placementResults,
    Map<String, String> existingDeviceIds,
  ) async {
    final newDeviceIds = <String, String>{};

    for (final result in placementResults) {
      final oldId = existingDeviceIds[result.task.id];
      if (oldId != null) {
        try {
          await deleteEvent(oldId);
        } catch (_) {}
      }
    }

    for (final result in placementResults) {
      final task = result.task;
      if (task.scheduledStart != null && task.scheduledEnd != null) {
        try {
          final newId = await writeTaskEvent(task);
          newDeviceIds[task.id] = newId;
        } catch (_) {}
      }
    }

    return newDeviceIds;
  }
}
