import 'dart:io';

/// 지식 폴더 기본 위치 (설계서 4.1). 설정에서 바꾸는 기능은 2주차에 붙인다.
String defaultVaultPath() => '${Platform.environment['HOME']}/SecondBrain';
