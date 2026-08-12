import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

import '../tool/snapshot_tools.dart';

void main() {
  group('SnapshotSanitizer', () {
    test('redacts sensitive node text while keeping normal amounts', () {
      final result = SnapshotSanitizer().sanitize({
        'text': '订单号 123456789012345，手机 13812345678，金额 ¥12.34',
        'desc': '配送地址：浙江省杭州市西湖区文一路88号3栋',
        'email': 'buyer@example.com',
        'recipient': '收货人：张小明',
        'card': '银行卡号：6222021234567890123',
      });
      final value = result.value! as Map;

      expect(value['text'], contains('[REDACTED_IDENTIFIER]'));
      expect(value['text'], contains('[REDACTED_PHONE]'));
      expect(value['text'], contains('¥12.34'));
      expect(value['desc'], contains('[REDACTED_ADDRESS]'));
      expect(value['email'], '[REDACTED_EMAIL]');
      expect(value['recipient'], contains('[REDACTED_NAME]'));
      expect(value['card'], contains('[REDACTED_CARD]'));
      expect(result.findings, isNotEmpty);
      expect(
          result.findings.every(
              (item) => !item.toJson().toString().contains('13812345678')),
          isTrue);
    });

    test('does not rewrite Android class names or stable view identifiers', () {
      final result = SnapshotSanitizer().sanitize({
        'name': 'android.widget.FrameLayout',
        'id': 'com.example.shop:id/orderFragment',
        'vid': 'exampleOrderContainer',
      });

      expect(result.value, {
        'name': 'android.widget.FrameLayout',
        'id': 'com.example.shop:id/orderFragment',
        'vid': 'exampleOrderContainer',
      });
      expect(result.findings, isEmpty);
    });

    test('writes a sanitized standalone JSON file and privacy report', () {
      final directory =
          Directory.systemTemp.createTempSync('sanitize-json-test-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final input = File('${directory.path}${Platform.pathSeparator}input.json')
        ..writeAsStringSync(jsonEncode({'phone': '13812345678'}));
      final output =
          File('${directory.path}${Platform.pathSeparator}output.json');
      final report =
          File('${directory.path}${Platform.pathSeparator}report.json');

      writeSanitizedJson(input, output, reportFile: report);

      expect(output.readAsStringSync(), contains('[REDACTED_PHONE]'));
      expect(output.readAsStringSync(), isNot(contains('13812345678')));
      expect(jsonDecode(report.readAsStringSync())['findingCount'], 1);
      expect(report.readAsStringSync(), isNot(contains('13812345678')));
    });
  });

  group('GkdSnapshotImporter', () {
    late Directory temporaryDirectory;

    setUp(() => temporaryDirectory =
        Directory.systemTemp.createTempSync('gkd-import-test-'));
    tearDown(() => temporaryDirectory.deleteSync(recursive: true));

    test('imports a GKD ZIP and preserves parent-child fields', () {
      final source = {
        'id': 42,
        'appId': 'com.example.shop',
        'activityId': 'com.example.OrderActivity',
        'screenWidth': 1080,
        'screenHeight': 2400,
        'isLandscape': false,
        'appInfo': {
          'id': 'com.example.shop',
          'name': 'Example',
          'versionName': '1.2.3',
          'versionCode': 12,
        },
        'nodes': [
          {
            'id': 0,
            'pid': -1,
            'attr': {'text': null, 'desc': null, 'childCount': 1},
          },
          {
            'id': 1,
            'pid': 0,
            'attr': {
              'text': '订单 123456789012',
              'desc': '实付款 ¥12.34',
              'childCount': 0
            },
          },
        ],
      };
      final archive = Archive()
        ..addFile(ArchiveFile('42.json', utf8.encode(jsonEncode(source)).length,
            utf8.encode(jsonEncode(source))))
        ..addFile(ArchiveFile('42.png', 4, [137, 80, 78, 71]));
      final zip = File(
          '${temporaryDirectory.path}${Platform.pathSeparator}snapshot.zip')
        ..writeAsBytesSync(ZipEncoder().encode(archive)!);

      final importer = GkdSnapshotImporter();
      final imported = importer.read(zip);
      final output = importer.write(
        imported,
        Directory(
            '${temporaryDirectory.path}${Platform.pathSeparator}workspace'),
      );

      expect(imported.summary['packageName'], 'com.example.shop');
      expect(imported.summary['activity'], 'com.example.OrderActivity');
      expect(imported.summary['nodeCount'], 2);
      final child = imported.nodes[1] as Map;
      expect(child['id'], 1);
      expect(child['pid'], 0);
      expect((child['attr'] as Map)['text'], contains('[REDACTED_IDENTIFIER]'));
      expect((child['attr'] as Map)['desc'], '实付款 ¥12.34');
      expect(
          File('${output.path}${Platform.pathSeparator}summary.json')
              .existsSync(),
          isTrue);
      expect(
          File('${output.path}${Platform.pathSeparator}nodes.json')
              .existsSync(),
          isTrue);
      expect(
          File('${output.path}${Platform.pathSeparator}privacy-report.json')
              .existsSync(),
          isTrue);
      expect(
          File('${output.path}${Platform.pathSeparator}screenshot.png')
              .existsSync(),
          isTrue);
    });

    test('rejects a node whose parent is missing', () {
      final source = {
        'id': 1,
        'nodes': [
          {'id': 1, 'pid': 99, 'attr': {}},
        ],
      };
      final bytes = utf8.encode(jsonEncode(source));
      final archive = Archive()
        ..addFile(ArchiveFile('1.json', bytes.length, bytes));
      final zip =
          File('${temporaryDirectory.path}${Platform.pathSeparator}bad.zip')
            ..writeAsBytesSync(ZipEncoder().encode(archive)!);

      expect(() => GkdSnapshotImporter().read(zip), throwsFormatException);
    });
  });
}
