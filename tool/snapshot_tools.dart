import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const _redactedAddress = '[REDACTED_ADDRESS]';

class PrivacyFinding {
  PrivacyFinding(this.category, this.path, this.replacement);

  final String category;
  final String path;
  final String replacement;

  Map<String, Object> toJson() => {
        'category': category,
        'path': path,
        'replacement': replacement,
      };
}

class SanitizationResult {
  SanitizationResult(this.value, this.findings);

  final Object? value;
  final List<PrivacyFinding> findings;
}

class SnapshotSanitizer {
  final List<PrivacyFinding> _findings = [];

  SanitizationResult sanitize(Object? value) {
    _findings.clear();
    final sanitized = _sanitizeValue(value, r'$');
    return SanitizationResult(sanitized, List.unmodifiable(_findings));
  }

  Object? _sanitizeValue(Object? value, String path) {
    if (value is Map) {
      return value.map<String, Object?>((key, child) {
        final name = key.toString();
        if (child is String &&
            path.contains('.attr') &&
            const {'id', 'vid', 'name'}.contains(name)) {
          return MapEntry(name, child);
        }
        return MapEntry(name, _sanitizeValue(child, '$path.$name'));
      });
    }
    if (value is List) {
      return [
        for (var index = 0; index < value.length; index++)
          _sanitizeValue(value[index], '$path[$index]'),
      ];
    }
    if (value is String) {
      return _sanitizeString(value, path);
    }
    return value;
  }

  String _sanitizeString(String source, String path) {
    var value = source;

    value = _replace(
      value,
      RegExp(r'(?<![\w.])[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}(?!\w)'),
      '[REDACTED_EMAIL]',
      'email',
      path,
    );
    value = _replace(
      value,
      RegExp(r'(?<!\d)1[3-9]\d{9}(?!\d)'),
      '[REDACTED_PHONE]',
      'phone',
      path,
    );
    value = _replace(
      value,
      RegExp(r'(?:收货人|联系人|姓名)[:：\s]*[\u4e00-\u9fff·]{2,8}'),
      '姓名：[REDACTED_NAME]',
      'person_name',
      path,
    );
    value = _replace(
      value,
      RegExp(r'(?<!\d)\d{17}[\dXx](?!\d)'),
      '[REDACTED_ID]',
      'government_id',
      path,
    );
    value = _replace(
      value,
      RegExp(
        r'(?:银行卡号?|信用卡号?|借记卡号?|卡号)[:：\s]*(?:\d[ -]?){12,19}(?!\d)',
      ),
      '卡号：[REDACTED_CARD]',
      'payment_card',
      path,
    );
    value = _replace(
      value,
      RegExp(
        r'(?:订单号|交易号|流水号|账号|用户ID|账户ID|支付单号|商户单号)'
        r'[:：\s]*[A-Za-z0-9_-]{6,}',
        caseSensitive: false,
      ),
      '标识：[REDACTED_IDENTIFIER]',
      'order_or_account_id',
      path,
    );
    value = _replace(
      value,
      RegExp(r'(?<!\d)\d{8,}(?!\d)'),
      '[REDACTED_IDENTIFIER]',
      'order_or_account_id',
      path,
    );

    final addressPattern = RegExp(
      r'(?:收货地址|配送地址|详细地址|地址)[:：\s]*[^,，;；\n]{4,}'
      r'|(?:[^,，;；\n]{0,16}(?:省|自治区|特别行政区))?'
      r'[^,，;；\n]{1,12}(?:市|自治州)'
      r'[^,，;；\n]{1,12}(?:区|县)'
      r'[^,，;；\n]{1,30}(?:路|街|道|巷|号|栋|室)[^,，;；\n]{0,20}',
    );
    value = _replace(
      value,
      addressPattern,
      _redactedAddress,
      'address',
      path,
    );

    return value;
  }

  String _replace(
    String value,
    RegExp pattern,
    String replacement,
    String category,
    String path,
  ) {
    final matches = pattern.allMatches(value).length;
    if (matches == 0) return value;
    for (var index = 0; index < matches; index++) {
      _findings.add(PrivacyFinding(category, path, replacement));
    }
    return value.replaceAll(pattern, replacement);
  }
}

class ImportedSnapshot {
  ImportedSnapshot({
    required this.summary,
    required this.nodes,
    required this.privacyReport,
    this.screenshot,
    this.screenshotExtension,
  });

  final Map<String, Object?> summary;
  final List<Object?> nodes;
  final Map<String, Object?> privacyReport;
  final Uint8List? screenshot;
  final String? screenshotExtension;
}

class GkdSnapshotImporter {
  ImportedSnapshot read(File zipFile) {
    if (!zipFile.existsSync()) {
      throw ArgumentError('Snapshot ZIP does not exist: ${zipFile.path}');
    }

    final archive = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());
    final jsonFiles = archive.files
        .where(
            (file) => file.isFile && file.name.toLowerCase().endsWith('.json'))
        .toList();
    if (jsonFiles.length != 1) {
      throw FormatException(
        'Expected exactly one JSON file in the GKD ZIP, found ${jsonFiles.length}.',
      );
    }

