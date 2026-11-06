import 'package:brain_core/brain_core.dart';

/// 지식 폴더 위치. CLI와 같은 규칙(`BRAIN_VAULT`, 없으면 `~/SecondBrain`)을 쓴다.
String defaultVaultPath() => Vault.resolve().root;
