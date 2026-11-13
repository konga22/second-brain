import 'package:flutter/widgets.dart';

import '../app/theme/app_colors.dart';

/// 노트 본문을 간단한 마크다운으로 그린다: 제목(#), 목록(-·*·1.), 코드 블록(```),
/// 굵게(**), 인라인 코드(`), `[[링크]]`(보라, 누르면 [onLink]).
/// 외부 패키지 없이 노트에서 실제로 쓰는 문법만 다룬다.
class MarkdownView extends StatelessWidget {
  const MarkdownView({super.key, required this.text, required this.onLink});

  final String text;
  final void Function(String title) onLink;

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
