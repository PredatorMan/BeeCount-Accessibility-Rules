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

  test('Alipay historical bills do not depend on success status text', () {
    final published = jsonDecode(File('rules.json').readAsStringSync()) as Map;
    final apps = published['apps'] as List;
    final alipay = apps.cast<Map>().singleWhere((app) => app['id'] == 'alipay');
    final rules = (alipay['rules'] as List).cast<Map>();
    final expense = rules.singleWhere(
      (rule) => rule['id'] == 'alipay_historical_bill_expense_v3',
    );
    final income = rules.singleWhere(
      (rule) => rule['id'] == 'alipay_historical_bill_income_v3',
    );

    expect(
        rules.indexOf(expense),
        lessThan(rules.indexWhere(
          (rule) => rule['id'] == 'alipay_bill_detail_expense_v2',
        )));
    expect(
        rules.indexOf(income),
        lessThan(rules.indexWhere(
          (rule) => rule['id'] == 'alipay_bill_detail_income_v2',
        )));
    expect(expense['requiredAnchors'], contains('账单详情'));
    expect(expense['anyAnchors'], contains('支付时间'));
    expect(income['requiredAnchors'], contains('账单详情'));
    expect(income['anyAnchors'], contains('收款时间'));

    final expenseRegexes =
        ((expense['amount'] as Map)['regexes'] as List).cast<String>();
    final incomeRegexes =
        ((income['amount'] as Map)['regexes'] as List).cast<String>();
    expect(expenseRegexes, hasLength(1));
    expect(incomeRegexes, hasLength(1));
    expect(RegExp(expenseRegexes.single).hasMatch('支出134.8元'), isTrue);
    expect(RegExp(expenseRegexes.single).hasMatch('收入134.8元'), isFalse);
    expect(RegExp(incomeRegexes.single).hasMatch('收入39.5元'), isTrue);
    expect(RegExp(incomeRegexes.single).hasMatch('支出39.5元'), isFalse);

    for (final rule in [expense, income]) {
      final excluded = (rule['excludedAnchors'] as List).cast<String>();
      expect(
          excluded,
          containsAll([
            '待支付',
            '交易失败',
            '已取消',
            '交易关闭',
            '退款成功',
          ]));
      expect(excluded, isNot(contains('等待确认收货')));
      expect(rule['anyAnchors'], isNot(contains('交易成功')));
    }
    for (final rule in rules) {
      final excluded = (rule['excludedAnchors'] as List).cast<String>();
      expect(excluded, contains('等待付款'));
      expect(excluded, contains('退款中'));
      expect(excluded, isNot(contains('等待确认收货')));
    }

    final expensePage = ['账单详情', '支出134.8元', '等待确认收货', '支付时间'];
    final incomePage = ['账单详情', '收入39.5元', '交易时间', '交易号'];
    expect(_matchesLegacyPageRule(expense, expensePage), isTrue);
    expect(_matchesLegacyPageRule(income, incomePage), isTrue);
    expect(_matchesLegacyPageRule(expense, incomePage), isFalse);
    expect(_matchesLegacyPageRule(income, expensePage), isFalse);
    expect(
      _matchesLegacyPageRule(
        expense,
        ['账单详情', '支出134.8元', '等待确认收货', '付款方式'],
      ),
      isTrue,
    );

    for (final unsafe in ['支付失败', '等待付款', '待支付', '交易关闭', '退款中']) {
      expect(
        _matchesLegacyPageRule(expense, [...expensePage, unsafe]),
        isFalse,
        reason: 'historical expense rule must reject $unsafe',
      );
    }
    expect(
      _matchesLegacyPageRule(expense, ['账单详情', '支出134.8元']),
      isFalse,
      reason:
          'a detail title plus amount without a reliable field is insufficient',
    );
    expect(
      _matchesLegacyPageRule(expense, ['账单列表', '支出134.8元', '支付时间']),
      isFalse,
      reason: 'a bill list must not match the detail rule',
    );
    expect(
      _firstMatchingRule(rules, expensePage)?['id'],
      'alipay_historical_bill_expense_v3',
    );
    expect(
      _firstMatchingRule(rules, [...expensePage, '交易成功', '退款中']),
      isNull,
      reason: 'an unsafe state must not fall through into a legacy rule',
    );
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

bool _matchesLegacyPageRule(Map rule, List<String> texts) {
  final required = (rule['requiredAnchors'] as List).cast<String>();
  final any = (rule['anyAnchors'] as List).cast<String>();
  final excluded = (rule['excludedAnchors'] as List).cast<String>();
  final regexes = ((rule['amount'] as Map)['regexes'] as List)
      .cast<String>()
      .map(RegExp.new);
  return required
          .every((anchor) => texts.any((text) => text.contains(anchor))) &&
      (any.isEmpty ||
          any.any((anchor) => texts.any((text) => text.contains(anchor)))) &&
      excluded
          .every((anchor) => texts.every((text) => !text.contains(anchor))) &&
      texts.any((text) => regexes.any((regex) => regex.hasMatch(text)));
}

Map? _firstMatchingRule(List<Map> rules, List<String> texts) {
  for (final rule in rules) {
    if (_matchesLegacyPageRule(rule, texts)) return rule;
  }
  return null;
}
