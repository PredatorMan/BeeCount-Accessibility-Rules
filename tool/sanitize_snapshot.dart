import 'dart:io';

import 'snapshot_tools.dart';

void main(List<String> arguments) {
  if (arguments.length < 2 ||
      arguments.contains('--help') ||
      arguments.contains('-h')) {
    _usage();
    exitCode =
        arguments.contains('--help') || arguments.contains('-h') ? 0 : 64;
    return;
  }

  File? report;
  for (var index = 2; index < arguments.length; index++) {
    if (arguments[index] == '--report' && index + 1 < arguments.length) {
      report = File(arguments[++index]);
    } else {
      stderr.writeln('Unknown or incomplete argument: ${arguments[index]}');
      _usage();
      exitCode = 64;
      return;
    }
  }

  try {
    writeSanitizedJson(File(arguments[0]), File(arguments[1]),
        reportFile: report);
    stdout.writeln(
        'Sanitized JSON written to: ${File(arguments[1]).absolute.path}');
    if (report != null)
      stdout.writeln('Privacy report written to: ${report.absolute.path}');
  } on Object catch (error) {
    stderr.writeln('Sanitization failed: $error');
    exitCode = 1;
  }
}

void _usage() {
  stdout.writeln(
    'Usage: dart run tool/sanitize_snapshot.dart <input.json> <output.json> '
    '[--report privacy-report.json]',
  );
}
