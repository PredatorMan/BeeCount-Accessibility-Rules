import 'dart:io';

import 'rules_source.dart';

void main(List<String> arguments) {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.writeln(
      'Usage: dart run tool/build_rules.dart [--check] '
      '[--manifest manifest.json] [--output rules.json]',
    );
    return;
  }

  try {
    final pending = arguments.toList();
    final check = pending.remove('--check');
    final manifestPath = _option(pending, '--manifest') ?? 'manifest.json';
    final outputPath = _option(pending, '--output') ?? 'rules.json';
    if (pending.isNotEmpty) {
      throw ArgumentError('Unknown arguments: ${pending.join(' ')}');
    }

    final result = RulesSourceLoader().load(manifestPath: manifestPath);
    final generated = result.encode();
    final output = File(outputPath);
    if (check) {
      if (!output.existsSync() || output.readAsStringSync() != generated) {
        throw StateError(
          '$outputPath is out of date. Run: dart run tool/build_rules.dart',
        );
      }
      stdout.writeln(
        'Rules are up to date: ${result.appCount} apps / '
        '${result.pageRuleCount} page rules -> $outputPath',
      );
      return;
    }

    output.writeAsStringSync(generated);
    stdout.writeln(
      'Built ${result.appCount} apps / '
      '${result.pageRuleCount} page rules -> $outputPath',
    );
  } on Object catch (error) {
    stderr.writeln('Build failed: $error');
    exitCode = 1;
  }
}

String? _option(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index == -1) return null;
  if (index + 1 >= arguments.length) {
    throw ArgumentError('$name requires a value');
  }
  final value = arguments[index + 1];
  arguments.removeRange(index, index + 2);
  return value;
}
