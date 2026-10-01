import 'dart:convert';

// ignore: constant_identifier_names
enum GoalPriority { P1, P2, P3 }
enum GoalStatus { active, archived }
enum TaskStatus { pending, completed, skipped }

class Goal {
  final String id;
  final String? parentGoalId;
  final String title;
  final String description;
  final GoalPriority priority;
  final String targetDate; // ISO 8601 YYYY-MM-DD
  final GoalStatus status;
  final String createdAt;

  Goal({
    required this.id,
    this.parentGoalId,
    required this.title,
    this.description = '',
    required this.priority,
    required this.targetDate,
    this.status = GoalStatus.active,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'parent_goal_id': parentGoalId,
    'title': title,
    'description': description,
    'priority': priority.name,
    'target_date': targetDate,
    'status': status.name,
    'created_at': createdAt,
  };

  factory Goal.fromMap(Map<String, dynamic> map) => Goal(
    id: map['id'],
    parentGoalId: map['parent_goal_id'],
    title: map['title'],
    description: map['description'] ?? '',
    priority: GoalPriority.values.byName(map['priority']),
    targetDate: map['target_date'],
    status: GoalStatus.values.byName(map['status']),
    createdAt: map['created_at'],
  );
}

class Task {
  final String id;
  final String goalId;
  final String title;
  final int durationMinutes;
  final String? recommendedDay; // ISO 8601 YYYY-MM-DD
  final String? pinnedDeadline; // ISO 8601 YYYY-MM-DD
  final List<String> prerequisiteIds;
  final String? scheduledStart; // ISO 8601 local datetime
  final String? scheduledEnd;
  final TaskStatus status;
  final bool adjusted;
  final int skipCount;
  final String? deviceEventId;
  final String createdAt;

  Task({
    required this.id,
    required this.goalId,
    required this.title,
    required this.durationMinutes,
    this.recommendedDay,
    this.pinnedDeadline,
    this.prerequisiteIds = const [],
    this.scheduledStart,
    this.scheduledEnd,
    this.status = TaskStatus.pending,
    this.adjusted = false,
    this.skipCount = 0,
    this.deviceEventId,
    required this.createdAt,
  });

  Task copyWith({
    String? id,
    String? goalId,
    String? title,
    int? durationMinutes,
    String? recommendedDay,
    String? pinnedDeadline,
    List<String>? prerequisiteIds,
    String? scheduledStart,
    String? scheduledEnd,
    TaskStatus? status,
    bool? adjusted,
    int? skipCount,
    String? deviceEventId,
    String? createdAt,
    bool clearSchedule = false,
    bool clearDeviceEventId = false,
    bool clearPinnedDeadline = false,
  }) => Task(
    id: id ?? this.id,
    goalId: goalId ?? this.goalId,
    title: title ?? this.title,
    durationMinutes: durationMinutes ?? this.durationMinutes,
    recommendedDay: recommendedDay ?? this.recommendedDay,
    pinnedDeadline: clearPinnedDeadline ? null : (pinnedDeadline ?? this.pinnedDeadline),
    prerequisiteIds: prerequisiteIds ?? this.prerequisiteIds,
    scheduledStart: clearSchedule ? null : (scheduledStart ?? this.scheduledStart),
    scheduledEnd: clearSchedule ? null : (scheduledEnd ?? this.scheduledEnd),
    status: status ?? this.status,
    adjusted: adjusted ?? this.adjusted,
    skipCount: skipCount ?? this.skipCount,
    deviceEventId: clearDeviceEventId ? null : (deviceEventId ?? this.deviceEventId),
    createdAt: createdAt ?? this.createdAt,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'goal_id': goalId,
    'title': title,
    'duration_minutes': durationMinutes,
    'recommended_day': recommendedDay,
    'pinned_deadline': pinnedDeadline,
    'prerequisite_ids': jsonEncode(prerequisiteIds),
    'scheduled_start': scheduledStart,
    'scheduled_end': scheduledEnd,
    'status': status.name,
    'adjusted': adjusted ? 1 : 0,
    'skip_count': skipCount,
    'device_event_id': deviceEventId,
    'created_at': createdAt,
  };

  factory Task.fromMap(Map<String, dynamic> map) => Task(
    id: map['id'],
    goalId: map['goal_id'],
    title: map['title'],
    durationMinutes: map['duration_minutes'],
    recommendedDay: map['recommended_day'],
    pinnedDeadline: map['pinned_deadline'],
    prerequisiteIds: (jsonDecode(map['prerequisite_ids'] ?? '[]') as List).map((e) => e.toString()).toList(),
    scheduledStart: map['scheduled_start'],
    scheduledEnd: map['scheduled_end'],
    status: TaskStatus.values.byName(map['status']),
    adjusted: (map['adjusted'] ?? 0) == 1,
    skipCount: map['skip_count'] ?? 0,
    deviceEventId: map['device_event_id'],
    createdAt: map['created_at'],
  );
}

class BusyBlock {
  final String id;
  final String source;
  final DateTime start;
  final DateTime end;

  BusyBlock({
    required this.id,
    required this.source,
    required this.start,
    required this.end,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'source': source,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
  };

  factory BusyBlock.fromMap(Map<String, dynamic> map) => BusyBlock(
    id: map['id'],
    source: map['source'],
    start: DateTime.parse(map['start']),
    end: DateTime.parse(map['end']),
  );
}

class UserPreferences {
  final String workStart; // 'HH:mm'
  final String workEnd;
  final int bufferMinutes;
  final List<String> activeDays; // ['mon', 'tue', ...]
  final String timezone;
  final String? planCalendarId;

  UserPreferences({
    this.workStart = '09:00',
    this.workEnd = '18:00',
    this.bufferMinutes = 10,
    this.activeDays = const ['mon', 'tue', 'wed', 'thu', 'fri'],
    required this.timezone,
    this.planCalendarId,
  });

  Map<String, dynamic> toMap() => {
    'id': 1,
    'work_start': workStart,
    'work_end': workEnd,
    'buffer_minutes': bufferMinutes,
    'active_days': jsonEncode(activeDays),
    'timezone': timezone,
    'plan_calendar_id': planCalendarId,
  };

  factory UserPreferences.fromMap(Map<String, dynamic> map) => UserPreferences(
    workStart: map['work_start'] ?? '09:00',
    workEnd: map['work_end'] ?? '18:00',
    bufferMinutes: map['buffer_minutes'] ?? 10,
    activeDays: (jsonDecode(map['active_days'] ?? '[]') as List).map((e) => e.toString()).toList(),
    timezone: map['timezone'] ?? 'UTC',
    planCalendarId: map['plan_calendar_id'],
  );
}
