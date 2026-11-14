import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../app/theme/app_colors.dart';

/// 노트 본문을 간단한 마크다운으로 그린다: 제목(#), 목록(-·*·1.), 코드 블록(```),
/// 굵게(**), 인라인 코드(`), `[[링크]]`(보라, 누르면 [onLink]),
/// 한 줄짜리 사진 링크 `![설명](../../assets/<해시>.png)` (설계서_프롬프트이후 5.5).
/// 외부 패키지 없이 노트에서 실제로 쓰는 문법만 다룬다.
class MarkdownView extends StatelessWidget {
  const MarkdownView({super.key, required this.text, required this.onLink, this.baseDir, this.vaultRoot});

  final String text;
  final void Function(String title) onLink;

  /// 노트 파일이 있는 폴더 (사진 링크의 상대 경로 기준). 없으면 사진을 그리지 않는다.
  final String? baseDir;

  /// 지식 폴더. 사진은 그 안 `assets/`에 있는 것만 읽는다 — 노트 본문이 아무 파일이나 열게 하지 않는다.
  final String? vaultRoot;

  static final _imageLine = RegExp(r'^\s*!\[([^\]\n]*)\]\(([^)\s]+)\)\s*$');

  /// 사진 링크가 가리키는 `assets/` 파일. 노트를 다른 깊이의 폴더로 옮겨 상대 경로가 어긋나면
  /// 같은 이름을 `assets/`에서 찾는다 (사진 이름이 내용 해시라 이름이 같으면 같은 사진).
  String? _assetPath(String target) {
    final root = vaultRoot;
    final base = baseDir;
    if (root == null || base == null) return null;
    final assets = p.join(root, 'assets');
    final relative = p.normalize(p.join(base, target));
    final byName = p.join(assets, p.basename(relative));
    if (p.isWithin(assets, relative) && (File(relative).existsSync() || !target.contains('assets/'))) {
      return relative;
    }
    return target.contains('assets/') ? byName : null;
  }

  Widget _image(String path, String alt, TextStyle base, AppColors colors) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480, maxHeight: 480),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          // 20MB 캡처를 원래 크기로 풀면 메모리를 크게 쓴다 → 보이는 너비의 2배로만 푼다
          cacheWidth: 960,
          semanticLabel: alt,
          errorBuilder: (_, _, _) => Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.surfaceRaised,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '사진을 열 수 없습니다: ${p.basename(path)}${alt.isEmpty ? '' : ' ($alt)'}',
              style: base.copyWith(fontSize: 12, color: colors.textMuted),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final base = TextStyle(fontSize: 13, height: 1.65, color: colors.text);
    final blocks = <Widget>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('```')) {
        final code = <String>[];
        for (
          i++;
          i < lines.length && !lines[i].trimLeft().startsWith('```');
          i++
        ) {
          code.add(lines[i]);
        }
        blocks.add(
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.surfaceRaised,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              code.join('\n'),
              style: base.copyWith(
                fontFamily: 'Menlo',
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        );
        continue;
      }
      if (line.trim().isEmpty) {
        blocks.add(const SizedBox(height: 6));
        continue;
      }
      final image = _imageLine.firstMatch(line);
      final imagePath = image == null ? null : _assetPath(image.group(2)!);
      if (imagePath != null) {
        blocks.add(_image(imagePath, image!.group(1)!.trim(), base, colors));
        continue;
      }
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      if (heading != null) {
        final level = heading.group(1)!.length;
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: _inline(
              heading.group(2)!,
              base.copyWith(
                fontSize: level <= 2 ? 16 : 14,
                fontWeight: FontWeight.w700,
              ),
              colors,
            ),
          ),
        );
        continue;
      }
      final bullet = RegExp(r'^(\s*)([-*]|\d+\.)\s+(.*)$').firstMatch(line);
      if (bullet != null) {
        final indent = bullet.group(1)!.length ~/ 2;
        final marker = bullet.group(2)!;
        blocks.add(
          Padding(
            padding: EdgeInsets.only(left: 4 + indent * 14.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 16,
                  child: Text(
                    marker.endsWith('.') ? marker : '•',
                    style: base.copyWith(color: colors.textMuted),
                  ),
                ),
                Expanded(child: _inline(bullet.group(3)!, base, colors)),
              ],
            ),
          ),
        );
        continue;
      }
      blocks.add(_inline(line, base, colors));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    );
  }

  Widget _inline(String text, TextStyle style, AppColors colors) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'\[\[([^\[\]\n]+?)\]\]|\*\*(.+?)\*\*|`([^`]+)`');
    var last = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      if (m.group(1) != null) {
        final target = m.group(1)!.split('|').first.split('#').first.trim();
        final label = m.group(1)!.contains('|')
            ? m.group(1)!.split('|').last
            : m.group(1)!;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onLink(target),
                child: Text(
                  '[[$label]]',
                  style: style.copyWith(color: colors.accentText),
                ),
              ),
            ),
          ),
        );
      } else if (m.group(2) != null) {
        spans.add(
          TextSpan(
            text: m.group(2),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m.group(3),
            style: TextStyle(
              fontFamily: 'Menlo',
              fontSize: 12,
              backgroundColor: colors.surfaceRaised,
            ),
          ),
        );
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}
