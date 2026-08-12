import 'dart:convert';

class RulesValidationResult {
  const RulesValidationResult({
    required this.schemaVersion,
    required this.rulesVersion,
    required this.appCount,
    required this.pageRuleCount,
  });

  final int schemaVersion;
  final int rulesVersion;
  final int appCount;
  final int pageRuleCount;
}

class RulesValidator {
  static const _maxApps = 50;
  static const _maxRulesPerApp = 20;
  static const _maxListItems = 50;
  static const _maxTextLength = 300;
  static const _maxRegexLength = 500;
  static const _maxRegexesPerField = 10;
  static const _builtInPackages = {
    'com.tencent.mm',
    'com.eg.android.AlipayGphone',
  };
  static final _packagePattern = RegExp(r'^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$');
  static final _backReference = RegExp(r'(?<!\\)(?:\\\\)*\\[1-9]');
  static final _unboundedGroup = RegExp(r'\)(?:\*|\+|\{\d+,\})');
  static const _relations = {
    'any',
    'self',
    'child',
    'descendant',
    'sibling',
    'followingSibling',
    'following',
    'ancestor',
  };

  RulesValidationResult validate(Object? value) {
    final root = _object(value, r'$');
    _onlyKeys(root, {'schemaVersion', 'rulesVersion', 'apps'}, r'$');
    final schemaVersion = _positiveInt(root, 'schemaVersion', r'$');
    if (schemaVersion < 1 || schemaVersion > 2) {
      _fail(r'$.schemaVersion', 'must be 1 or 2');
    }
    final rulesVersion = _positiveInt(root, 'rulesVersion', r'$');
    final apps = _list(root, 'apps', r'$');
    if (apps.isEmpty || apps.length > _maxApps) {
      _fail(r'$.apps', 'must contain 1..$_maxApps items');
    }

    final appIds = <String>{};
    final packages = <String>{};
    var pageRuleCount = 0;
    for (var index = 0; index < apps.length; index++) {
      final app = _object(apps[index], r'$.apps[$index]');
      pageRuleCount += _validateApp(app, r'$.apps[$index]', appIds, packages);
    }
    return RulesValidationResult(
      schemaVersion: schemaVersion,
      rulesVersion: rulesVersion,
      appCount: apps.length,
      pageRuleCount: pageRuleCount,
    );
  }

  RulesValidationResult validateText(String source) {
    if (utf8.encode(source).length > 512 * 1024) {
      _fail(r'$', 'file exceeds BeeCount 512 KiB download limit');
    }
    final decoded = jsonDecode(source);
    return validate(decoded);
  }

  int _validateApp(
    Map<String, Object?> app,
    String path,
    Set<String> appIds,
    Set<String> packages,
  ) {
    _onlyKeys(
        app,
        {
          'id',
          'packageName',
          'displayName',
          'defaultEnabled',
          'activityIncludes',
          'rules',
        },
        path);
    final id = _text(app, 'id', path);
    if (!appIds.add(id)) _fail('$path.id', 'duplicate app id: $id');
    final packageName = _text(app, 'packageName', path);
    if (!_packagePattern.hasMatch(packageName)) {
      _fail('$path.packageName', 'invalid Android package name');
    }
    if (!packages.add(packageName)) {
      _fail('$path.packageName', 'duplicate packageName: $packageName');
    }
    _text(app, 'displayName', path);
    _optionalBoolean(app, 'defaultEnabled', path);
    if (!_builtInPackages.contains(packageName) &&
        app['defaultEnabled'] != false) {
      _fail(
        '$path.defaultEnabled',
        'new apps must explicitly default to false',
      );
    }
    _stringList(app, 'activityIncludes', path);
    final rules = _list(app, 'rules', path);
    if (rules.isEmpty || rules.length > _maxRulesPerApp) {
      _fail('$path.rules', 'must contain 1..$_maxRulesPerApp items');
    }
    final ruleIds = <String>{};
    for (var index = 0; index < rules.length; index++) {
      final rulePath = '$path.rules[$index]';
      final rule = _object(rules[index], rulePath);
      _validatePageRule(rule, rulePath, ruleIds);
    }
    return rules.length;
  }

