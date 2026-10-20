import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Native (Android/desktop) SQLite factory. FFI on the host platform:
/// isolate-based for production, so long queries never block the UI
/// isolate.
final platformDatabaseFactory = databaseFactoryFfi;
