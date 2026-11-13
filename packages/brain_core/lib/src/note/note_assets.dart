import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../log/change_log.dart';
import '../security/secret_mask.dart';
import '../vault/vault.dart';
import 'note_store.dart' show NoteStoreException;

/// 첨부 사진 (설계서_프롬프트이후 5.5). `assets/<해시>.<확장자>`에 같은 사진은 한 번만 둔다 (설계서 4.1).
///
/// 사진 속 글자는 [maskSecrets]처럼 가릴 수 없다. 키가 찍힌 사진을 거르는 것은 스킬 규칙(brain-save)이다.

/// 받는 사진 확장자. jpeg는 jpg로 맞춘다 — 같은 사진이 확장자만 달라 두 번 저장되지 않게.
const attachmentExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic'};

/// 사진 1장 크기 상한 20MB (설계서_프롬프트이후 5.5). 지식 폴더 백업 zip이 커지는 것을 막는다.
const maxAttachmentBytes = 20 * 1024 * 1024;

/// 지식 폴더 안 첨부 폴더 이름.
const assetsDirName = 'assets';

/// 붙일 사진 하나를 검사한다. 반환: 맞춘 확장자(`png`·`jpg`…). 문제가 있으면 [NoteStoreException].
///
/// 확장자만 보면 이름만 바꾼 글 파일도 들어온다 → 파일 머리(매직 바이트)도 본다.
String checkAttachment(String path) {
  final name = p.basename(path);
  final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
  if (!attachmentExtensions.contains(ext)) {
    throw NoteStoreException('$name: 사진만 붙일 수 있습니다 (png·jpg·gif·webp·heic). 글은 본문(표준 입력)으로 주세요.');
  }
  final file = File(path);
  if (!file.existsSync()) {
    throw NoteStoreException('$name: 파일이 없습니다 ($path). 경로를 확인하거나 파일을 끌어다 놓아 주세요.');
  }
  final size = file.lengthSync();
  if (size > maxAttachmentBytes) {
    throw NoteStoreException(
      '$name: ${(size / 1024 / 1024).toStringAsFixed(1)}MB라 붙이지 않았습니다. 사진은 1장 20MB까지입니다.',
    );
  }
  final normalized = ext == 'jpeg' ? 'jpg' : ext;
  final handle = file.openSync();
  final List<int> head;
  try {
    head = handle.readSync(16);
  } finally {
    handle.closeSync();
  }
  if (!_looksLike(normalized, head)) {
    throw NoteStoreException('$name: 확장자는 $ext인데 사진 파일이 아닙니다. 원래 사진 파일을 주세요.');
  }
  return normalized;
}

bool _startsWith(List<int> bytes, List<int> prefix, [int at = 0]) {
  if (bytes.length < at + prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[at + i] != prefix[i]) return false;
  }
  return true;
}

/// HEIC 계열 상표(ftyp 뒤 4글자). 아이폰 사진은 heic, 그 밖은 mif1·msf1 등.
const _heifBrands = {'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1'};