  void _validatePageRule(
    Map<String, Object?> rule,
    String path,
    Set<String> ruleIds,
  ) {
    _onlyKeys(
        rule,
        {
          'id',
          'transactionType',
          'requiredAnchors',
          'anyAnchors',
          'excludedAnchors',
          'pageMatch',
          'scope',
          'amount',
          'merchant',
          'note',
          'paymentMethod',
          'transactionTime',
          'orderId',
        },
        path);
    final id = _text(rule, 'id', path);
    if (!ruleIds.add(id)) _fail('$path.id', 'duplicate rule id: $id');
    final type = _text(rule, 'transactionType', path);
    if (type != 'expense' && type != 'income') {
      _fail('$path.transactionType', 'must be expense or income');
    }
    final required = _stringList(rule, 'requiredAnchors', path);
    final any = _stringList(rule, 'anyAnchors', path);
    _stringList(rule, 'excludedAnchors', path);

    var pageAllCount = 0;
    var pageAnyCount = 0;
    if (rule['pageMatch'] != null) {
      final pageMatch = _object(rule['pageMatch'], '$path.pageMatch');
      _onlyKeys(pageMatch, {'all', 'any', 'none'}, '$path.pageMatch');
      pageAllCount = _selectorList(pageMatch, 'all', '$path.pageMatch').length;
      pageAnyCount = _selectorList(pageMatch, 'any', '$path.pageMatch').length;
      _selectorList(pageMatch, 'none', '$path.pageMatch');
    }
    if (required.isEmpty &&
        any.isEmpty &&
        pageAllCount == 0 &&
        pageAnyCount == 0) {
      _fail(path, 'needs anchors or pageMatch.all/pageMatch.any');
    }

    if (rule['scope'] != null) _validateScope(rule['scope'], '$path.scope');
    _validateAmount(_requiredObject(rule, 'amount', path), '$path.amount');
    for (final field in [
      'merchant',
      'note',
      'paymentMethod',
      'transactionTime',
      'orderId',
    ]) {
      if (rule[field] != null) {
        _validateField(_object(rule[field], '$path.$field'), '$path.$field');
      }
    }
  }

  void _validateScope(Object? value, String path) {
    final scope = _object(value, path);
    _onlyKeys(scope, {'selector', 'anchor', 'ancestorLevels'}, path);
    if (scope['selector'] == null && scope['anchor'] == null) {
      _fail(path, 'needs selector or anchor');
    }
    if (scope['selector'] != null)
      _selector(scope['selector'], '$path.selector');
    if (scope['anchor'] != null) _selector(scope['anchor'], '$path.anchor');
    final levels = _optionalInt(scope, 'ancestorLevels', path, 0);
    if (levels < 0 || levels > 20) {
      _fail('$path.ancestorLevels', 'must be in 0..20');
    }
  }

  void _validateAmount(Map<String, Object?> amount, String path) {
    _onlyKeys(
        amount,
        {
          'labels',
          'regexes',
          'currencyLabels',
          'standaloneRegex',
          'maxAnchorDistancePx',
          'maxCurrencyDistancePx',
          'node',
        },
        path);
    _stringList(amount, 'labels', path);
    final regexes = _stringList(amount, 'regexes', path);
    if (regexes.isEmpty || regexes.length > _maxRegexesPerField) {
      _fail('$path.regexes', 'must contain 1..$_maxRegexesPerField items');
    }
    for (final regex in regexes) _validateRegex(regex, '$path.regexes');
    _stringList(amount, 'currencyLabels', path);
    final standalone = _optionalText(amount, 'standaloneRegex', path);
    if (standalone != null && standalone.isNotEmpty) {
      _validateRegex(standalone, '$path.standaloneRegex');
    }
    final anchorDistance =
        _optionalInt(amount, 'maxAnchorDistancePx', path, 1800);
    if (anchorDistance < 100 || anchorDistance > 5000) {
      _fail('$path.maxAnchorDistancePx', 'must be in 100..5000');
    }
    final currencyDistance =
        _optionalInt(amount, 'maxCurrencyDistancePx', path, 300);
    if (currencyDistance < 20 || currencyDistance > 1000) {
      _fail('$path.maxCurrencyDistancePx', 'must be in 20..1000');
    }
    if (amount['node'] != null) {
      _validateRelativeNode(amount['node'], '$path.node');
    }
  }

