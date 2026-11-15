import 'dart:io';

import 'package:danawallet/repositories/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// Device-path-shaped regression test for finding R10c: Android sqflite
/// rejects a comment-only statement with DatabaseException(not an error
/// (code 0 SQLITE_OK)), which killed onboarding on a fresh install. The
/// statement splitter must never emit a chunk whose executable content is
/// empty.
String _executableContent(String statement) =>
    statement.replaceAll(RegExp(r'--[^\n]*'), '').trim();

void main() {
  test('migration assets never split into comment-only statements (R10c)', () {
    final dir = Directory('assets/sql/migrations');
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty);
    for (final f in files) {
      final sql = f.readAsStringSync();
      final statements = splitSqlStatements(sql).toList();
      for (final stmt in statements) {
        expect(
          _executableContent(stmt),
          isNotEmpty,
          reason: '${f.path}: chunk is comment-only and would crash Android '
              'sqflite: "${stmt.substring(0, stmt.length.clamp(0, 80))}"',
        );
      }
    }
  });

  test('splitSqlStatements drops a leading comment block but keeps the DDL',
      () {
    const sql = '''
-- header comment
-- more comment
CREATE TABLE t (a INTEGER);
-- trailing comment
''';
    final statements = splitSqlStatements(sql).toList();
    expect(statements, hasLength(1));
    expect(statements.single, contains('CREATE TABLE t'));
  });
}
