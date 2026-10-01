import 'package:doer/calendar/calendar_service.dart';
import 'package:doer/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CalendarService resolves UserPreferences.timezone at construction', () {
    final service = CalendarService(
      'calendar-id',
      preferences: UserPreferences(timezone: 'America/Los_Angeles'),
    );

    expect(service.timeZone.name, 'America/Los_Angeles');
    expect(service.resolvedTimezone, 'America/Los_Angeles');
    expect(service.timezoneWarning, isNull);
  });

  test('CalendarService defaults to UTC when preferences are omitted', () {
    final service = CalendarService('calendar-id');

    expect(service.timeZone.name, 'UTC');
    expect(service.resolvedTimezone, 'UTC');
    expect(service.timezoneWarning, isNull);
  });

  test('timezone resolution happens without initialize()', () {
    final service = CalendarService(
      'calendar-id',
      preferences: UserPreferences(timezone: 'Europe/Berlin'),
    );

    expect(service.timeZone.name, 'Europe/Berlin');
    expect(service.planCalendarId, 'calendar-id');
  });

  test('invalid timezone falls back to UTC with surfaced warning', () {
    final service = CalendarService(
      'calendar-id',
      preferences: UserPreferences(timezone: 'Not/A_Real_Zone'),
    );

    expect(service.timeZone.name, 'UTC');
    expect(service.resolvedTimezone, 'UTC');
    expect(service.timezoneWarning, contains('Not/A_Real_Zone'));
    expect(service.timezoneWarning, contains('UTC'));
  });

  test('empty timezone string falls back to UTC without warning', () {
    final service = CalendarService(
      'calendar-id',
      preferences: UserPreferences(timezone: ''),
    );

    expect(service.timeZone.name, 'UTC');
    expect(service.resolvedTimezone, 'UTC');
    expect(service.timezoneWarning, isNull);
  });
}
