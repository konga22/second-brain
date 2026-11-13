import 'package:brain_core/brain_core.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../app/theme/app_colors.dart';
import '../../shared/safe_set_state.dart';

/// 페르소나 질문 4문항 입력 (설계서_프롬프트이후 5.2). [연동] 다음 단계와 [설정]이 같이 쓴다.
///
/// 모두 비워 두거나 건너뛸 수 있다. 나이·성별·건강·가족은 묻지 않는다 — AI 행동을 바꾸지 않고 파일이 평문이라서.
/// 저장은 [onSave]가 한다(파일 쓰기). 이 위젯은 쓴 것만 [Persona]로 넘긴다.
class PersonaForm extends StatefulWidget {
  const PersonaForm({super.key, required this.initial, required this.onSave, this.onSkip});

  final Persona initial;
  final Future<void> Function(Persona persona) onSave;

  /// 있으면 [건너뛰기]를 보인다 ([연동] 다음 단계).
  final VoidCallback? onSkip;

  @override
  State<PersonaForm> createState() => _PersonaFormState();
}

class _PersonaFormState extends State<PersonaForm> with SafeSetState<PersonaForm> {
  late final _work = TextEditingController(text: widget.initial.work);
  late final _forbidden = TextEditingController(text: widget.initial.forbidden.join(', '));
  late final Set<String> _keeps = {...widget.initial.keeps};
  late String _style = widget.initial.answerStyle;
  bool _isSaving = false;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _forbidden.addListener(_onForbiddenChanged);
  }

  @override
  void dispose() {
    _work.dispose();
    _forbidden.dispose();
    super.dispose();
  }

  /// 1글자 금지어 안내를 바로 고친다.
  void _onForbiddenChanged() => setState(() {});

  /// 보기 순서대로, 손으로 고친 me.md에만 있던 항목은 뒤에 그대로.
  List<String> get _orderedKeeps => [
    for (final choice in Persona.keepChoices)
      if (_keeps.contains(choice)) choice,
    for (final keep in widget.initial.keeps)
      if (_keeps.contains(keep) && !Persona.keepChoices.contains(keep)) keep,
  ];

  void _toggleKeep(String choice) =>
      setState(() => _keeps.contains(choice) ? _keeps.remove(choice) : _keeps.add(choice));

  /// 고른 것을 다시 누르면 비운다 (답하지 않기).
  void _onStyle(String style) => setState(() => _style = _style == style ? '' : style);

  Future<void> _onSave() async {
    setState(() {
      _isSaving = true;
      _message = null;
    });
    try {
      await widget.onSave(
        widget.initial.copyWith(
          work: _work.text.trim(),
          keeps: _orderedKeeps,
          answerStyle: _style,
          forbidden: Persona.splitItems(_forbidden.text),
        ),
      );
      setState(() {
        _message = '저장함. Claude Code는 새 세션부터, 저장 막기는 바로 적용됩니다.';
        _isError = false;
      });
    } on Object catch (e) {
      // 쓴 글은 칸에 그대로 남는다
      setState(() {
        _message = '저장하지 못했습니다: $e';
        _isError = true;
      });
    } finally {
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = AppColors.of(context);
    final ignored = [
      for (final term in Persona.splitItems(_forbidden.text))
        if (term.replaceAll(' ', '').runes.length < 2) term,
    ];
    Widget question(String title, String? hint) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.small),
          if (hint != null) Text(hint, style: theme.textTheme.muted.copyWith(fontSize: 12)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '모두 비워 두거나 건너뛰어도 됩니다. 답은 지식 폴더의 me.md에만 저장하고 서버로 보내지 않습니다.',
          style: theme.textTheme.muted,
        ),
        question('1. 지금 하는 일 한 줄', 'Claude Code 새 세션 안내에 한 줄로 들어갑니다 (60자까지).'),
        ShadInput(controller: _work, placeholder: const Text('예: 대학교 3학년, 맥 앱을 혼자 만드는 중')),
        question('2. 주로 남길 것 (여러 개)', null),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            for (final choice in Persona.keepChoices)
              GestureDetector(
                onTap: () => _toggleKeep(choice),
                behavior: HitTestBehavior.opaque,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ShadCheckbox(value: _keeps.contains(choice), onChanged: (_) => _toggleKeep(choice)),
                    const SizedBox(width: 6),
                    Text(choice),
                  ],
                ),
              ),
          ],
        ),
        question('3. 답 방식', 'Claude Code 새 세션 안내에 함께 들어갑니다.'),
        Wrap(
          spacing: 8,
          children: [
            for (final style in const [Persona.styleShort, Persona.styleDetailed])
              (_style == style ? ShadButton.secondary : ShadButton.outline)(
                size: ShadButtonSize.sm,
                onPressed: () => _onStyle(style),
                child: Text(style),
              ),
          ],
        ),
        question(
          '4. 절대 저장하면 안 되는 것',
          '이 말이 든 노트는 brain add·brain write와 앱이 저장하지 않습니다. 이 맥에서만 검사하고, AI에게 목록을 보내지 않습니다.',
        ),
        ShadTextarea(
          controller: _forbidden,
          minHeight: 64,
          placeholder: const Text('예: 회사 이름, 연봉 (쉼표나 줄로 나눔)'),
        ),
        if (ignored.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '1글자 ${ignored.map((t) => '"$t"').join(', ')}은 검사하지 않습니다 (너무 흔해 거의 모든 노트가 막힘).',
              style: TextStyle(color: colors.warning, fontSize: 12),
            ),
          ),
        const SizedBox(height: 14),
        Row(
          children: [
            ShadButton(
              size: ShadButtonSize.sm,
              enabled: !_isSaving,
              onPressed: _onSave,
              child: Text(_isSaving ? '저장 중…' : '저장'),
            ),
            if (widget.onSkip != null) ...[
              const SizedBox(width: 8),
              ShadButton.ghost(size: ShadButtonSize.sm, enabled: !_isSaving, onPressed: widget.onSkip, child: const Text('건너뛰기')),
            ],
          ],
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _message!,
              style: _isError ? TextStyle(color: colors.danger, fontSize: 13) : theme.textTheme.muted,
            ),
          ),
      ],
    );
  }
}
