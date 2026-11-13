// content.js의 블록으로 Word(.docx)와 PDF 출력용 HTML을 함께 만든다.
// 사용법: make.sh로 실행한다 (직접 실행 시 node build.js <출력 폴더> <파일 이름>)
const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType, ShadingType,
  AlignmentType, HeadingLevel, BorderStyle, LevelFormat, Header, Footer, PageNumber,
  ImageRun, PageBreak, VerticalAlign,
} = require('docx');
// 세 번째 인자로 다른 내용 파일(주간 보고 등)을 줄 수 있다. 없으면 이 폴더의 content.js.
const [outDir, baseName, contentArg] = process.argv.slice(2);
const CONTENT = contentArg ? path.resolve(contentArg) : path.join(__dirname, 'content.js');
const { meta, blocks } = require(CONTENT);
const WORK = path.dirname(CONTENT);
const DOC_TITLE = meta.docTitle || `${meta.title} 기획안`;

const FONT = 'Malgun Gothic';
const FONT_ATTR = { ascii: FONT, eastAsia: FONT, hAnsi: FONT, cs: FONT };
// meta.theme === 'brain'이면 앱 디자인 기준(설계서 3.2: 차분한 도구형, 보라 포인트 1색, Pretendard)으로 만든다.
// 기획안(content.js)은 theme이 없어 예전 모양 그대로다.
const BRAIN = meta.theme === 'brain';
const C = BRAIN ? {
  navy: '18181B', accent: '6D28D9', text: '18181B', gray: '71717A',
  head: 'F4F4F6', border: 'E4E4E7', callout: 'FAFAFA', terms: 'FAFAFA', bar: 'D4D4D8',
} : {
  navy: '1F3A5F', accent: '2E6DB4', text: '222222', gray: '666666',
  head: 'DCE6F2', border: 'B8C4D2', callout: 'EEF3F9', terms: 'F6F7F9', bar: '2E6DB4',
};
const CONTENT_W = 9638; // A4 너비 11906 - 좌우 여백 1134 * 2
const IMG_W = 640;

function parseRuns(s) {
  const out = [];
  const re = /\*\*(.+?)\*\*/g;
  let last = 0;
  let m;
  while ((m = re.exec(s))) {
    if (m.index > last) out.push({ text: s.slice(last, m.index), bold: false });
    out.push({ text: m[1], bold: true });
    last = re.lastIndex;
  }
  if (last < s.length) out.push({ text: s.slice(last), bold: false });
  return out;
}

// ---------------------------------------------------------------- Word

function runs(s, opt = {}) {
  return parseRuns(s).map((r) => new TextRun({
    text: r.text, bold: r.bold || opt.bold, size: opt.size, color: opt.color,
  }));
}

const numberingConfigs = [{
  reference: 'bullet',
  levels: [{
    level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT,
    style: { paragraph: { indent: { left: 400, hanging: 260 } } },
  }],
}];
let numberedCount = 0;
function newNumberedRef() {
  const reference = `num-${numberedCount++}`;
  numberingConfigs.push({
    reference,
    levels: [{
      level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 400, hanging: 300 } } },
    }],
  });
  return reference;
}

const cellBorder = { style: BorderStyle.SINGLE, size: 4, color: C.border };
const cellBorders = { top: cellBorder, bottom: cellBorder, left: cellBorder, right: cellBorder };

function cell(text, width, opt = {}) {
  return new TableCell({
    width: { size: width, type: WidthType.DXA },
    borders: opt.borders || cellBorders,
    shading: opt.fill ? { type: ShadingType.CLEAR, color: 'auto', fill: opt.fill } : undefined,
    margins: { top: 70, bottom: 70, left: 110, right: 110 },
    verticalAlign: VerticalAlign.CENTER,
    children: opt.children || [new Paragraph({
      alignment: opt.center ? AlignmentType.CENTER : AlignmentType.LEFT,
      spacing: { before: 0, after: 0, line: 280 },
      children: runs(text, { size: 18, bold: opt.bold }),
    })],
  });
}