    final raw = _contentBytes(jsonFiles.single);
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map) {
      throw const FormatException('GKD snapshot JSON root must be an object.');
    }
    final snapshot = Map<String, Object?>.from(decoded);
    final rawNodes = snapshot['nodes'];
    if (rawNodes is! List) {
      throw const FormatException(
          'GKD snapshot JSON must contain a nodes array.');
    }

    final sanitizer = SnapshotSanitizer();
    final sanitizedResult = sanitizer.sanitize(rawNodes);
    final sanitizedNodes = List<Object?>.from(sanitizedResult.value! as List);
    _validateRelationships(sanitizedNodes);

    final appInfo = snapshot['appInfo'] is Map
        ? Map<String, Object?>.from(snapshot['appInfo']! as Map)
        : <String, Object?>{};
    final snapshotId = snapshot['id']?.toString() ??
        jsonFiles.single.name.split('/').last.replaceAll('.json', '');
    final image = _findScreenshot(archive, jsonFiles.single.name);

    final counts = <String, int>{};
    for (final finding in sanitizedResult.findings) {
      counts.update(finding.category, (count) => count + 1, ifAbsent: () => 1);
    }

    return ImportedSnapshot(
      summary: {
        'formatVersion': 1,
        'snapshotId': snapshotId,
        'packageName': snapshot['appId'] ?? appInfo['id'],
        'activity': snapshot['activityId'],
        'app': {
          'name': appInfo['name'],
          'versionName': appInfo['versionName'],
          'versionCode': appInfo['versionCode'],
        },
        'screen': {
          'width': snapshot['screenWidth'],
          'height': snapshot['screenHeight'],
          'isLandscape': snapshot['isLandscape'],
        },
        'nodeCount': sanitizedNodes.length,
        'rootNodeIds': [
          for (final node in sanitizedNodes)
            if (node is Map && node['pid'] == -1) node['id'],
        ],
        'screenshot': image == null ? null : 'screenshot.${image.$2}',
        'source': 'GKD snapshot ZIP (sanitized during import)',
      },
      nodes: sanitizedNodes,
      privacyReport: {
        'formatVersion': 1,
        'safeToCommit': false,
        'findingCount': sanitizedResult.findings.length,
        'countsByCategory': counts,
        'findings':
            sanitizedResult.findings.map((item) => item.toJson()).toList(),
        'notice': image == null
            ? 'Review sanitized text manually before sharing. Imported workspaces are excluded from Git.'
            : 'Screenshots cannot be reliably auto-redacted. Treat the screenshot as private and do not commit it.',
      },
      screenshot: image?.$1,
      screenshotExtension: image?.$2,
    );
  }

  Directory write(ImportedSnapshot snapshot, Directory outputRoot) {
    final snapshotId = snapshot.summary['snapshotId'].toString();
    final safeId = snapshotId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final directory =
        Directory('${outputRoot.path}${Platform.pathSeparator}$safeId');
    directory.createSync(recursive: true);

    _writeJson(File('${directory.path}${Platform.pathSeparator}summary.json'),
        snapshot.summary);
    _writeJson(File('${directory.path}${Platform.pathSeparator}nodes.json'),
        snapshot.nodes);
    _writeJson(
      File('${directory.path}${Platform.pathSeparator}privacy-report.json'),
      snapshot.privacyReport,
    );
    if (snapshot.screenshot != null && snapshot.screenshotExtension != null) {
      File(
        '${directory.path}${Platform.pathSeparator}screenshot.${snapshot.screenshotExtension}',
      ).writeAsBytesSync(snapshot.screenshot!, flush: true);
    }
    return directory;
  }

  void _validateRelationships(List<Object?> nodes) {
    final ids = <Object?>{};
    for (final node in nodes) {
      if (node is! Map || !node.containsKey('id') || !node.containsKey('pid')) {
        throw const FormatException('Every GKD node must contain id and pid.');
      }
      if (!ids.add(node['id'])) {
        throw FormatException('Duplicate GKD node id: ${node['id']}');
      }
    }
    for (final node in nodes.cast<Map>()) {
      if (node['pid'] != -1 && !ids.contains(node['pid'])) {
        throw FormatException(
          'Node ${node['id']} references missing parent ${node['pid']}.',
        );
      }
    }
  }

  (Uint8List, String)? _findScreenshot(Archive archive, String jsonName) {
    final jsonBase = jsonName.substring(0, jsonName.length - 5).toLowerCase();
    final images = archive.files.where((file) {
      final name = file.name.toLowerCase();
      return file.isFile &&
          (name.endsWith('.png') ||
              name.endsWith('.jpg') ||
              name.endsWith('.jpeg'));
    }).toList();
    if (images.isEmpty) return null;
    final image = images.firstWhere(
      (file) => file.name.toLowerCase().startsWith(jsonBase),
      orElse: () => images.first,
    );
    final extension = image.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
    return (_contentBytes(image), extension);
  }

  Uint8List _contentBytes(ArchiveFile file) {
    final content = file.content;
    if (content is Uint8List) return content;
    return Uint8List.fromList(List<int>.from(content as Iterable));
  }
}

void writeSanitizedJson(File input, File output, {File? reportFile}) {
  final decoded = jsonDecode(input.readAsStringSync());
  final result = SnapshotSanitizer().sanitize(decoded);
  _writeJson(output, result.value);

  if (reportFile != null) {
    final counts = <String, int>{};
    for (final finding in result.findings) {
      counts.update(finding.category, (count) => count + 1, ifAbsent: () => 1);
    }
    _writeJson(reportFile, {
      'findingCount': result.findings.length,
      'countsByCategory': counts,
      'findings': result.findings.map((item) => item.toJson()).toList(),
    });
  }
}

void _writeJson(File file, Object? value) {
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(value)}\n');
}
