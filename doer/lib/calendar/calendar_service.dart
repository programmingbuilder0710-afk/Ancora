import 'dart:async';
import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/material.dart' show Color;
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../models/models.dart';
import '../slotter/slotter.dart';

class CalendarService {
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

  Future<void> deleteEvent(String deviceEventId) async {
    final result = await _deviceCalendarPlugin.deleteEvent(planCalendarId, deviceEventId);
    if (!result.isSuccess) {
      throw Exception('Failed to delete event: ${result.errors}');
    }
  }

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
