import 'dart:io';

import 'snapshot_tools.dart';

void main(List<String> arguments) {
  if (arguments.isEmpty ||
      arguments.contains('--help') ||
      arguments.contains('-h')) {
    _usage();
    exitCode = arguments.isEmpty ? 64 : 0;
    return;
  }

  final zipPath = arguments.first;
  var outputPath = 'snapshots-local';
  for (var index = 1; index < arguments.length; index++) {
    if (arguments[index] == '--output' && index + 1 < arguments.length) {
      outputPath = arguments[++index];
    } else {
      stderr.writeln('Unknown or incomplete argument: ${arguments[index]}');
      _usage();
      exitCode = 64;
      return;
    }
  }

  try {
    final importer = GkdSnapshotImporter();
    final snapshot = importer.read(File(zipPath));
    final output = importer.write(snapshot, Directory(outputPath));
    stdout
        .writeln('Imported sanitized GKD snapshot to: ${output.absolute.path}');
    stdout.writeln('Nodes: ${snapshot.summary['nodeCount']}');
    stdout
        .writeln('Privacy findings: ${snapshot.privacyReport['findingCount']}');
    stdout.writeln('Review privacy-report.json before sharing any output.');
  } on Object catch (error) {
    stderr.writeln('Import failed: $error');
    exitCode = 1;
  }
}

void _usage() {
  stdout.writeln(
    'Usage: dart run tool/import_snapshot.dart <gkd-snapshot.zip> '
    '[--output snapshots-local]',
  );
}