function docTable(b) {
  const center = new Set(b.center || []);
  const header = new TableRow({
    tableHeader: true, cantSplit: true,
    children: b.header.map((h, i) => cell(h, b.widths[i], { fill: C.head, bold: true, center: true })),
  });
  const rows = b.rows.map((r) => new TableRow({
    cantSplit: true,
    children: r.map((v, i) => cell(v, b.widths[i], { center: center.has(i) })),
  }));
  return new Table({ width: { size: CONTENT_W, type: WidthType.DXA }, columnWidths: b.widths, rows: [header, ...rows] });
}

function boxTable(children, fill, accentColor) {
  const none = { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' };
  return new Table({
    width: { size: CONTENT_W, type: WidthType.DXA },
    columnWidths: [CONTENT_W],
    rows: [new TableRow({
      cantSplit: true,
      children: [cell('', CONTENT_W, {
        fill,
        borders: { top: none, bottom: none, right: none, left: { style: BorderStyle.SINGLE, size: 24, color: accentColor } },
        children,
      })],
    })],
  });
}

function bulletPara(text, size) {
  return new Paragraph({
    numbering: { reference: 'bullet', level: 0 },
    spacing: { before: 20, after: 40, line: 300 },
    children: runs(text, { size }),
  });
}

const spacer = () => new Paragraph({ spacing: { before: 0, after: 120 }, children: [] });

function docBlock(b) {
  switch (b.type) {
    case 'h1':
      return [new Paragraph({
        heading: HeadingLevel.HEADING_1,
        pageBreakBefore: Boolean(b.breakBefore),
        border: { bottom: { style: BorderStyle.SINGLE, size: BRAIN ? 4 : 12, color: BRAIN ? C.bar : C.accent, space: 4 } },
        children: [new TextRun({ text: b.text })],
      })];
    case 'h2':
      return [new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun({ text: b.text })] })];
    case 'p':
      return [new Paragraph({ spacing: { before: 60, after: 120, line: 320 }, children: runs(b.text) })];
    case 'note':
      return [new Paragraph({ spacing: { before: 40, after: 160 }, children: runs(b.text, { size: 17, color: C.gray }) })];
    case 'bullets':
      return [...b.items.map((t) => bulletPara(t)), spacer()];
    case 'numbered': {
      const reference = newNumberedRef();
      return [...b.items.map((t) => new Paragraph({
        numbering: { reference, level: 0 },
        spacing: { before: 20, after: 60, line: 300 },
        children: runs(t),
      })), spacer()];
    }
    case 'table':
      return [docTable(b), spacer()];
    case 'callout':
      return [boxTable([
        new Paragraph({ spacing: { before: 40, after: 80 }, children: [new TextRun({ text: b.title, bold: true, color: C.accent, size: 21 })] }),
        ...b.items.map((t) => bulletPara(t, 19)),
      ], C.callout, C.bar), spacer()];
    case 'terms':
      return [boxTable([
        new Paragraph({ spacing: { before: 20, after: 60 }, children: [new TextRun({ text: '용어 설명', bold: true, color: C.gray, size: 18 })] }),
        ...b.items.map((t) => bulletPara(t, 17)),
      ], C.terms, C.border), spacer()];
    case 'image': {
      const data = fs.readFileSync(path.join(WORK, b.src));
      return [
        new Paragraph({
          alignment: AlignmentType.CENTER, spacing: { before: 120, after: 60 },
          // 그림마다 비율이 다르다 (앱 화면 1600×1000 등): PNG 머리(IHDR)에서 가로·세로를 읽는다.
          children: [new ImageRun({ type: 'png', data, transformation: { width: IMG_W, height: Math.round(IMG_W * data.readUInt32BE(20) / data.readUInt32BE(16)) } })],
        }),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 200 }, children: runs(b.caption, { size: 17, color: C.gray }) }),
      ];
    }
    default:
      throw new Error(`unknown block: ${b.type}`);
  }
}

