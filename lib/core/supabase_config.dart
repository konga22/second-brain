import 'dart:io';

/// Supabase 프로젝트 주소와 공개(publishable) 키.
///
/// `flutter run -d macos --dart-define-from-file=env/supabase.json`으로 넣는다.
/// 공개 키는 앱에 들어가도 되는 키지만 저장소에는 올리지 않는다.
/// AI API 키·서비스 키는 앱에 절대 넣지 않는다 (설계서 1절).
class SupabaseConfig {
  const SupabaseConfig._();

  static const url = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;
}

/// Supabase 인증 서버의 상태 확인 주소(`/auth/v1/health`)에 닿는지 본다.
/// 설정이 없으면 null을 돌려준다.
Future<bool?> checkSupabaseReachable() async {
  if (!SupabaseConfig.isConfigured) return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(
      Uri.parse('${SupabaseConfig.url}/auth/v1/health'),
    );
    request.headers.set('apikey', SupabaseConfig.publishableKey);
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>();
    return response.statusCode == HttpStatus.ok;
  } on Exception {
    return false;
  } finally {
    client.close(force: true);
  }
}
