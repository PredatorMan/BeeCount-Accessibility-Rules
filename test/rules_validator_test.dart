import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/rules_validator.dart';

void main() {
  test('validates the published rules file', () {
    final rules = jsonDecode(File('rules.json').readAsStringSync());
    final result = RulesValidator().validate(rules);

    expect(result.appCount, greaterThan(0));
    expect(result.pageRuleCount, greaterThan(0));
  });

  test('accepts schema v2 selectors and relative extraction', () {
    final rules = _minimalRules();
    final rule = ((rules['apps'] as List).first as Map)['rules'].first as Map;
    rule['requiredAnchors'] = <Object?>[];
    rule['pageMatch'] = {
      'all': [
        {
          'textContains': ['订单详情'],
          'viewIdEquals': ['com.example.shop:id/title'],
        },
      ],
      'none': [
        {
          'textContains': ['等待付款'],
        },
      ],
    };
    (rule['amount'] as Map)['node'] = {
      'selector': {
        'textRegexes': [r'^¥\s*([0-9]{1,7}(?:\.[0-9]{1,2})?)$'],
      },
      'relativeTo': {
        'textEquals': ['实付款'],
      },
      'relation': 'following',
      'requireUnique': true,
    };

    expect(() => RulesValidator().validate(rules), returnsNormally);
  });

  test('rejects a non-unique package', () {
    final rules = _minimalRules();
    (rules['apps'] as List).add(
      Map<String, Object?>.from((rules['apps'] as List).first as Map),
    );

    expect(
      () => RulesValidator().validate(rules),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects unsafe regular expressions', () {
    final rules = _minimalRules();
    final rule = ((rules['apps'] as List).first as Map)['rules'].first as Map;
    (rule['amount'] as Map)['regexes'] = [r'(?=¥)([0-9]+)'];

    expect(
      () => RulesValidator().validate(rules),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a new app that defaults to enabled', () {
    final rules = _minimalRules();
    ((rules['apps'] as List).first as Map)['defaultEnabled'] = true;

    expect(
      () => RulesValidator().validate(rules),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a file larger than the BeeCount download limit', () {
    expect(
      () => RulesValidator().validateText(' ' * (512 * 1024 + 1)),
      throwsA(isA<FormatException>()),
    );
  });
}

Map<String, Object?> _minimalRules() =>
    Map<String, Object?>.from(jsonDecode(jsonEncode({
      'schemaVersion': 2,
      'rulesVersion': 1,
      'apps': [
        {
          'id': 'example',
          'packageName': 'com.example.shop',
          'displayName': 'Example',
          'defaultEnabled': false,
          'activityIncludes': <Object?>[],
          'rules': [
            {
              'id': 'example_order_detail',
              'transactionType': 'expense',
              'requiredAnchors': ['订单详情'],
              'anyAnchors': <Object?>[],
              'excludedAnchors': ['等待付款'],
              'amount': {
                'regexes': [r'¥\s*([0-9]{1,7}(?:\.[0-9]{1,2})?)'],
              },
            },
          ],
        },
      ],
    })) as Map);
