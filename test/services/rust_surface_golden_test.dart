// B2.7 golden manifest test: the Rust-bridge surface the Flutter side may
// invoke is FROZEN. The flutter_rust_bridge generated API (every callable the
// generated bindings expose, keyed by their `debugName`) must match the
// checked-in manifest `test/services/rust_surface_golden.json` exactly.
//
// Any addition to the Rust surface (a new exported function, method, getter or
// auto-accessor) changes this set and FAILS the test, naming the unexpected
// item — surface growth must be a deliberate, reviewed manifest update
// (BEHAVIOR.md §11 B2.7).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // flutter test runs with the package root as the working directory.
  final generatedFile = File('lib/generated/rust/frb_generated.dart');
  final manifestFile = File('test/services/rust_surface_golden.json');

  /// Every callable the generated bridge exposes, keyed by FRB's `debugName`.
  Set<String> extractLiveSurface(String generatedSource) {
    final pattern = RegExp(r'debugName: "([^"]+)"');
    return pattern.allMatches(generatedSource).map((m) => m.group(1)!).toSet();
  }

  test(
    'B2.7: the Rust bridge surface matches the golden manifest exactly',
    () {
      expect(generatedFile.existsSync(), isTrue,
          reason: 'lib/generated/rust/frb_generated.dart not found — the '
              'generated bridge source of truth is missing');
      final live = extractLiveSurface(generatedFile.readAsStringSync());
      expect(live, isNotEmpty,
          reason: 'no debugName entries found in frb_generated.dart — '
              'the surface extractor is broken');

      expect(manifestFile.existsSync(), isTrue,
          reason: 'test/services/rust_surface_golden.json not found — the '
              'B2.7 golden manifest is missing');
      final manifest =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      final expected = (manifest['entries'] as List).cast<String>().toSet();

      final unexpected = (live.difference(expected).toList()..sort());
      final missing = (expected.difference(live).toList()..sort());

      if (unexpected.isNotEmpty || missing.isNotEmpty) {
        final problems = <String>[
          if (unexpected.isNotEmpty)
            'UNEXPECTED Rust surface (not in the B2.7 manifest) — the Rust '
                'surface grew. If this growth is intended and reviewed, add '
                'the entries to test/services/rust_surface_golden.json '
                'deliberately:\n  ${unexpected.join('\n  ')}',
          if (missing.isNotEmpty)
            'MANIFEST ENTRIES with no live surface (stale manifest):\n  '
                '${missing.join('\n  ')}',
        ];
        fail(problems.join('\n\n'));
      }
    },
  );
}
