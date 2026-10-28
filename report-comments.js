// ============================================================================
// report-comments.js — recipe comments for the Excel batch report.
//
// The Brew Sheet has a "Comments:" block of single-line rows (A44:J44 …
// A52:J52, fixed height). The recipe comments (recipe_comments.comments, a
// text array) are word-wrapped onto those rows from the top; the rows below
// stay free for the brewers' own notes.
// Loaded in the browser (<script src="report-comments.js">) and in Node
// (require('../report-comments.js'), batch report generator).
// ============================================================================

const REPORT_COMMENT_FIRST_ROW = 44;
const REPORT_COMMENT_ROWS = 9;        // rows 44-52
// A:J is ~70 digit widths (Calibri 11); prose is narrower than digits
// (checked in a rendered report: 73 characters fill ~75% of the row).
const REPORT_COMMENT_LINE_WIDTH = 85;
// Rows 47-52 are centred in the template; rows 46-51 with a comment take the
// left-aligned style of A45 (same fill and border). Row 52 keeps its own
// style (bottom border).
const REPORT_COMMENT_STYLE_CELL = 'Brew Sheet!A45';

function wrapCommentText(text, width) {
  const lines = [];
  let line = '';
  for (let word of text.split(' ')) {
    while (word.length > width) {
      if (line) { lines.push(line); line = ''; }
      lines.push(word.slice(0, width));
      word = word.slice(width);
    }
    if (!word) continue;
    if (!line) line = word;
    else if (line.length + 1 + word.length <= width) line += ' ' + word;
    else { lines.push(line); line = word; }
  }
  if (line) lines.push(line);
  return lines;
}

// Returns at most maxRows lines. Each comment (and each line break inside
// one) starts on a new row; text that does not fit goes into the last row,
// so nothing is dropped from the cell.
function reportCommentLines(comments, width = REPORT_COMMENT_LINE_WIDTH, maxRows = REPORT_COMMENT_ROWS) {
  const list = Array.isArray(comments) ? comments : (comments ? [comments] : []);
  const lines = [];
  for (const comment of list) {
    for (const paragraph of String(comment ?? '').split(/\r?\n/)) {
      const clean = paragraph.replace(/\s+/g, ' ').trim();
      if (clean) lines.push(...wrapCommentText(clean, width));
    }
  }
  if (lines.length <= maxRows) return lines;
  return [...lines.slice(0, maxRows - 1), lines.slice(maxRows - 1).join(' ')];
}

// Cell → text for the Brew Sheet comment rows (only rows with text);
// styleFrom: cell whose style the row takes over.
function reportCommentCells(comments) {
  return reportCommentLines(comments).map((value, i) => {
    const row = REPORT_COMMENT_FIRST_ROW + i;
    const styleFrom = row >= 46 && row <= 51 ? REPORT_COMMENT_STYLE_CELL : null;
    return { cell: `Brew Sheet!A${row}`, value, styleFrom };
  });
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { reportCommentLines, reportCommentCells, REPORT_COMMENT_ROWS, REPORT_COMMENT_LINE_WIDTH };
}
