import 'package:flutter/widgets.dart';

/// 비동기 작업(백업·연동 설치·가져오기·AI 검증)이 끝났을 때 화면이 이미 닫혔으면 setState를 건너뛴다.
/// 예전에는 다른 화면으로 옮긴 뒤 작업이 끝나면 "setState() called after dispose()"로 터졌다 (11/11 K-37).
mixin SafeSetState<T extends StatefulWidget> on State<T> {
  @override
  void setState(VoidCallback fn) {
    if (mounted) super.setState(fn);
  }
}
