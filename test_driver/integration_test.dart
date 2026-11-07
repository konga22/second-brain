import 'package:integration_test/integration_test_driver.dart';

/// profile 모드 성능 측정용 (실제 사용 속도에 가까움):
/// flutter drive --profile --driver=test_driver/integration_test.dart \
///   --target=integration_test/perf_test.dart -d macos
Future<void> main() => integrationDriver();
