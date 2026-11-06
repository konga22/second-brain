import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_config.dart';

/// 로그인·가입 (설계서 3절 `/login`, `/signup`). Supabase 이메일 로그인.
/// 로그인은 앱 안 AI 질문·요금제에만 필요하다. 노트·연동은 로그인 없이 된다.
Future<void> showLoginDialog(BuildContext context) =>
    showShadDialog<void>(context: context, builder: (_) => const _LoginDialog());

class _LoginDialog extends StatefulWidget {
  const _LoginDialog();

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _isSignUp = false;
  bool _isWorking = false;
  String? _message;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    if (!SupabaseConfig.isConfigured) {
      setState(() => _message = '서버 설정 전입니다 (env/supabase.json).');
      return;
    }
    setState(() {
      _isWorking = true;
      _message = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      if (_isSignUp) {
        final result = await auth.signUp(email: _email.text.trim(), password: _password.text);
        if (result.session == null) {
          setState(() => _message = '확인 메일을 보냈습니다. 메일의 링크를 누른 뒤 로그인하세요.');
          return;
        }
      } else {
        await auth.signInWithPassword(email: _email.text.trim(), password: _password.text);
      }
      if (mounted) Navigator.of(context).pop();
    } on AuthException catch (e) {
      setState(() => _message = e.message);
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: Text(_isSignUp ? '가입' : '로그인'),
      description: const Text('앱 안 AI 질문과 요금제에만 씁니다. 노트는 서버로 보내지 않습니다.'),
      actions: [
        ShadButton.ghost(
          onPressed: () => setState(() => _isSignUp = !_isSignUp),
          child: Text(_isSignUp ? '이미 계정이 있어요' : '처음이에요 (가입)'),
        ),
        ShadButton(
          enabled: !_isWorking,
          onPressed: _onSubmit,
          child: Text(_isWorking ? '잠시만…' : (_isSignUp ? '가입' : '로그인')),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShadInput(controller: _email, placeholder: const Text('이메일'), autofocus: true),
          const SizedBox(height: 8),
          ShadInput(
            controller: _password,
            placeholder: const Text('비밀번호 (6자 이상)'),
            obscureText: true,
            onSubmitted: (_) => _onSubmit(),
          ),
          if (_message != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
        ],
      ),
    );
  }
}
