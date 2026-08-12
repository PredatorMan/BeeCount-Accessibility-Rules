import 'dart:io';

import 'rules_validator.dart';

void main(List<String> arguments) {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.writeln('Usage: dart run tool/validate_rules.dart [rules.json]');
    return;
  }
  if (arguments.length > 1) {
    stderr.writeln('Usage: dart run tool/validate_rules.dart [rules.json]');
    exitCode = 64;
    return;
  }
  final path = arguments.isEmpty ? 'rules.json' : arguments.single;
  try {
    final file = File(path);
    if (!file.existsSync()) {
      throw ArgumentError('Rules file does not exist: $path');
    }
    final result = RulesValidator().validateText(file.readAsStringSync());
    stdout.writeln(
      'Valid rules: schemaVersion=${result.schemaVersion}, '
      'rulesVersion=${result.rulesVersion}, apps=${result.appCount}, '
      'pageRules=${result.pageRuleCount}',
    );
  } on Object catch (error) {
    stderr.writeln('Invalid rules: $error');
    exitCode = 1;
  }
}
