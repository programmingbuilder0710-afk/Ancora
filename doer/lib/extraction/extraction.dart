import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import '../models/models.dart';

class ExtractionService {
  static const int maxCharsPerDoc = 5000;

  Future<String> extractText(File file) async {
    final extension = file.path.split('.').last.toLowerCase();

    if (extension == 'txt' || extension == 'md') {
      final raw = await file.readAsString();
      return _truncate(raw);
    }

    if (extension == 'pdf' || extension == 'docx') {
      try {
        final bytes = await file.readAsBytes();
        final raw = utf8.decode(bytes, allowMalformed: true);
        final printable = raw.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), ' ');
        return _truncate(printable);
      } catch (_) {
        return '';
      }
    }

    return '';
  }

  String _truncate(String text) {
    if (text.length <= maxCharsPerDoc) {
      return text;
    }
    return '${text.substring(0, maxCharsPerDoc)}\n...[truncated]';
  }

  List<BusyBlock> parseIcsContent(String content, String sourceName) {
    final blocks = <BusyBlock>[];
    final lines = content.split(RegExp(r'\r?\n'));
    final uuid = const Uuid();

    bool inEvent = false;
    DateTime? dtStart;
    DateTime? dtEnd;
    String? rrule;

    for (var line in lines) {
      line = line.trim();

      if (line == 'BEGIN:VEVENT') {
        inEvent = true;
        dtStart = null;
        dtEnd = null;
        rrule = null;
        continue;
      }

      if (line == 'END:VEVENT') {
        if (inEvent && dtStart != null) {
          final end = dtEnd ?? dtStart.add(const Duration(hours: 1));
          if (end.isAfter(dtStart)) {
            final occurrences =
                rrule != null ? _expandRrule(rrule, dtStart, end) : [dtStart];
            for (final occ in occurrences) {
              final occEnd = occ.add(end.difference(dtStart));
              if (occEnd.isAfter(occ)) {
                blocks.add(BusyBlock(
                  id: uuid.v4(),
                  source: sourceName,
                  start: occ,
                  end: occEnd,
                ));
              }
            }
          }
        }
        inEvent = false;
        continue;
      }

      if (!inEvent) continue;

      if (line.startsWith('DTSTART')) {
        dtStart = _parseIcsDateTime(line);
      } else if (line.startsWith('DTEND')) {
        dtEnd = _parseIcsDateTime(line);
      } else if (line.startsWith('RRULE')) {
        rrule = _unfoldRrule(line);
      }
    }

    return blocks;
  }

  /// Unfold RRULE value, tolerating line continuations already joined.
  String? _unfoldRrule(String line) {
    final parts = line.split(':');
    if (parts.length < 2) return null;
    return parts.sublist(1).join(':').trim();
  }

  /// Bounded RRULE expansion (SPEC 7.2): DAILY / WEEKLY / MONTHLY with
  /// INTERVAL, COUNT, UNTIL, and WEEKLY BYDAY. Expansion stops at the
  /// later of COUNT occurrences or UNTIL, hard-capped to [maxOccurrences]
  /// to keep unbounded rules from exploding storage.
  static const int maxOccurrences = 366;

  List<DateTime> _expandRrule(String rrule, DateTime dtStart, DateTime dtEnd) {
    final parts = <String, String>{};
    for (final seg in rrule.split(';')) {
      if (seg.trim().isEmpty) continue;
      final kv = seg.split('=');
      if (kv.length != 2) continue;
      parts[kv[0].trim().toUpperCase()] = kv[1].trim();
    }

    final freq = parts['FREQ']?.toUpperCase();
    if (freq == null) return [dtStart];
    final interval = int.tryParse(parts['INTERVAL'] ?? '1') ?? 1;
    if (interval < 1) return [dtStart];

    DateTime? until;
    if (parts['UNTIL'] != null) {
      until = _parseIcsDateTime('UNTIL:${parts['UNTIL']}');
    }
    final count = int.tryParse(parts['COUNT'] ?? '');

    final byDay = <int>{}; // Dart weekdays: 1=Mon … 7=Sun
    if (parts['BYDAY'] != null && freq == 'WEEKLY') {
      const dayMap = {
        'MO': 1, 'TU': 2, 'WE': 3, 'THU': 4, 'FR': 5, 'SA': 6, 'SU': 7,
      };
      for (final token in parts['BYDAY']!.split(',')) {
        final code = token.trim().toUpperCase();
        final day = dayMap[code];
        if (day != null) byDay.add(day);
      }
    }

    final occurrences = <DateTime>[];
    var current = dtStart;
    var emitted = 0;

    while (true) {
      if (freq == 'WEEKLY' && byDay.isNotEmpty) {
        // Phase weeks from dtStart's own week (Monday of that week), so
        // mid-week starts never emit days before dtStart and INTERVAL
        // phasing is anchored correctly.
        final weekStartMonday = dtStart.subtract(Duration(days: dtStart.weekday - 1));
        final sortedDays = byDay.toList()..sort();
        var week = 0;

        while (emitted < (count ?? maxOccurrences) && emitted < maxOccurrences) {
          final base = weekStartMonday.add(Duration(days: 7 * interval * week));
          // Once the whole week is past UNTIL, no later week can qualify —
          // terminates instead of spinning on skipped candidates.
          if (until != null && base.isAfter(until)) break;
          for (final weekday in sortedDays) {
            if (emitted >= (count ?? maxOccurrences) || emitted >= maxOccurrences) break;
            final candidate = base.add(Duration(days: weekday - 1));
            if (candidate.isBefore(dtStart)) continue; // never before dtStart
            if (until != null && candidate.isAfter(until)) continue;
            occurrences.add(candidate);
            emitted++;
          }
          week++;
        }
        break;
      }

      if (until != null && current.isAfter(until)) break;
      occurrences.add(current);
      emitted++;
      if (count != null && emitted >= count) break;
      if (emitted >= maxOccurrences) break;

      switch (freq) {
        case 'DAILY':
          current = current.add(Duration(days: interval));
          break;
        case 'WEEKLY':
          current = current.add(Duration(days: 7 * interval));
          break;
        case 'MONTHLY':
          current = DateTime(current.year, current.month + interval, current.day,
              current.hour, current.minute, current.second);
          break;
        default:
          return occurrences.isEmpty ? [dtStart] : occurrences;
      }
    }

    return occurrences.isEmpty ? [dtStart] : occurrences;
  }

  DateTime? _parseIcsDateTime(String line) {
    final parts = line.split(':');
    if (parts.length < 2) return null;
    final value = parts.sublist(1).join(':').trim();

    try {
      if (value.length == 8 && RegExp(r'^\d{8}$').hasMatch(value)) {
        final y = int.parse(value.substring(0, 4));
        final m = int.parse(value.substring(4, 6));
        final d = int.parse(value.substring(6, 8));
        return DateTime(y, m, d, 0, 0);
      }

      final normalized = value.replaceAll('Z', '');
      if (normalized.length >= 15 && normalized.contains('T')) {
        final datePart = normalized.substring(0, 8);
        final timePart = normalized.substring(9, 15);

        final y = int.parse(datePart.substring(0, 4));
        final m = int.parse(datePart.substring(4, 6));
        final d = int.parse(datePart.substring(6, 8));

        final h = int.parse(timePart.substring(0, 2));
        final min = int.parse(timePart.substring(2, 4));
        final s = int.parse(timePart.substring(4, 6));

        if (value.endsWith('Z')) {
          return DateTime.utc(y, m, d, h, min, s).toLocal();
        }
        return DateTime(y, m, d, h, min, s);
      }
    } catch (_) {}

    return null;
  }
}
