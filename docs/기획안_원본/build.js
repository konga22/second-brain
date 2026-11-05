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
const C = {
  navy: '1F3A5F', accent: '2E6DB4', text: '222222', gray: '666666',
  head: 'DCE6F2', border: 'B8C4D2', callout: 'EEF3F9', terms: 'F6F7F9',
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
        border: { bottom: { style: BorderStyle.SINGLE, size: 12, color: C.accent, space: 4 } },
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
      ], C.callout, C.accent), spacer()];
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
          children: [new ImageRun({ type: 'png', data, transformation: { width: IMG_W, height: Math.round(IMG_W * 760 / 1600) } })],
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
      border: { bottom: { style: BorderStyle.SINGLE, size: 18, color: C.navy, space: 8 } },
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
          run: { font: FONT_ATTR, size: 23, bold: true, color: C.accent },
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

function buildHtml(file) {
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