function coverDoc() {
  const tocItems = blocks.filter((b) => b.type === 'h1').map((b) => b.text);
  const infoRows = meta.info.map(([k, v]) => new TableRow({
    cantSplit: true,
    children: [cell(k, 2400, { fill: C.head, bold: true, center: true }), cell(v, 7238)],
  }));
  return [
    new Paragraph({ spacing: { before: 2200, after: 120 }, children: [new TextRun({ text: meta.label, color: C.accent, bold: true, size: 26 })] }),
    new Paragraph({
      spacing: { after: 80 },
      children: [new TextRun({ text: meta.title, bold: true, color: C.navy, size: 60 }), new TextRun({ text: `  ${meta.tentative}`, color: C.gray, size: 26 })],
    }),
    new Paragraph({
      border: { bottom: { style: BorderStyle.SINGLE, size: BRAIN ? 4 : 18, color: BRAIN ? C.bar : C.navy, space: 8 } },
      spacing: { after: 600 },
      children: [new TextRun({ text: meta.subtitle, color: C.gray, size: 24 })],
    }),
    new Table({ width: { size: CONTENT_W, type: WidthType.DXA }, columnWidths: [2400, 7238], rows: infoRows }),
    new Paragraph({ spacing: { before: 600, after: 120 }, children: [new TextRun({ text: '목차', bold: true, color: C.navy, size: 24 })] }),
    ...tocItems.map((t) => new Paragraph({ spacing: { after: 40 }, children: [new TextRun({ text: t, size: 20, color: C.text })] })),
    new Paragraph({ children: [new PageBreak()] }),
  ];
}

async function buildDocx(file) {
  const children = [...coverDoc(), ...blocks.flatMap(docBlock)];
  const doc = new Document({
    creator: '김민상',
    title: DOC_TITLE,
    styles: {
      default: {
        document: { run: { font: FONT_ATTR, size: 20, color: C.text } },
        heading1: {
          run: { font: FONT_ATTR, size: 30, bold: true, color: C.navy },
          paragraph: { spacing: { before: 360, after: 160 }, keepNext: true },
        },
        heading2: {
          run: { font: FONT_ATTR, size: 23, bold: true, color: BRAIN ? C.text : C.accent },
          paragraph: { spacing: { before: 220, after: 100 }, keepNext: true },
        },
      },
    },
    numbering: { config: numberingConfigs },
    sections: [{
      properties: {
        page: { size: { width: 11906, height: 16838 }, margin: { top: 1134, right: 1134, bottom: 1134, left: 1134 } },
        titlePage: true,
      },
      headers: {
        first: new Header({ children: [new Paragraph({ children: [] })] }),
        default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT, children: [new TextRun({ text: meta.headerText, size: 16, color: C.gray })] })] }),
      },
      footers: {
        first: new Footer({ children: [new Paragraph({ children: [] })] }),
        default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [new TextRun({ children: ['- ', PageNumber.CURRENT, ' -'], size: 17, color: C.gray })] })] }),
      },
      children,
    }],
  });
  fs.writeFileSync(file, await Packer.toBuffer(doc));
}

// ---------------------------------------------------------------- HTML (PDF 출력용)

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const html = (s) => parseRuns(s).map((r) => (r.bold ? `<strong>${esc(r.text)}</strong>` : esc(r.text))).join('');

