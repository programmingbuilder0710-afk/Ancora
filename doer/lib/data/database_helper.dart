import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/models.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal() : _memoryDb = false;

  /// Test constructor: fresh in-memory DB, isolated per instance.
  /// isSingleInstance: false => every openDatabase() gets its OWN private
  /// :memory: database (the factory otherwise pools by path, sharing one
  /// :memory: DB across all opens in the process). No files, hermetic.
  DatabaseHelper.forTest() : _memoryDb = true;

  final bool _memoryDb;
  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    if (_memoryDb) {
      return await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: sqflite.OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ),
      )..execute('''
      CREATE TABLE goals (
        id TEXT PRIMARY KEY,
        parent_goal_id TEXT REFERENCES goals(id),
        title TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        priority TEXT NOT NULL CHECK (priority IN ('P1','P2','P3')),
        target_date TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
        created_at TEXT NOT NULL
      )
      ''')..execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL REFERENCES goals(id),
        title TEXT NOT NULL,
        duration_minutes INTEGER NOT NULL,
        recommended_day TEXT,
        pinned_deadline TEXT,
        prerequisite_ids TEXT NOT NULL DEFAULT '[]',
        scheduled_start TEXT,
        scheduled_end TEXT,
        status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed','skipped')),
        adjusted INTEGER NOT NULL DEFAULT 0,
        skip_count INTEGER NOT NULL DEFAULT 0,
        device_event_id TEXT,
        created_at TEXT NOT NULL
      )
      ''')..execute('''
      CREATE TABLE documents (
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL REFERENCES goals(id),
        filename TEXT NOT NULL,
        extracted_text TEXT NOT NULL
      )
      ''')..execute('''
      CREATE TABLE busy_blocks (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        start TEXT NOT NULL,
        end TEXT NOT NULL
      )
      ''')..execute('''
      CREATE TABLE user_preferences (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        work_start TEXT NOT NULL,
        work_end TEXT NOT NULL,
        buffer_minutes INTEGER NOT NULL DEFAULT 10,
        active_days TEXT NOT NULL DEFAULT '["mon","tue","wed","thu","fri"]',
        timezone TEXT NOT NULL,
        plan_calendar_id TEXT
      )
      ''')..execute('''
      CREATE TABLE provider_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        mode TEXT NOT NULL DEFAULT 'demo' CHECK (mode IN ('demo','byok')),
        preset TEXT,
        base_url TEXT,
        model TEXT
      )
      ''');
    }
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'doer.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE goals (
        id TEXT PRIMARY KEY,
        parent_goal_id TEXT REFERENCES goals(id),
        title TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        priority TEXT NOT NULL CHECK (priority IN ('P1','P2','P3')),
        target_date TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL REFERENCES goals(id),
        title TEXT NOT NULL,
        duration_minutes INTEGER NOT NULL,
        recommended_day TEXT,
        pinned_deadline TEXT,
        prerequisite_ids TEXT NOT NULL DEFAULT '[]',
        scheduled_start TEXT,
        scheduled_end TEXT,
        status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed','skipped')),
        adjusted INTEGER NOT NULL DEFAULT 0,
        skip_count INTEGER NOT NULL DEFAULT 0,
        device_event_id TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE documents (
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL REFERENCES goals(id),
        filename TEXT NOT NULL,
        extracted_text TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE busy_blocks (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        start TEXT NOT NULL,
        end TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE user_preferences (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        work_start TEXT NOT NULL,
        work_end TEXT NOT NULL,
        buffer_minutes INTEGER NOT NULL DEFAULT 10,
        active_days TEXT NOT NULL DEFAULT '["mon","tue","wed","thu","fri"]',
        timezone TEXT NOT NULL,
        plan_calendar_id TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE provider_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        mode TEXT NOT NULL DEFAULT 'demo' CHECK (mode IN ('demo','byok')),
        preset TEXT,
        base_url TEXT,
        model TEXT
      )
    ''');

    await _createIndexes(db);
  }

  Future<void> _createIndexes(Database db) async {
    await db.execute('CREATE INDEX idx_tasks_goal_id ON tasks(goal_id)');
    await db.execute('CREATE INDEX idx_tasks_status ON tasks(status)');
    await db.execute('CREATE INDEX idx_tasks_scheduled_start ON tasks(scheduled_start)');
    await db.execute('CREATE INDEX idx_busy_blocks_start_end ON busy_blocks(start, end)');
    await db.execute('CREATE INDEX idx_goals_status ON goals(status)');
  }

  Future<void> close() async {
    final db = _database;
    if (db == null) return; // never opened: nothing to close
    _database = null;
    await db.close();
  }

  // --- Goal CRUD ---
  Future<int> insertGoal(Goal goal) async {
    final db = await database;
    return await db.insert('goals', goal.toMap());
  }

  Future<List<Goal>> getAllGoals({bool activeOnly = true}) async {
    final db = await database;
    final where = activeOnly ? "status = 'active'" : null;
    final maps = await db.query('goals', where: where, orderBy: 'priority, target_date');
    return maps.map(Goal.fromMap).toList();
  }

  Future<Goal?> getGoal(String id) async {
    final db = await database;
    final maps = await db.query('goals', where: 'id = ?', whereArgs: [id]);
    return maps.isEmpty ? null : Goal.fromMap(maps.first);
  }

  Future<int> updateGoal(Goal goal) async {
    final db = await database;
    return await db.update('goals', goal.toMap(), where: 'id = ?', whereArgs: [goal.id]);
  }

  /// Delete a goal and all dependent rows (tasks, documents) in one
  /// transaction. FK enforcement is ON; children must go first.
  Future<int> deleteGoal(String id) async {
    final db = await database;
    return await db.transaction((txn) async {
      await txn.delete('tasks', where: 'goal_id = ?', whereArgs: [id]);
      await txn.delete('documents', where: 'goal_id = ?', whereArgs: [id]);
      return await txn.delete('goals', where: 'id = ?', whereArgs: [id]);
    });
  }

  // --- Task CRUD ---
  Future<int> insertTask(Task task) async {
    final db = await database;
    return await db.insert('tasks', task.toMap());
  }

  Future<int> insertTasks(List<Task> tasks) async {
    final db = await database;
    final batch = db.batch();
    for (final task in tasks) {
      batch.insert('tasks', task.toMap());
    }
    await batch.commit(noResult: true);
    return tasks.length;
  }

  Future<List<Task>> getAllTasks() async {
    final db = await database;
    final maps = await db.query('tasks', orderBy: 'scheduled_start');
    return maps.map(Task.fromMap).toList();
  }

  Future<List<Task>> getTasksByGoal(String goalId) async {
    final db = await database;
    final maps = await db.query('tasks', where: 'goal_id = ?', whereArgs: [goalId], orderBy: 'scheduled_start');
    return maps.map(Task.fromMap).toList();
  }

  Future<List<Task>> getTasksByStatus(TaskStatus status) async {
    final db = await database;
    final maps = await db.query('tasks', where: 'status = ?', whereArgs: [status.name], orderBy: 'scheduled_start');
    return maps.map(Task.fromMap).toList();
  }

  Future<Task?> getTask(String id) async {
    final db = await database;
    final maps = await db.query('tasks', where: 'id = ?', whereArgs: [id]);
    return maps.isEmpty ? null : Task.fromMap(maps.first);
  }

  Future<int> updateTask(Task task) async {
    final db = await database;
    return await db.update('tasks', task.toMap(), where: 'id = ?', whereArgs: [task.id]);
  }

  Future<int> deleteTask(String id) async {
    final db = await database;
    return await db.delete('tasks', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteTasksByGoal(String goalId) async {
    final db = await database;
    return await db.delete('tasks', where: 'goal_id = ?', whereArgs: [goalId]);
  }

  Future<int> deleteUnplacedTasks() async {
    final db = await database;
    return await db.delete('tasks', where: 'scheduled_start IS NULL');
  }

  // --- Documents ---
  Future<int> insertDocument({
    required String id,
    required String goalId,
    required String filename,
    required String extractedText,
  }) async {
    final db = await database;
    return await db.insert('documents', {
      'id': id,
      'goal_id': goalId,
      'filename': filename,
      'extracted_text': extractedText,
    });
  }

  Future<List<Map<String, dynamic>>> getDocumentsByGoal(String goalId) async {
    final db = await database;
    return await db.query('documents', where: 'goal_id = ?', whereArgs: [goalId]);
  }

  // --- Busy Blocks ---
  Future<int> insertBusyBlock(BusyBlock block) async {
    final db = await database;
    return await db.insert('busy_blocks', block.toMap());
  }

  Future<int> insertBusyBlocks(List<BusyBlock> blocks) async {
    final db = await database;
    final batch = db.batch();
    for (final block in blocks) {
      batch.insert('busy_blocks', block.toMap());
    }
    await batch.commit(noResult: true);
    return blocks.length;
  }

  Future<List<BusyBlock>> getBusyBlocksInRange(DateTime start, DateTime end) async {
    final db = await database;
    final maps = await db.query(
      'busy_blocks',
      where: 'start < ? AND end > ?',
      whereArgs: [end.toIso8601String(), start.toIso8601String()],
    );
    return maps.map(BusyBlock.fromMap).toList();
  }

  Future<int> deleteBusyBlocksBySource(String source) async {
    final db = await database;
    return await db.delete('busy_blocks', where: 'source = ?', whereArgs: [source]);
  }

  Future<int> clearBusyBlocks() async {
    final db = await database;
    return await db.delete('busy_blocks');
  }

  // --- User Preferences ---
  Future<int> upsertPreferences(UserPreferences prefs) async {
    final db = await database;
    return await db.insert(
      'user_preferences',
      prefs.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<UserPreferences?> getPreferences() async {
    final db = await database;
    final maps = await db.query('user_preferences', limit: 1);
    return maps.isEmpty ? null : UserPreferences.fromMap(maps.first);
  }

  // --- Provider Config ---
  Future<int> upsertProviderConfig({
    required String mode,
    String? preset,
    String? baseUrl,
    String? model,
  }) async {
    final db = await database;
    return await db.insert(
      'provider_config',
      {
        'id': 1,
        'mode': mode,
        'preset': preset,
        'base_url': baseUrl,
        'model': model,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getProviderConfig() async {
    final db = await database;
    final maps = await db.query('provider_config', limit: 1);
    return maps.isEmpty ? null : maps.first;
  }
}
