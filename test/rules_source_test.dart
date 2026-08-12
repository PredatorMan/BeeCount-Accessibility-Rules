import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/rules_source.dart';

void main() {
  late Directory temporary;

  test('published rules match the split source files', () {
    final expected = File('rules.json').readAsStringSync();
    final result = RulesSourceLoader().load();

    expect(result.sourcePaths, ['apps/wechat.json', 'apps/alipay.json']);
    expect(result.encode(), expected);
  });

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('beecount-rules-source-');
    Directory('${temporary.path}/apps').createSync();
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  test('merges app sources in manifest order deterministically', () {
    _writeApp(temporary, 'second', 'com.example.second');
    _writeApp(temporary, 'first', 'com.example.first');
    _writeManifest(temporary, ['second', 'first']);

    final result = RulesSourceLoader().load(
      manifestPath: '${temporary.path}/manifest.json',
    );
    final apps = result.document['apps'] as List<Object?>;

    expect((apps[0] as Map)['id'], 'second');
    expect((apps[1] as Map)['id'], 'first');
    expect(result.encode(), endsWith('\n'));
    expect(result.encode(), result.encode());
  });

  test('rejects an app file not listed by the manifest', () {
    _writeApp(temporary, 'listed', 'com.example.listed');
    _writeApp(temporary, 'forgotten', 'com.example.forgotten');
    _writeManifest(temporary, ['listed']);

    expect(
      () => RulesSourceLoader().load(
        manifestPath: '${temporary.path}/manifest.json',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects unsafe source paths', () {
    _writeApp(temporary, 'listed', 'com.example.listed');
    File('${temporary.path}/manifest.json').writeAsStringSync(jsonEncode({
      'schemaVersion': 2,
      'rulesVersion': 1,
      'apps': [
        {'id': 'listed', 'source': '../listed.json'},
      ],
    }));

    expect(
      () => RulesSourceLoader().load(
        manifestPath: '${temporary.path}/manifest.json',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

void _writeManifest(Directory root, List<String> ids) {
  File('${root.path}/manifest.json').writeAsStringSync(jsonEncode({
    'schemaVersion': 2,
    'rulesVersion': 1,
    'apps': [
      for (final id in ids) {'id': id, 'source': 'apps/$id.json'},
    ],
  }));
}

void _writeApp(Directory root, String id, String packageName) {
  File('${root.path}/apps/$id.json').writeAsStringSync(jsonEncode({
    'id': id,
    'packageName': packageName,
    'displayName': id,
    'defaultEnabled': false,
    'activityIncludes': <Object?>[],
    'rules': [
      {
        'id': '${id}_detail',
        'transactionType': 'expense',
        'requiredAnchors': ['支付成功'],
        'anyAnchors': <Object?>[],
        'excludedAnchors': <Object?>[],
        'amount': {
          'regexes': [r'¥\s*([0-9]{1,7}(?:\.[0-9]{1,2})?)'],
        },
      },
    ],
  }));
}
