import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

const String migrationsDirectory = "assets/sql/migrations";
const String dbFileName = "dana.db";

/// Splits a SQL migration script into executable statements (on ';'),
/// dropping chunks with no executable content (whitespace/comment-only).
/// Android sqflite rejects a comment-only statement ("not an error (code 0
/// SQLITE_OK)"), which crashed onboarding on device (finding R10c); the
/// sqflite_common_ffi used by the unit tests tolerates it, so the guard
/// must live in the splitter, not in the executor.
Iterable<String> splitSqlStatements(String sql) => sql
    .split(';')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty && _hasExecutableContent(s));

bool _hasExecutableContent(String statement) =>
    statement.replaceAll(RegExp(r'--[^\n]*'), '').trim().isNotEmpty;

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB(dbFileName);
    return _database!;
  }

// Usage
  Future<Database> _initDB(String filePath) async {
    final String dbPath = await _getDbPath();

    final path = join(dbPath, filePath);

    // read migration files from asset manifest
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final migrations = manifest
        .listAssets()
        .where((key) => key.startsWith(migrationsDirectory))
        .toList();

    // migrations must run in alphabetical order of their file names
    migrations.sort();

    // database version is the number of migrations
    final version = migrations.length;

    return await openDatabase(
      path,
      version: version,
      onUpgrade: (db, oldVersion, newVersion) =>
          _performMigrations(db, oldVersion, migrations),
      onConfigure: _onConfigure,
    );
  }

  Future<String> _getDbPath() async {
    if (Platform.isLinux) {
      String? home = Platform.environment['HOME'];
      if (home == null) {
        throw Exception("Home variable required on linux");
      }
      return "$home/.dana";
    } else {
      // on non-linux platforms, we use the default path provided by the sqflite package
      return await getDatabasesPath();
    }
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute("PRAGMA foreign_keys = ON");
  }

  Future _performMigrations(
      Database db, int currentVersion, List<String> migrations) async {
    Logger().i(
        "Performing database migration from $currentVersion to ${migrations.length}");

    while (currentVersion < migrations.length) {
      final migration = await rootBundle.loadString(migrations[currentVersion]);
      final statements = splitSqlStatements(migration);

      for (final statement in statements) {
        Logger().d(statement);
        await db.execute(statement);
      }
      currentVersion++;
    }
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
