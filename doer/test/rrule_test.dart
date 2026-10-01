import 'package:flutter_test/flutter_test.dart';

import 'package:doer/extraction/extraction.dart';

void main() {
  final service = ExtractionService();

  // Fixed base so DAILY/WEEKLY arithmetic is deterministic.
  String wrap(String event) => 'BEGIN:VCALENDAR\n$event\nEND:VCALENDAR';

  group('RRULE expansion', () {
    test('no RRULE: single occurrence passthrough', () {
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20260929T090000
DTEND:20260929T100000
SUMMARY:One-off
END:VEVENT'''), 'flat.ics');
      expect(blocks.length, 1);
      expect(blocks.first.start.year, 2026);
      expect(blocks.first.start.hour, 9);
      expect(blocks.first.end.hour, 10);
    });

    test('DAILY with COUNT expands exactly COUNT occurrences', () {
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20260929T090000
DTEND:20260929T093000
RRULE:FREQ=DAILY;COUNT=5
SUMMARY:Daily standup
END:VEVENT'''), 'daily.ics');
      expect(blocks.length, 5);
      expect(blocks.first.start.day, 29);
      // 29,30,Oct 1,Oct 2,Oct 3: month boundary, day-of-month resets.
      expect(blocks[1].start.day, 30);
      expect(blocks[2].start.day, 1);
      expect(blocks[3].start.day, 2);
      expect(blocks.last.start.day, 3);
      expect(blocks.last.start.month, 10);
      // Every occurrence keeps the original duration.
      for (final b in blocks) {
        expect(b.end.difference(b.start).inMinutes, 30);
      }
    });

    test('WEEKLY with INTERVAL=2 skips alternate weeks', () {
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20260928T140000
DTEND:20260928T150000
RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=3
SUMMARY:Biweekly 1:1
END:VEVENT'''), 'biweekly.ics');
      expect(blocks.length, 3);
      final days = blocks.map((b) => b.start.day).toList();
      // 09-28, 10-12, 10-26: fortnight stride.
      expect(days, [28, 12, 26]);
      for (final b in blocks) {
        expect(b.start.weekday, DateTime.monday);
      }
    });

    test('WEEKLY BYDAY expands to listed weekdays', () {
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20260928T080000
DTEND:20260928T084500
RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=4
SUMMARY:Gym
END:VEVENT'''), 'gym.ics');
      // Mon 28th + Wed 30th + Fri 2nd + Mon 5th = 4 occurrences.
      expect(blocks.length, 4);
      expect(blocks.map((b) => b.start.weekday).toList(),
          [DateTime.monday, DateTime.wednesday, DateTime.friday, DateTime.monday]);
      expect(blocks.first.start.day, 28);
      expect(blocks[1].start.day, 30);
      expect(blocks[2].start.day, 2);
      expect(blocks[3].start.day, 5);
    });

    test('mid-week dtStart with BYDAY never emits before dtStart and phases correctly', () {
      // DTSTART Wednesday 2026-09-30; BYDAY=MO,WE trap: the Monday of
      // week 1 (09-28) is BEFORE dtStart and must not emit.
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20260930T090000
DTEND:20260930T093000
RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4
SUMMARY:Midweek start
END:VEVENT'''), 'midweek.ics');
      expect(blocks.length, 4);
      // First occurrence must be dtStart itself (Wed 09-30), not Mon 09-28.
      expect(blocks.first.start.month, 9);
      expect(blocks.first.start.day, 30);
      // Then: Mon 10-05, Wed 10-07, Mon 10-12.
      expect(blocks[1].start.month, 10);
      expect(blocks[1].start.day, 5);
      expect(blocks[1].start.weekday, DateTime.monday);
      expect(blocks[2].start.day, 7);
      expect(blocks[2].start.weekday, DateTime.wednesday);
      expect(blocks[3].start.day, 12);
      // No occurrence ever precedes dtStart.
      for (final b in blocks) {
        expect(b.start.isAfter(DateTime(2026, 9, 29, 23, 59)), isTrue);
      }
    });

    test('WEEKLY BYDAY with UNTIL terminates and bounds correctly', () {
      // dtStart Mon 2026-09-28, BYDAY=MO,WE; UNTIL Wed 2026-10-07.
      // Expected: Mon 28, Wed 30, Mon 05, Wed 07 — then STOP.
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20260928T080000
DTEND:20260928T083000
RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261007T235959
SUMMARY:Bounded weekly
END:VEVENT'''), 'weekly-until.ics');
      expect(blocks.length, 4);
      expect(blocks.map((b) => b.start.day).toList(), [28, 30, 5, 7]);
      expect(blocks.map((b) => b.start.month).toList(), [9, 9, 10, 10]);
      // No occurrence past UNTIL.
      for (final b in blocks) {
        expect(b.start.isBefore(DateTime(2026, 10, 8)), isTrue);
      }
    });

    test('WEEKLY BYDAY with INTERVAL=2 phases from dtStart week', () {
      // dtStart Monday 09-28; BYDAY=MO,FR every 2 weeks, 4 occurrences:
      // Mon 28, Fri 02, Mon 12, Fri 16.
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20260928T070000
DTEND:20260928T074500
RRULE:FREQ=WEEKLY;BYDAY=MO,FR;INTERVAL=2;COUNT=4
SUMMARY:Biweekly phase
END:VEVENT'''), 'phase.ics');
      expect(blocks.length, 4);
      expect(blocks.map((b) => b.start.day).toList(), [28, 2, 12, 16]);
      expect(blocks.map((b) => b.start.month).toList(), [9, 10, 10, 10]);
    });

    test('UNTIL bounds expansion', () {
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20260929T100000
DTEND:20260929T110000
RRULE:FREQ=DAILY;UNTIL=20261002T100000
SUMMARY:Until-bound event
END:VEVENT'''), 'until.ics');
      // 29,30,1,2 — the 3rd would be past UNTIL.
      expect(blocks.length, 4);
      expect(blocks.last.start.day, 2);
    });

    test('MONTHLY keeps day-of-month across months', () {
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20260915T130000
DTEND:20260915T140000
RRULE:FREQ=MONTHLY;COUNT=3
SUMMARY:Monthly review
END:VEVENT'''), 'monthly.ics');
      expect(blocks.length, 3);
      expect(blocks.map((b) => b.start.month).toSet(), {9, 10, 11});
      for (final b in blocks) {
        expect(b.start.day, 15);
      }
    });

    test('unbounded rule hard-caps at maxOccurrences, never explodes', () {
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20200101T000000
DTEND:20200101T010000
RRULE:FREQ=DAILY
SUMMARY:Forever event
END:VEVENT'''), 'forever.ics');
      expect(blocks.length, lessThanOrEqualTo(366));
      expect(blocks.length, greaterThanOrEqualTo(1));
    });

    test('malformed RRULE falls back to single occurrence', () {
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20260929T090000
DTEND:20260929T100000
RRULE:GARBAGE
SUMMARY:Broken rule
END:VEVENT'''), 'broken.ics');
      expect(blocks.length, 1);
    });
  });

  group('multiple events with mixed recurrence', () {
    test('flat + recurring events coexist', () {
      final blocks = service.parseIcsContent(wrap('''
BEGIN:VEVENT
DTSTART:20260929T090000
DTEND:20260929T100000
SUMMARY:Flat
END:VEVENT
BEGIN:VEVENT
DTSTART:20260930T120000
DTEND:20260930T130000
RRULE:FREQ=DAILY;COUNT=2
SUMMARY:Recurring
END:VEVENT'''), 'mixed.ics');
      expect(blocks.length, 3); // 1 flat + 2 recurring
      final sources = blocks.map((b) => b.source).toSet();
      expect(sources, {'mixed.ics'});
    });
  });
}