  void _validateField(Map<String, Object?> field, String path) {
    _onlyKeys(
        field,
        {
          'labels',
          'regexes',
          'beforeAmountNodes',
          'afterAmountNodes',
          'fallbackToMerchant',
          'node',
        },
        path);
    _stringList(field, 'labels', path);
    final regexes = _stringList(field, 'regexes', path);
    if (regexes.length > _maxRegexesPerField) {
      _fail('$path.regexes', 'cannot exceed $_maxRegexesPerField items');
    }
    for (final regex in regexes) _validateRegex(regex, '$path.regexes');
    for (final key in ['beforeAmountNodes', 'afterAmountNodes']) {
      final count = _optionalInt(field, key, path, 0);
      if (count < 0 || count > 10) _fail('$path.$key', 'must be in 0..10');
    }
    _optionalBoolean(field, 'fallbackToMerchant', path);
    if (field['node'] != null) {
      _validateRelativeNode(field['node'], '$path.node');
    }
  }

  void _validateRelativeNode(Object? value, String path) {
    final node = _object(value, path);
    _onlyKeys(
        node, {'selector', 'relativeTo', 'relation', 'requireUnique'}, path);
    _selector(node['selector'], '$path.selector');
    final relation = _optionalText(node, 'relation', path) ?? 'any';
    if (!_relations.contains(relation)) {
      _fail('$path.relation', 'unsupported relation: $relation');
    }
    if (node['relativeTo'] != null) {
      _selector(node['relativeTo'], '$path.relativeTo');
    } else if (relation != 'any') {
      _fail('$path.relativeTo', 'is required for relation $relation');
    }
    _optionalBoolean(node, 'requireUnique', path);
  }

  List<Object?> _selectorList(
      Map<String, Object?> object, String key, String path) {
    final values = _listOrEmpty(object, key, path);
    if (values.length > _maxListItems) {
      _fail('$path.$key', 'cannot exceed $_maxListItems items');
    }
    for (var index = 0; index < values.length; index++) {
      _selector(values[index], '$path.$key[$index]');
    }
    return values;
  }

  void _selector(Object? value, String path) {
    final selector = _object(value, path);
    const keys = {
      'textEquals',
      'textContains',
      'textRegexes',
      'descriptionEquals',
      'descriptionContains',
      'descriptionRegexes',
      'viewIdEquals',
      'viewIdContains',
      'viewIdRegexes',
      'classNameEquals',
    };
    _onlyKeys(selector, keys, path);
    var itemCount = 0;
    for (final key in keys) {
      final values = _stringList(selector, key, path);
      itemCount += values.length;
      if (key.endsWith('Regexes')) {
        if (values.length > _maxRegexesPerField) {
          _fail('$path.$key', 'cannot exceed $_maxRegexesPerField items');
        }
        for (final regex in values) _validateRegex(regex, '$path.$key');
      }
    }
    if (itemCount == 0) _fail(path, 'selector cannot be empty');
  }

