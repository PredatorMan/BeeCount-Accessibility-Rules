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
      final source = _text(entry, 'source', path).replaceAll('\\', '/');
      if (!RegExp(r'^apps/[a-z0-9][a-z0-9_-]*\.json$').hasMatch(source)) {
        throw FormatException(
          '$path.source must be a direct apps/*.json path using a safe name',
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
      final app = _object(
        jsonDecode(appFile.readAsStringSync()),
        source,
      );
      if (app['id'] != id) {
        throw FormatException(
          '$source.id must match manifest id "$id"',
        );
      }
      sourcePaths.add(source);
      apps.add(app);
    }

    _rejectUnlistedAppFiles(rootDirectory, sourcePaths);
    final document = <String, Object?>{
      'schemaVersion': schemaVersion,
      'rulesVersion': rulesVersion,
      'apps': apps,
    };
    RulesValidator().validate(document);
    return RulesSourceResult(document: document, sourcePaths: sourcePaths);
  }

  void _rejectUnlistedAppFiles(Directory root, List<String> listed) {
    final appsDirectory = Directory(
      '${root.path}${Platform.pathSeparator}apps',
    );
    if (!appsDirectory.existsSync()) return;
    final actual = appsDirectory
        .listSync(followLinks: false)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.json'))
        .map((file) => 'apps/${file.uri.pathSegments.last}')
        .toSet();
    final unlisted = actual.difference(listed.toSet()).toList()..sort();
    if (unlisted.isNotEmpty) {
      throw FormatException(
        'App source files are missing from manifest.json: ${unlisted.join(', ')}',
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
    final result = value[key];
    if (result is! String || result.trim().isEmpty) {
      throw FormatException('$path.$key must be a non-empty string');
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
