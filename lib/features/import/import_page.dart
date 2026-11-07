import 'dart:io';

import 'package:brain_core/brain_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/router/app_page.dart';
import '../../core/brain_providers.dart';

/// 가져오기 (설계서 3절 `/import`, 5.6): 텍스트 회의록·문서를 원본(raw/)으로 넣는다.
/// 정리는 사용자 AI의 brain-ingest가 정리 대기 노트로 만든다.
class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key});

  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  ImportKind _kind = ImportKind.meeting;
  bool _isWorking = false;
  final _log = <String>[];

  Future<void> _onPick() async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: '텍스트', extensions: ['md', 'txt', 'markdown']),
        XTypeGroup(label: 'PDF·Word (markitdown 필요)', extensions: ['pdf', 'docx']),
      ],
    );
    if (files.isEmpty) return;
    setState(() => _isWorking = true);
    final vault = ref.read(vaultProvider);
    final batch = newBatchId();
    for (final file in files) {
      try {
        final ext = p.extension(file.path).toLowerCase();
        final String? text = switch (ext) {
          '.pdf' || '.docx' => await convertWithMarkitdown(file.path),
          _ => await File(file.path).readAsString(),
        };
        if (text == null) {
          _log.add('${file.name} — 건너뜀: PDF·Word는 이 맥에 markitdown이 있어야 합니다 (pip install markitdown).');
          continue;
        }
        final result = importText(
          vault,
          name: file.name,
          text: text,
          kind: _kind,
          originalPath: file.path,
          batch: batch,
        );
        _log.add(
          '${file.name} → ${result.relPath}${result.maskedCount > 0 ? ' (비밀값 ${result.maskedCount}개 가림)' : ''}',
        );
      } on FileSystemException catch (e) {
        _log.add('${file.name} — 실패: ${e.message}');
      } on FormatException {
        _log.add('${file.name} — 실패: UTF-8 텍스트가 아닙니다.');
      }
    }
    bumpVault(ref);
    setState(() => _isWorking = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final raw = ref.watch(rawDocsProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
      children: [
        Text('가져오기', style: theme.textTheme.h4),
        const SizedBox(height: 16),
        ShadCard(
          title: const Text('텍스트 회의록·문서'),
          description: const Text(
            '.md·.txt 파일을 원본(raw/)으로 넣습니다. 원본은 고치지 않고, 비밀값(API 키 등)은 저장 전에 가립니다. '
            'PDF·Word는 이 맥에 markitdown이 있으면 md로 바꿔서 넣습니다.',
          ),
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 4,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final kind in ImportKind.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: (kind == _kind ? ShadButton.secondary : ShadButton.ghost)(
                          size: ShadButtonSize.sm,
                          onPressed: () => setState(() => _kind = kind),
                          child: Text('${kind.label} (raw/${kind.folder})'),
                        ),
                      ),
                    ShadButton(
                      size: ShadButtonSize.sm,
                      enabled: !_isWorking,
                      leading: const Icon(LucideIcons.fileInput, size: 14),
                      onPressed: _onPick,
                      child: Text(_isWorking ? '가져오는 중…' : '파일 고르기'),
                    ),
                  ],
                ),
                for (final line in _log) Text(line, style: theme.textTheme.muted),
                const SizedBox(height: 8),
                Text(
                  '다음: Claude Code에서 "가져온 거 정리해 줘"라고 하면 brain-ingest가 원본을 읽고 정리 대기 노트를 만듭니다.',
                  style: theme.textTheme.muted,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ShadCard(
          title: const Text('Claude Code 지난 대화'),
          description: const Text('이 맥에 남은 Claude Code 대화는 연동 화면의 "지난 대화 정리"에서 가져옵니다.'),
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: () => context.go(AppPage.connect.path),
                child: const Text('연동 화면으로'),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        ShadCard(
          title: const Text('ChatGPT·Claude 앱 대화 (내보내기 파일)'),
          description: const Text(
            '실제 내보내기 파일 형식을 확인한 뒤 지원합니다 (형식을 추측해서 만들지 않습니다). 샘플 파일이 준비되면 추가됩니다.',
          ),
        ),
        const SizedBox(height: 24),
        Text('원본 ${raw.length}개', style: theme.textTheme.small),
        const SizedBox(height: 6),
        for (final doc in raw.reversed.take(30))
          GestureDetector(
            onTap: () => ref.read(selectedNoteProvider.notifier).select(doc.id),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('${doc.title}  ·  ${doc.path}', style: const TextStyle(fontSize: 12)),
            ),
          ),
      ],
    );
  }
}
