import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// Web SQLite factory, in-page (no Worker at all): the wasm loads and runs
/// on the page itself. Some embedders (headless automation browsers,
/// Android WebView) construct Workers that never wire message ports,
/// leaving every DB call unanswered ("unsupported result null"); the
/// no-worker factory sidesteps the whole messaging channel. Production
/// browsers would also work with the default shared-worker factory — this
/// choice trades worker-thread isolation for universal embedder support.
final platformDatabaseFactory = databaseFactoryFfiWebNoWebWorker;
