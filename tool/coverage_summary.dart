// Parses lcov.info and prints a coverage summary.
// Usage: dart run tool/coverage_summary.dart [coverage/lcov.info]

// ignore_for_file: avoid_print — CLI tool, print is the interface

import 'dart:io';

void main(List<String> args) {
  final path = args.isNotEmpty ? args[0] : 'coverage/lcov.info';
  final file = File(path);
  if (!file.existsSync()) {
    print('No coverage file at $path — run: flutter test --coverage');
    exit(1);
  }

  var totalLines = 0;
  var coveredLines = 0;
  String? currentFile;
  var fileTotal = 0;
  var fileCovered = 0;

  final stats = <String, (int covered, int total)>{};

  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      currentFile = line.substring(3);
      fileTotal = 0;
      fileCovered = 0;
    } else if (line.startsWith('DA:')) {
      final comma = line.indexOf(',', 3);
      final count = int.parse(line.substring(comma + 1));
      totalLines++;
      fileTotal++;
      if (count > 0) {
        coveredLines++;
        fileCovered++;
      }
    } else if (line == 'end_of_record' && currentFile != null) {
      if (fileTotal > 0) {
        stats[currentFile] = (fileCovered, fileTotal);
      }
      currentFile = null;
    }
  }

  final pct = totalLines > 0 ? (100.0 * coveredLines / totalLines) : 0.0;

  print('');
  print(
    'Coverage: $coveredLines / $totalLines lines '
    '(${pct.toStringAsFixed(1)}%)',
  );
  print('');

  // Filter out generated files for the per-file breakdown.
  final filtered = Map.fromEntries(
    stats.entries.where((e) => !e.key.endsWith('.g.dart')),
  );

  // Worst coverage first.
  final sorted =
      filtered.entries.toList()..sort((a, b) {
        final aPct = a.value.$1 / a.value.$2;
        final bPct = b.value.$1 / b.value.$2;
        return aPct.compareTo(bPct);
      });

  print('Lowest coverage (non-generated):');
  for (final e in sorted.take(15)) {
    final (cov, tot) = e.value;
    final p = (100.0 * cov / tot).toStringAsFixed(1).padLeft(5);
    final short = e.key.replaceFirst('lib/', '');
    print(
      '  $p%  ${cov.toString().padLeft(4)}/${tot.toString().padRight(4)}'
      '  $short',
    );
  }

  print('');
  print('Best coverage:');
  for (final e in sorted.reversed.take(5)) {
    final (cov, tot) = e.value;
    final p = (100.0 * cov / tot).toStringAsFixed(1).padLeft(5);
    final short = e.key.replaceFirst('lib/', '');
    print(
      '  $p%  ${cov.toString().padLeft(4)}/${tot.toString().padRight(4)}'
      '  $short',
    );
  }
  print('');
}
