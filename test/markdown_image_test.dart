import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:secondbrain/app/theme/app_theme.dart';
import 'package:secondbrain/shared/markdown_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// 노트 화면이 본문의 `assets/` 사진 링크를 그림으로 보여 준다 (설계서_프롬프트이후 5.5).
void main() {
  late Directory temp;
  late String vaultRoot;
  late String noteDir;

  // 1×1 PNG
  final onePixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('md_image_');
    vaultRoot = p.join(temp.path, 'vault');
    noteDir = p.join(vaultRoot, 'wiki', 'Flutter');
    Directory(noteDir).createSync(recursive: true);
    File(p.join(vaultRoot, 'assets', '0123456789abcdef.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(onePixel);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> show(WidgetTester tester, String text) => tester.pumpWidget(
    ShadApp(
      theme: buildAppTheme(Brightness.light),
      home: SingleChildScrollView(
        child: MarkdownView(text: text, onLink: (_) {}, baseDir: noteDir, vaultRoot: vaultRoot),
      ),
    ),
  );

  testWidgets('assets/ 사진 링크는 그림으로, 나머지 글은 그대로', (tester) async {
    await show(tester, '서명 오류가 났다.\n\n![빌드 화면](../../assets/0123456789abcdef.png)\n');
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image is ResizeImage ? (image.image as ResizeImage).imageProvider : image.image;
    expect((provider as FileImage).file.path, p.join(vaultRoot, 'assets', '0123456789abcdef.png'));
    expect(image.semanticLabel, '빌드 화면');
    expect(find.textContaining('서명 오류가 났다.'), findsOneWidget);
    expect(find.textContaining('assets/'), findsNothing, reason: '링크 글이 그대로 보이면 그림으로 안 그린 것');
    // 실제 디코딩은 flutter_tester에서 runAsync로 돌리면 이 기기에서 멈춰(11/13) 위젯 트리까지만 본다.
    expect(tester.getSize(find.byType(Image)).width, lessThanOrEqualTo(480), reason: '너비를 묶는다');
  });

  testWidgets('노트가 다른 깊이로 옮겨져 상대 경로가 어긋나도 assets/의 같은 이름을 찾는다', (tester) async {
    await show(tester, '![화면](../assets/0123456789abcdef.png)');
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image is ResizeImage ? (image.image as ResizeImage).imageProvider : image.image;
    expect((provider as FileImage).file.path, p.join(vaultRoot, 'assets', '0123456789abcdef.png'));
  });

  testWidgets('사진을 읽지 못하면 자리 표시 (파일 이름을 보여 준다)', (tester) async {
    await show(tester, '![없는 사진](../../assets/ffffffffffffffff.png)');
    final image = tester.widget<Image>(find.byType(Image));
    // 읽기 실패 때 Flutter가 부르는 errorBuilder를 직접 그려 본다 (실제 디코딩은 위 시험의 이유로 돌리지 않는다)
    await tester.pumpWidget(
      ShadApp(
        theme: buildAppTheme(Brightness.light),
        home: Builder(builder: (context) => image.errorBuilder!(context, const FileSystemException('없음'), null)),
      ),
    );
    expect(find.textContaining('사진을 열 수 없습니다: ffffffffffffffff.png (없는 사진)'), findsOneWidget);
  });

  testWidgets('지식 폴더 assets/ 밖을 가리키는 사진 링크는 그림으로 읽지 않는다', (tester) async {
    await show(tester, '![밖](/etc/secret.png)');
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('/etc/secret.png'), findsOneWidget);
  });
}