  void _validateRegex(String source, String path) {
    if (source.length > _maxRegexLength) _fail(path, 'regex is too long');
    if (_hasUnsafeGroup(source)) {
      _fail(path, 'lookarounds, flags, and special groups are unsupported');
    }
    if (_backReference.hasMatch(source)) {
      _fail(path, 'back references are unsupported');
    }
    if (_unboundedGroup.hasMatch(source)) {
      _fail(path, 'groups cannot use unbounded quantifiers');
    }
    RegExp regex;
    try {
      regex = RegExp(source);
    } on FormatException {
      _fail(path, 'invalid regular expression');
    }
    if (regex.hasMatch('')) _fail(path, 'regex cannot match empty text');
  }

  bool _hasUnsafeGroup(String source) {
    for (var index = 0; index + 2 < source.length; index++) {
      if (source[index] != '(' || source[index + 1] != '?') continue;
      if (source[index + 2] != ':') return true;
    }
    return false;
  }

  void _onlyKeys(Map<String, Object?> value, Set<String> keys, String path) {
    final unknown = value.keys.where((key) => !keys.contains(key)).toList();
    if (unknown.isNotEmpty) _fail(path, 'unknown keys: ${unknown.join(', ')}');
  }

  Map<String, Object?> _requiredObject(
      Map<String, Object?> object, String key, String path) {
    if (!object.containsKey(key)) _fail('$path.$key', 'is required');
    return _object(object[key], '$path.$key');
  }

  Map<String, Object?> _object(Object? value, String path) {
    if (value is! Map) _fail(path, 'must be an object');
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  List<Object?> _list(Map<String, Object?> value, String key, String path) {
    if (!value.containsKey(key)) _fail('$path.$key', 'is required');
    final result = value[key];
    if (result is! List) _fail('$path.$key', 'must be an array');
    return result.cast<Object?>();
  }

  List<Object?> _listOrEmpty(
      Map<String, Object?> value, String key, String path) {
    if (!value.containsKey(key)) return const [];
    final result = value[key];
    if (result is! List) _fail('$path.$key', 'must be an array');
    return result.cast<Object?>();
  }

  List<String> _stringList(
      Map<String, Object?> value, String key, String path) {
    final values = _listOrEmpty(value, key, path);
    if (values.length > _maxListItems) {
      _fail('$path.$key', 'cannot exceed $_maxListItems items');
    }
    return [
      for (var index = 0; index < values.length; index++)
        _validatedText(values[index], '$path.$key[$index]'),
    ];
  }

  String _text(Map<String, Object?> value, String key, String path) {
    if (!value.containsKey(key)) _fail('$path.$key', 'is required');
    return _validatedText(value[key], '$path.$key');
  }

  String? _optionalText(Map<String, Object?> value, String key, String path) {
    if (!value.containsKey(key) || value[key] == null) return null;
    return _validatedText(value[key], '$path.$key', allowEmpty: true);
  }

  String _validatedText(Object? value, String path, {bool allowEmpty = false}) {
    if (value is! String) _fail(path, 'must be a string');
    final result = value.trim();
    if ((!allowEmpty && result.isEmpty) || result.length > _maxTextLength) {
      _fail(path, 'must contain 1..$_maxTextLength characters');
    }
    return result;
  }

  int _positiveInt(Map<String, Object?> value, String key, String path) {
    final result = _requiredInt(value, key, path);
    if (result <= 0) _fail('$path.$key', 'must be positive');
    return result;
  }

  int _requiredInt(Map<String, Object?> value, String key, String path) {
    if (!value.containsKey(key)) _fail('$path.$key', 'is required');
    final result = value[key];
    if (result is! int) _fail('$path.$key', 'must be an integer');
    return result;
  }

  int _optionalInt(
      Map<String, Object?> value, String key, String path, int fallback) {
    return value.containsKey(key) ? _requiredInt(value, key, path) : fallback;
  }

  void _optionalBoolean(Map<String, Object?> value, String key, String path) {
    if (value.containsKey(key) && value[key] is! bool) {
      _fail('$path.$key', 'must be a boolean');
    }
  }

  Never _fail(String path, String message) {
    throw FormatException('$path $message');
  }
}