bool _looksLike(String ext, List<int> head) => switch (ext) {
  'png' => _startsWith(head, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  'jpg' => _startsWith(head, const [0xff, 0xd8, 0xff]),
  'gif' => _startsWith(head, 'GIF87a'.codeUnits) || _startsWith(head, 'GIF89a'.codeUnits),
  'webp' => _startsWith(head, 'RIFF'.codeUnits) && _startsWith(head, 'WEBP'.codeUnits, 8),
  'heic' => _startsWith(head, 'ftyp'.codeUnits, 4) &&
      head.length >= 12 &&
      _heifBrands.contains(String.fromCharCodes(head.sublist(8, 12))),
  _ => false,
};

/// 사진을 `assets/<해시 16자>.<확장자>`로 복사한다. 같은 내용이 이미 있으면 복사하지 않는다.
///
/// 새로 만든 파일만 되돌리기 묶음([batch])에 남긴다. 이미 있던 사진은 다른 노트가 쓰고 있을 수 있어
/// 이 묶음을 되돌려도 건드리지 않는다. 반환: (지식 폴더 기준 경로, 새로 만들었는가).
(String, bool) storeAsset(Vault vault, String source, {String? batch}) {
  final ext = checkAttachment(source);
  final bytes = File(source).readAsBytesSync();
  final hash = sha256.convert(bytes).toString().substring(0, 16);
  final rel = '$assetsDirName/$hash.$ext';
  final target = p.join(vault.root, rel);
  if (File(target).existsSync()) return (rel, false);
  recordBeforeChange(vault, target, batch: batch);
  writeBytesAtomic(target, bytes); // 쓰다가 꺼져도 반쪽 사진이 남지 않는다
  return (rel, true);
}

/// 노트 본문에 붙일 사진 링크. 경로는 노트 폴더 기준 상대 경로라 Obsidian·VS Code·GitHub에서도 열린다.
/// 설명 글은 원래 파일 이름(가림 거침). 링크 문법을 깨는 `[`·`]`는 뺀다.
String assetLink(Vault vault, String notePath, String assetRel, String sourceName) {
  final rel = p.posix.joinAll(p.split(p.relative(p.join(vault.root, assetRel), from: p.dirname(notePath))));
  var alt = maskSecrets(p.basenameWithoutExtension(sourceName)).replaceAll(RegExp(r'[\[\]\n\r]'), ' ').trim();
  if (alt.isEmpty) alt = '사진';
  return '![$alt]($rel)';
}

/// 본문의 `assets/` 사진 링크 `![설명](…assets/…)`. 색인에서는 설명 글만 남긴다
/// (경로의 `assets`·`png`로 노트가 찾히지 않게, 설계서_프롬프트이후 5.5).
final assetImageLink = RegExp(r'!\[([^\]\n]*)\]\(((?:[^)\s]*/)?assets/[^)\s]+)\)');

/// [assetName](`<해시>.<확장자>`)을 가리키는 노트·원본·실수 노트가 지식 폴더에 남아 있는가.
/// 되돌리기가 새 사진을 치우기 전에 본다 — 다른 노트가 나중에 같은 사진을 붙였을 수 있다.
bool isAssetReferenced(Vault vault, String assetName) {
  for (final dir in [vault.wikiDir, p.join(vault.root, 'raw'), vault.lessonsDir]) {
    final root = Directory(dir);
    if (!root.existsSync()) continue;
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      try {
        if (entity.readAsStringSync().contains('$assetsDirName/$assetName')) return true;
      } on FileSystemException {
        // 읽지 못한 파일이 가리키는지 모른다 → 남겨 두는 쪽이 안전하다.
        return true;
      }
    }
  }
  return false;
}

/// 노트를 [fromPath]에서 [toPath]로 옮길 때 본문의 사진 링크를 새 자리 기준 상대 경로로 다시 쓴다 (설계서_프롬프트이후 5.1).
/// 링크는 노트 폴더 기준이라(`../../assets/…`) 구역 아래로 한 단계 깊어지면 그대로는 끊긴다. 둘 다 절대 경로.
/// 지식 폴더의 `assets/`를 가리키는 상대 링크만 바꾼다 (절대 경로·주소·폴더 밖은 그대로).
String rebaseAssetLinks(Vault vault, String text, String fromPath, String toPath) {
  final assetsRoot = p.join(vault.root, assetsDirName);
  return text.replaceAllMapped(assetImageLink, (m) {
    final link = m.group(2)!;
    if (link.startsWith('/') || link.contains(':')) return m.group(0)!;
    final target = p.normalize(p.join(p.dirname(fromPath), link));
    if (!p.isWithin(assetsRoot, target)) return m.group(0)!;
    final rel = p.posix.joinAll(p.split(p.relative(target, from: p.dirname(toPath))));
    return '![${m.group(1)}]($rel)';
  });
}
