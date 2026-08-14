import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/rules_source.dart';

void main() {
  late Directory temporary;

  test('published rules match the split source files', () {
    final expected = File('rules.json').readAsStringSync();
    final result = RulesSourceLoader().load();

    expect(result.sourcePaths, [
      'apps/wechat/app.json',
      'apps/wechat/rules/bill_detail_expense.json',
      'apps/wechat/rules/bill_detail_income.json',
      'apps/wechat/rules/payment_result_expense.json',
      'apps/alipay/app.json',
      'apps/alipay/rules/historical_bill_expense.json',
      'apps/alipay/rules/historical_bill_income.json',
      'apps/alipay/rules/bill_detail_expense.json',
      'apps/alipay/rules/bill_detail_income.json',
      'apps/alipay/rules/payment_result_expense.json',
    ]);
    expect(result.appCount, 2);
    expect(result.pageRuleCount, 8);
    expect(result.encode(), expected);
    expect(expected, isNot(contains('"description":')));
    expect(expected, isNot(contains('"understanding"')));
    expect(expected, isNot(contains('"ruleSources"')));
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

  test('rejects a source file not listed by app metadata', () {
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
        {'id': 'listed', 'source': '../listed/app.json'},
      ],
    }));

    expect(
      () => RulesSourceLoader().load(
        manifestPath: '${temporary.path}/manifest.json',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects unsafe rule source paths', () {
    _writeApp(temporary, 'listed', 'com.example.listed');
    final appFile = File('${temporary.path}/apps/listed/app.json');
    final app = jsonDecode(appFile.readAsStringSync()) as Map;
    app['ruleSources'] = ['../listed_detail.json'];
    appFile.writeAsStringSync(jsonEncode(app));
    _writeManifest(temporary, ['listed']);

    expect(
      () => RulesSourceLoader().load(
        manifestPath: '${temporary.path}/manifest.json',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('requires human-readable understanding for every page rule', () {
    _writeApp(temporary, 'listed', 'com.example.listed');
    final ruleFile =
        File('${temporary.path}/apps/listed/rules/order_detail.json');
    final source = jsonDecode(ruleFile.readAsStringSync()) as Map;
    source['understanding'] = <Object?>[];
    ruleFile.writeAsStringSync(jsonEncode(source));
    _writeManifest(temporary, ['listed']);

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
      for (final id in ids) {'id': id, 'source': 'apps/$id/app.json'},
    ],
  }));
}

void _writeApp(Directory root, String id, String packageName) {
  final appDirectory = Directory('${root.path}/apps/$id')..createSync();
  final rulesDirectory = Directory('${appDirectory.path}/rules')..createSync();
  File('${appDirectory.path}/app.json').writeAsStringSync(jsonEncode({
    'id': id,
    'packageName': packageName,
    'displayName': id,
    'defaultEnabled': false,
    'activityIncludes': <Object?>[],
    'description': '$id test app',
    'ruleSources': ['rules/order_detail.json'],
  }));
  File('${rulesDirectory.path}/order_detail.json')
      .writeAsStringSync(jsonEncode({
    'description': '$id order detail',
    'understanding': ['Matches a completed order detail page.'],
    'rule': {
      'id': '${id}_detail',
      'transactionType': 'expense',
      'requiredAnchors': ['支付成功'],
      'anyAnchors': <Object?>[],
      'excludedAnchors': <Object?>[],
      'amount': {
        'regexes': [r'¥\s*([0-9]{1,7}(?:\.[0-9]{1,2})?)'],
      },
    },
  }));
}