function htmlTable(b) {
  const center = new Set(b.center || []);
  const total = b.widths.reduce((a, w) => a + w, 0);
  const cols = b.widths.map((w) => `<col style="width:${((w / total) * 100).toFixed(2)}%">`).join('');
  const head = b.header.map((h) => `<th>${html(h)}</th>`).join('');
  const body = b.rows.map((r) => `<tr>${r.map((v, i) => `<td${center.has(i) ? ' class="c"' : ''}>${html(v)}</td>`).join('')}</tr>`).join('');
  return `<table><colgroup>${cols}</colgroup><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function htmlBlock(b) {
  switch (b.type) {
    case 'h1': return `<h1${b.breakBefore ? ' class="break"' : ''}>${esc(b.text)}</h1>`;
    case 'h2': return `<h2>${esc(b.text)}</h2>`;
    case 'p': return `<p>${html(b.text)}</p>`;
    case 'note': return `<p class="note">${html(b.text)}</p>`;
    case 'bullets': return `<ul>${b.items.map((t) => `<li>${html(t)}</li>`).join('')}</ul>`;
    case 'numbered': return `<ol>${b.items.map((t) => `<li>${html(t)}</li>`).join('')}</ol>`;
    case 'table': return htmlTable(b);
    case 'callout': return `<div class="callout"><div class="box-title">${esc(b.title)}</div><ul>${b.items.map((t) => `<li>${html(t)}</li>`).join('')}</ul></div>`;
    case 'terms': return `<div class="terms"><div class="box-title">용어 설명</div><ul>${b.items.map((t) => `<li>${html(t)}</li>`).join('')}</ul></div>`;
    case 'image': return `<figure><img src="${b.src}" alt=""><figcaption>${html(b.caption)}</figcaption></figure>`;
    default: throw new Error(`unknown block: ${b.type}`);
  }
}

// ---- 앱 디자인 기준 테마 (주간 보고)
const FONT_DIR = path.relative(WORK, path.resolve(__dirname, '../../assets/fonts/pretendard')).split(path.sep).join('/');
const MARK = '<svg width="15" height="15" viewBox="0 0 16 16" fill="none"><path d="M4 11.5 8 4.5l4.5 5M4 11.5l8.5-2" stroke="#a78bfa" stroke-width="1.1"/><circle cx="8" cy="4.5" r="2.1" fill="#7c3aed"/><circle cx="4" cy="11.5" r="1.7" fill="#7c3aed"/><circle cx="12.5" cy="9.5" r="1.4" fill="#7c3aed"/></svg>';

// "**이름**: 내용" 꼴 항목은 이름·내용 두 칸으로 나눠 그린다.
function propRows(items) {
  return items.map((t) => {
    const m = /^\*\*(.+?)\*\*\s*:\s*(.*)$/s.exec(t);
    return m ? `<div class="row"><div class="k">${esc(m[1])}</div><div class="v">${html(m[2])}</div></div>`
      : `<div class="row one"><div class="v">${html(t)}</div></div>`;
  }).join('');
}

function brainTable(b) {
  const center = new Set(b.center || []);
  const total = b.widths.reduce((a, w) => a + w, 0);
  const cols = b.widths.map((w) => `<col style="width:${((w / total) * 100).toFixed(2)}%">`).join('');
  const cls = (i) => (center.has(i) ? ' class="c"' : '');
  const head = b.header.map((h, i) => `<th${cls(i)}>${html(h)}</th>`).join('');
  const body = b.rows.map((r) => `<tr>${r.map((v, i) => `<td${cls(i)}>${html(v)}</td>`).join('')}</tr>`).join('');
  return `<table><colgroup>${cols}</colgroup><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function brainBlock(b) {
  switch (b.type) {
    case 'h1': {
      const m = /^(\d+)\.\s*(.*)$/.exec(b.text);
      const inner = m ? `<span class="n">${m[1].padStart(2, '0')}</span>${esc(m[2])}` : esc(b.text);
      return `<h1${b.breakBefore ? ' class="break"' : ''}>${inner}</h1>`;
    }
    case 'table': return brainTable(b);
    case 'callout': return `<div class="cap">${esc(b.title)}</div><div class="props key">${propRows(b.items)}</div>`;
    case 'terms': return `<div class="cap">용어</div><div class="props terms">${propRows(b.items)}</div>`;
    default: return htmlBlock(b);
  }
}

function buildHtmlBrain(file) {
  const info = meta.info.map(([k, v]) => `<div><span>${esc(k)}</span><b>${esc(v)}</b></div>`).join('');
  const face = [['Regular', 400], ['Medium', 500], ['SemiBold', 600], ['Bold', 700]]
    .map(([n, w]) => `@font-face { font-family: Pretendard; font-weight: ${w}; src: url("${FONT_DIR}/Pretendard-${n}.otf") format("opentype"); }`).join('\n  ');
  const css = `
  ${face}
  @page { size: A4; margin: 18mm 18mm 16mm; }
  * { -webkit-print-color-adjust: exact; print-color-adjust: exact; box-sizing: border-box; }
  body { font-family: Pretendard, "Apple SD Gothic Neo", sans-serif; font-size: 9.4pt; line-height: 1.62; color: #18181b; margin: 0; word-break: keep-all; font-variant-numeric: tabular-nums; }
  strong { font-weight: 600; }
  .head { padding-bottom: 16px; border-bottom: 1px solid #d4d4d8; }
  .head .label { display: flex; align-items: center; gap: 6px; font-size: 8.4pt; font-weight: 600; color: #6d28d9; }
  .head .title { font-size: 21pt; font-weight: 700; letter-spacing: -0.02em; line-height: 1.25; margin-top: 12px; }
  .head .title small { font-size: 9.5pt; font-weight: 400; color: #a1a1aa; margin-left: 7px; letter-spacing: 0; }
  .head .subtitle { color: #52525b; font-size: 11pt; margin-top: 3px; }
  .head .meta { display: grid; grid-template-columns: 1fr 1fr 1.5fr; gap: 10px 20px; margin-top: 18px; }
  .head .meta span { display: block; font-size: 7.4pt; font-weight: 500; color: #a1a1aa; line-height: 1.4; }
  .head .meta b { font-weight: 500; font-size: 8.8pt; }
  h1 { display: flex; align-items: baseline; gap: 9px; font-size: 12.5pt; font-weight: 700; letter-spacing: -0.01em; margin: 26px 0 8px; break-after: avoid; }
  h1 .n { font-size: 8.4pt; font-weight: 600; color: #7c3aed; letter-spacing: 0.02em; }
  h1.break { break-before: page; margin-top: 0; }
  h2 { font-size: 10.2pt; font-weight: 600; margin: 16px 0 4px; break-after: avoid; }
  p { margin: 4px 0 8px; }
  p.note { font-size: 8.2pt; color: #71717a; margin: 2px 0 6px; }
  ul, ol { margin: 4px 0 10px; padding-left: 18px; }
  li { margin: 5px 0; padding-left: 2px; }
  ol li::marker { color: #7c3aed; font-weight: 600; font-size: 8.6pt; }
  table { width: 100%; border-collapse: collapse; margin: 2px 0 8px; font-size: 8.6pt; line-height: 1.5; }
  th { text-align: left; font-size: 7.6pt; font-weight: 600; color: #71717a; padding: 5px 12px 5px 0; border-bottom: 1px solid #d4d4d8; }
  td { padding: 6px 12px 6px 0; border-bottom: 1px solid #ececef; vertical-align: top; color: #3f3f46; }
  td:first-child { color: #18181b; font-weight: 500; }
  th:last-child, td:last-child { padding-right: 0; }
  th.c, td.c { text-align: center; padding-left: 4px; padding-right: 4px; }
  td strong { color: #18181b; }
  tr { break-inside: avoid; }
  thead { display: table-header-group; }
  .cap { font-size: 7.6pt; font-weight: 600; color: #71717a; margin: 12px 0 4px; break-after: avoid; }
  .props { border: 1px solid #e4e4e7; border-radius: 8px; background: #fafafa; padding: 2px 14px; margin: 0 0 6px; break-inside: avoid; }
  .props .row { display: grid; grid-template-columns: 78px 1fr; gap: 14px; padding: 7px 0; border-bottom: 1px solid #ececef; }
  .props .row:last-child { border-bottom: 0; }
  .props .row.one { grid-template-columns: 1fr; }
  .props .k { font-size: 8.4pt; font-weight: 600; color: #6d28d9; }
  .props .v { color: #3f3f46; }
  .props.terms { font-size: 8.4pt; }
  .props.terms .row { grid-template-columns: 132px 1fr; padding: 5px 0; }
  .props.terms .k { font-size: 8.2pt; color: #52525b; }
  figure { margin: 10px 0 14px; text-align: center; break-inside: avoid; }
  figure img { width: 100%; }
  figcaption { font-size: 8.2pt; color: #71717a; margin-top: 4px; }
  `;
  const doc = `<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8"><title>${esc(DOC_TITLE)}</title><style>${css}</style></head><body>
  <header class="head">
    <div class="label">${MARK}${esc(meta.label)}</div>
    <div class="title">${esc(meta.title)}<small>${esc(meta.tentative)}</small></div>
    <div class="subtitle">${esc(meta.subtitle)}</div>
    <div class="meta">${info}</div>
  </header>
  ${blocks.map(brainBlock).join('\n')}
  </body></html>`;
  fs.writeFileSync(file, doc);
}

function buildHtml(file) {
  if (BRAIN) return buildHtmlBrain(file);
  const toc = blocks.filter((b) => b.type === 'h1').map((b) => `<li>${esc(b.text)}</li>`).join('');
  const info = meta.info.map(([k, v]) => `<tr><th>${esc(k)}</th><td>${esc(v)}</td></tr>`).join('');
  const css = `
  @page { size: A4; margin: 20mm; }
  * { -webkit-print-color-adjust: exact; print-color-adjust: exact; box-sizing: border-box; }
  body { font-family: "Apple SD Gothic Neo", "Malgun Gothic", sans-serif; font-size: 10pt; line-height: 1.6; color: #222; margin: 0; }
  .cover { height: 255mm; padding-top: 38mm; break-after: page; }
  .cover .label { color: #${C.accent}; font-weight: 700; font-size: 13pt; margin-bottom: 6px; }
  .cover .title { color: #${C.navy}; font-weight: 800; font-size: 30pt; line-height: 1.25; }
  .cover .title small { color: #${C.gray}; font-weight: 400; font-size: 13pt; margin-left: 8px; }
  .cover .subtitle { color: #${C.gray}; font-size: 12pt; padding-bottom: 12px; border-bottom: 3px solid #${C.navy}; margin-bottom: 30mm; }
  .cover table.info th { width: 25%; }
  .cover .toc-title { color: #${C.navy}; font-weight: 700; font-size: 12pt; margin-top: 20mm; margin-bottom: 4px; }
  .cover ul.toc { list-style: none; padding: 0; margin: 0; font-size: 10pt; line-height: 1.9; }
  h1 { color: #${C.navy}; font-size: 15pt; border-bottom: 2px solid #${C.accent}; padding-bottom: 4px; margin: 26px 0 10px; break-after: avoid; }
  h1.break { break-before: page; margin-top: 0; }
  h2 { color: #${C.accent}; font-size: 11.5pt; margin: 16px 0 6px; break-after: avoid; }
  p { margin: 4px 0 8px; }
  p.note { font-size: 8.5pt; color: #${C.gray}; margin-top: 2px; }
  ul, ol { margin: 4px 0 10px; padding-left: 22px; }
  li { margin: 2px 0; }
  table { width: 100%; border-collapse: collapse; margin: 6px 0 10px; font-size: 9pt; line-height: 1.45; }
  th, td { border: 1px solid #${C.border}; padding: 5px 7px; vertical-align: middle; }
  th { background: #${C.head}; font-weight: 700; text-align: center; }
  td.c { text-align: center; }
  tr { break-inside: avoid; }
  thead { display: table-header-group; }
  .callout, .terms { padding: 9px 13px; margin: 8px 0 12px; break-inside: avoid; }
  .callout { background: #${C.callout}; border-left: 4px solid #${C.accent}; }
  .terms { background: #${C.terms}; border-left: 4px solid #${C.border}; font-size: 8.8pt; }
  .box-title { font-weight: 700; color: #${C.accent}; margin-bottom: 3px; }
  .terms .box-title { color: #${C.gray}; }
  .callout ul, .terms ul { margin: 0; }
  figure { margin: 10px 0 14px; text-align: center; break-inside: avoid; }
  figure img { width: 100%; }
  figcaption { font-size: 8.5pt; color: #${C.gray}; margin-top: 4px; }
  `;
  const doc = `<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8"><title>${esc(DOC_TITLE)}</title><style>${css}</style></head><body>
  <section class="cover">
    <div class="label">${esc(meta.label)}</div>
    <div class="title">${esc(meta.title)}<small>${esc(meta.tentative)}</small></div>
    <div class="subtitle">${esc(meta.subtitle)}</div>
    <table class="info">${info}</table>
    <div class="toc-title">목차</div>
    <ul class="toc">${toc}</ul>
  </section>
  ${blocks.map(htmlBlock).join('\n')}
  </body></html>`;
  fs.writeFileSync(file, doc);
}

(async () => {
  await buildDocx(path.join(outDir, `${baseName}.docx`));
  buildHtml(path.join(WORK, `${baseName}.html`));
  console.log('built', baseName);
})();
