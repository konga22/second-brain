import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 세션에서 읽은 범위 세기 (11/12 O-7 실측: 긴 세션의 중간을 건너뛰고 저장했다).
void main() {
  late Directory temp;
  late SessionReads reads;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('reads_');
    reads = SessionReads(Vault(p.join(temp.path, 'vault'))..ensure());
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('건너뛴 곳을 안 읽은 곳으로 돌려준다 (실측에서 12,000자 판이 건너뛴 모양)', () {
    const total = 140832;
    for (var from = 0; from < 108000; from += 12000) {
      reads.record('s1', from, from + 12000, total);
    }
    final gaps = reads.record('s1', 128000, total, total);
    expect(gaps, [(108000, 128000)]);
    expect(SessionReads.describe(gaps), '108000~128000');
    expect(reads.record('s1', 108000, 120000, total), [(120000, 128000)]);
    expect(reads.record('s1', 120000, 128000, total), isEmpty);
  });

  test('한 번도 안 읽은 세션은 전체가 안 읽은 곳, 세션이 자라면 뒤가 다시 안 읽은 곳', () {
    expect(reads.unread('s2', 5000), [(0, 5000)]);
    reads.record('s2', 0, 5000, 5000);
    expect(reads.unread('s2', 5000), isEmpty);
    expect(reads.unread('s2', 9000), [(5000, 9000)]);
  });
}
