import 'dart:convert';
import 'dart:io';

import 'rules_validator.dart';

class RulesSourceResult {
  const RulesSourceResult({
    required this.document,
    required this.sourcePaths,
  });

  final Map<String, Object?> document;
  final List<String> sourcePaths;

  int get appCount => (document['apps'] as List<Object?>).length;

  int get pageRuleCount => sourcePaths.length - appCount;

  String encode() =>
      '${const JsonEncoder.withIndent('  ').convert(document)}\n';
}

class RulesSourceLoader {
  RulesSourceResult load({String manifestPath = 'manifest.json'}) {
    final manifestFile = File(manifestPath).absolute;
    if (!manifestFile.existsSync()) {
      throw ArgumentError('Manifest does not exist: $manifestPath');
    }
    final rootDirectory = manifestFile.parent;
    final manifest = _object(
      jsonDecode(manifestFile.readAsStringSync()),
      r'$',
    );
    _onlyKeys(manifest, {'schemaVersion', 'rulesVersion', 'apps'}, r'$');
    final schemaVersion = _positiveInt(manifest, 'schemaVersion', r'$');
    final rulesVersion = _positiveInt(manifest, 'rulesVersion', r'$');
    final entries = _list(manifest, 'apps', r'$');
    if (entries.isEmpty) {
      throw const FormatException(r'$.apps must not be empty');
    }

    final appIds = <String>{};
    final sourcePaths = <String>[];
    final apps = <Object?>[];
    for (var index = 0; index < entries.length; index++) {
      final path = r'$.apps[' + index.toString() + ']';
      final entry = _object(entries[index], path);
      _onlyKeys(entry, {'id', 'source', 'description'}, path);
      final id = _text(entry, 'id', path);
      if (!appIds.add(id)) {
        throw FormatException('$path.id duplicate app id: $id');
      }
      if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(id)) {
        throw FormatException(
          '$path.id must use lowercase letters, digits, hyphens, or underscores',
        );
      }
      final source = _text(entry, 'source', path).replaceAll('\\', '/');
      final expectedSource = 'apps/$id/app.json';
      if (source != expectedSource) {
        throw FormatException(
          '$path.source must be $expectedSource',
        );
      }
      if (sourcePaths.contains(source)) {
        throw FormatException('$path.source duplicate source: $source');
      }
      if (entry.containsKey('description')) {
        _text(entry, 'description', path);
      }

      final appFile = File(
          '${rootDirectory.path}${Platform.pathSeparator}${source.replaceAll('/', Platform.pathSeparator)}');
      if (!appFile.existsSync()) {
        throw FormatException('$path.source does not exist: $source');
      }
      final appSource = _object(
        jsonDecode(appFile.readAsStringSync()),
        source,
      );
      _onlyKeys(
        appSource,
        {
          'id',
          'packageName',
          'displayName',
          'defaultEnabled',
          'activityIncludes',
          'pageCandidateAnchors',
          'description',
          'ruleSources',
        },
        source,
      );
      if (appSource['id'] != id) {
        throw FormatException(
          '$source.id must match manifest id "$id"',
        );
      }
      _text(appSource, 'description', source);
      final ruleEntries = _list(appSource, 'ruleSources', source);
      if (ruleEntries.isEmpty) {
        throw FormatException('$source.ruleSources must not be empty');
      }

      final appDirectory = appFile.parent;
      final ruleSourcePaths = <String>[];
      final rules = <Object?>[];
      for (var ruleIndex = 0; ruleIndex < ruleEntries.length; ruleIndex++) {
        final rulePath = '$source.ruleSources[$ruleIndex]';
        final relativeRuleSource = _validatedText(
          ruleEntries[ruleIndex],
          rulePath,
        ).replaceAll('\\', '/');
        if (!RegExp(r'^rules/[a-z0-9][a-z0-9_-]*\.json$')
            .hasMatch(relativeRuleSource)) {
          throw FormatException(
            '$rulePath must be a direct rules/*.json path using a safe name',
          );
        }
        final fullRuleSource = 'apps/$id/$relativeRuleSource';
        if (sourcePaths.contains(fullRuleSource) ||
            ruleSourcePaths.contains(fullRuleSource)) {
          throw FormatException(
              '$rulePath duplicate source: $relativeRuleSource');
        }
        final ruleFile = File(
          '${appDirectory.path}${Platform.pathSeparator}'
          '${relativeRuleSource.replaceAll('/', Platform.pathSeparator)}',
        );
        if (!ruleFile.existsSync()) {
          throw FormatException('$rulePath does not exist: $fullRuleSource');
        }
        final ruleSource = _object(
          jsonDecode(ruleFile.readAsStringSync()),
          fullRuleSource,
        );
        _onlyKeys(
          ruleSource,
          {'description', 'understanding', 'rule'},
          fullRuleSource,
        );
        _text(ruleSource, 'description', fullRuleSource);
        final understanding =
            _list(ruleSource, 'understanding', fullRuleSource);
        if (understanding.isEmpty) {
          throw FormatException(
            '$fullRuleSource.understanding must not be empty',
          );
        }
        for (var noteIndex = 0; noteIndex < understanding.length; noteIndex++) {
          _validatedText(
            understanding[noteIndex],
            '$fullRuleSource.understanding[$noteIndex]',
          );
        }
        rules.add(_object(ruleSource['rule'], '$fullRuleSource.rule'));
        ruleSourcePaths.add(fullRuleSource);
      }

      final app = <String, Object?>{
        'id': appSource['id'],
        'packageName': appSource['packageName'],
        'displayName': appSource['displayName'],
        'defaultEnabled': appSource['defaultEnabled'],
        'activityIncludes': appSource['activityIncludes'],
        if (appSource.containsKey('pageCandidateAnchors'))
          'pageCandidateAnchors': appSource['pageCandidateAnchors'],
        'rules': rules,
      };
      sourcePaths.add(source);
      sourcePaths.addAll(ruleSourcePaths);
      apps.add(app);
    }

