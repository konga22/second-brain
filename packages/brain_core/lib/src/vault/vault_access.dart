import 'dart:async';
import 'dart:io';

/// 지식 폴더를 만들고 읽고 쓰고 변경을 감시할 수 있는지 확인한 결과.
class VaultAccess {
  const VaultAccess({
    required this.path,
    required this.canWrite,
    required this.canRead,
    required this.canWatch,
    this.error,
  });

  final String path;
  final bool canWrite;
  final bool canRead;
  final bool canWatch;
  final String? error;

  bool get isReady => canWrite && canRead && canWatch;

  List<(String, bool)> get items => [
    ('쓰기 (임시 파일 → 이름 바꾸기)', canWrite),
    ('읽기', canRead),
    ('폴더 변경 감시', canWatch),
  ];
}

/// [path]에 시험 파일을 원자적으로 쓰고, 읽고, 감시 이벤트가 오는지 본 뒤 지운다.
Future<VaultAccess> checkVaultAccess(String path) async {
  final dir = Directory(path);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final probe = File('${dir.path}/.brain-probe-$stamp.md');
  final temp = File('${probe.path}.tmp');
  const text = '# 점검\n\n한글 확인 — 결제 오류\n';
  var canWrite = false;
  var canRead = false;
  var canWatch = false;
  StreamSubscription<FileSystemEvent>? watching;
  try {
    await dir.create(recursive: true);
    final seen = Completer<void>();
    watching = dir.watch().listen((event) {
      if (event.path.endsWith(probe.uri.pathSegments.last) &&
          !seen.isCompleted) {
        seen.complete();
      }
    });

    await temp.writeAsString(text, flush: true);
    await temp.rename(probe.path);
    canWrite = await probe.exists();
    canRead = await probe.readAsString() == text;
    canWatch = await seen.future
        .timeout(const Duration(seconds: 3))
        .then((_) => true, onError: (_) => false);
    return VaultAccess(
      path: dir.path,
      canWrite: canWrite,
      canRead: canRead,
      canWatch: canWatch,
    );
  } on FileSystemException catch (e) {
    return VaultAccess(
      path: dir.path,
      canWrite: canWrite,
      canRead: canRead,
      canWatch: canWatch,
      error: '${e.message} (${e.path})',
    );
  } finally {
    await watching?.cancel();
    for (final file in [temp, probe]) {
      if (await file.exists()) await file.delete();
    }
  }
}