    _rejectUnlistedSourceFiles(rootDirectory, sourcePaths);
    final document = <String, Object?>{
      'schemaVersion': schemaVersion,
      'rulesVersion': rulesVersion,
      'apps': apps,
    };
    RulesValidator().validate(document);
    return RulesSourceResult(document: document, sourcePaths: sourcePaths);
  }

  void _rejectUnlistedSourceFiles(Directory root, List<String> listed) {
    final appsDirectory = Directory(
      '${root.path}${Platform.pathSeparator}apps',
    );
    if (!appsDirectory.existsSync()) return;
    final actual = appsDirectory
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.json'))
        .map((file) {
      final relative = file.absolute.path
          .substring(root.absolute.path.length + 1)
          .replaceAll('\\', '/');
      return relative;
    }).toSet();
    final unlisted = actual.difference(listed.toSet()).toList()..sort();
    if (unlisted.isNotEmpty) {
      throw FormatException(
        'Source files are not referenced by app metadata: ${unlisted.join(', ')}',
      );
    }
  }

  Map<String, Object?> _object(Object? value, String path) {
    if (value is! Map) throw FormatException('$path must be an object');
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  List<Object?> _list(Map<String, Object?> value, String key, String path) {
    final result = value[key];
    if (result is! List) throw FormatException('$path.$key must be an array');
    return result.cast<Object?>();
  }

  int _positiveInt(Map<String, Object?> value, String key, String path) {
    final result = value[key];
    if (result is! int || result <= 0) {
      throw FormatException('$path.$key must be a positive integer');
    }
    return result;
  }

  String _text(Map<String, Object?> value, String key, String path) {
    return _validatedText(value[key], '$path.$key');
  }

  String _validatedText(Object? value, String path) {
    final result = value;
    if (result is! String || result.trim().isEmpty) {
      throw FormatException('$path must be a non-empty string');
    }
    return result.trim();
  }

  void _onlyKeys(
    Map<String, Object?> value,
    Set<String> allowed,
    String path,
  ) {
    final unknown = value.keys.where((key) => !allowed.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException('$path unknown keys: ${unknown.join(', ')}');
    }
  }
}
