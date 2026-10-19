import json, re, sys, html, os

SRC = sys.argv[1]
OUT = sys.argv[2]
canvas = json.load(open(os.path.join(SRC, 'canvas.json')))
order = canvas['order']
boards = canvas['boards']

SHORT = {
    'Home.dc.html': 'Home', 'ActiveBatches.dc.html': 'Active batches', 'AllBatches.dc.html': 'All batches',
    'Overview.dc.html': 'Overview', 'Brewing.dc.html': 'Brewing', 'Main.dc.html': 'Fermentation log',
    'Processing.dc.html': 'Processing', 'Filling.dc.html': 'Filling', 'FillingReport.dc.html': 'Filling report',
    'Calculators.dc.html': 'Calculators (popup)', 'NanoFlavor.dc.html': 'Nano Flavor (popup)',
    'Settings.dc.html': 'Settings · action tags', 'BatchCreation.dc.html': 'Batch creation',
    'SplitBatch.dc.html': 'Split / transfer (popup)',
}
HOME = ('Home', 'ActiveBatches', 'AllBatches')
BATCH = ('Overview', 'Brewing', 'Main', 'Processing', 'Filling', 'FillingReport')
TAGS = r'(table|thead|tbody|tfoot|tr|td|th|select|option|colgroup|col)'


def scope_css(css, sel):
    out = []
    for m in re.finditer(r'([^{}]+)\{([^{}]*)\}', css):
        sels, body = m.group(1).strip(), m.group(2)
        parts = []
        for s in sels.split(','):
            s = s.strip()
            if not s:
                continue
            if s == 'body':
                parts.append(sel)
            elif s.startswith('body '):
                parts.append(sel + ' ' + s[5:])
            else:
                parts.append(sel + ' ' + s)
        out.append(', '.join(parts) + '{' + body + '}')
    return '\n'.join(out)


# Home first, then the rest in canvas order
ordered = [n for n in ('Home.dc.html', 'ActiveBatches.dc.html', 'AllBatches.dc.html') if n in order] + \
          [n for n in order if n not in ('Home.dc.html', 'ActiveBatches.dc.html', 'AllBatches.dc.html')]

parts_css, parts_tpl, parts_js, nav = [], [], [], []
for name in ordered:
    src = open(os.path.join(SRC, name)).read()
    key = re.sub(r'\W', '', name.replace('.dc.html', ''))
    style = ''
    hm = re.search(r'<helmet>(.*?)</helmet>', src, re.S)
    if hm:
        sm = re.search(r'<style>(.*?)</style>', hm.group(1), re.S)
        style = sm.group(1) if sm else ''
    xd = re.search(r'<x-dc>(.*?)</x-dc>', src, re.S).group(1)
    xd = re.sub(r'<helmet>.*?</helmet>', '', xd, flags=re.S)
    xd = re.sub(r'<(/?)' + TAGS + r'(?=[\s>/])', r'<\1x-\2', xd)
    sc = re.search(r'<script type="text/x-dc" data-dc-script data-props=\'(.*?)\'>(.*?)</script>', src, re.S)
    props = json.loads(html.unescape(sc.group(1)))
    defaults = {k: v.get('default') for k, v in props.items() if isinstance(v, dict) and 'default' in v and not k.startswith('$')}
    toggles = [k for k, v in props.items() if isinstance(v, dict) and v.get('editor') == 'boolean']
    fixed = 'expand' not in boards[name]
    parts_css.append(scope_css(style, '#b-' + key))
    parts_tpl.append('<template id="t-%s">%s</template>' % (key, xd))
    parts_js.append('BOARDS[%s] = { file: %s, title: %s, fixed: %s, w: %d, defaults: %s, toggles: %s, cls: (function(){\n%s\nreturn Component; })() };' % (
        json.dumps(key), json.dumps(name), json.dumps(SHORT.get(name, name)), 'true' if fixed else 'false', boards[name]['w'],
        json.dumps(defaults), json.dumps(toggles), sc.group(2)))
    nav.append((key, SHORT.get(name, name), fixed))

btn = lambda k, t: '<button type="button" data-k="%s">%s</button>' % (k, html.escape(t))
home_nav = ''.join(btn(k, t) for k, t, f in nav if k in HOME)
main_nav = ''.join(btn(k, t) for k, t, f in nav if k in BATCH)
extra_nav = ''.join(btn(k, t) for k, t, f in nav if k not in BATCH and k not in HOME)

RUNTIME = r'''
const BOARDS = {};
const SVGNS = 'http://www.w3.org/2000/svg';
class DCLogic {
  constructor(props) { this.props = props || {}; this.state = {}; }
  setState(o) { const p = typeof o === 'function' ? o(this.state, this.props) : o; this.state = Object.assign({}, this.state, p); if (this.__render) this.__queue(); }
  forceUpdate() { if (this.__render) this.__queue(); }
}
function lit(p) {
  if (p === 'true') return [true, true]; if (p === 'false') return [true, false]; if (p === 'null') return [true, null];
  if (/^-?\d+(\.\d+)?$/.test(p)) return [true, Number(p)];
  if (/^'.*'$|^".*"$/.test(p)) return [true, p.slice(1, -1)];
  return [false];
}
function resolve(path, scope) {
  path = path.trim(); const l = lit(path); if (l[0]) return l[1];
  const segs = path.split('.'); let v = scope[segs[0]];
  for (let i = 1; i < segs.length; i++) { if (v === null || v === undefined) return undefined; v = v[segs[i]]; }
  return v;
}
const WHOLE = /^\s*\{\{\s*([^}]+?)\s*\}\}\s*$/;
function interp(str, scope) { return str.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (m, p) => { const v = resolve(p, scope); return v === undefined || v === null ? '' : String(v); }); }
function attrVal(str, scope) { const m = str.match(WHOLE); return m ? resolve(m[1], scope) : interp(str, scope); }
function render(src, scope, inSvg) {
  const out = [];
  src.childNodes.forEach((node) => {
    if (node.nodeType === 3) { out.push(document.createTextNode(node.nodeValue.indexOf('{{') >= 0 ? interp(node.nodeValue, scope) : node.nodeValue)); return; }
    if (node.nodeType !== 1) return;
    const tag = node.localName;
    if (tag === 'sc-for') {
      const list = attrVal(node.getAttribute('list') || '', scope) || []; const as = node.getAttribute('as') || 'item';
      list.forEach((it, i) => { const sc = Object.create(scope); sc[as] = it; sc.$index = i; out.push(...render(node, sc, inSvg)); });
      return;
    }
    if (tag === 'sc-if') { if (attrVal(node.getAttribute('value') || '', scope)) out.push(...render(node, scope, inSvg)); return; }
    const real = tag.startsWith('x-') ? tag.slice(2) : tag;
    const svg = inSvg || node.namespaceURI === SVGNS || real === 'svg';
    const el = svg ? document.createElementNS(SVGNS, real) : document.createElement(real);
    let post = null;
    for (const a of Array.from(node.attributes)) {
      const n = a.name;
      if (n.startsWith('hint-')) continue;
      if (n.startsWith('on')) { const fn = attrVal(a.value, scope); if (typeof fn === 'function') el.addEventListener(n.slice(2) === 'change' ? 'change' : n.slice(2), fn); continue; }
      const v = attrVal(a.value, scope);
      if (n === 'checked' || n === 'disabled' || n === 'selected') { if (v === true || v === 'true') { el[n] = true; el.setAttribute(n, ''); } continue; }
      if (n === 'value' && (real === 'input' || real === 'select' || real === 'textarea')) { post = v === undefined || v === null ? '' : String(v); continue; }
      if (v === false || v === undefined || v === null) continue;
      el.setAttribute(n, String(v));
    }
    render(node, scope, svg).forEach((c) => el.appendChild(c));
    if (post !== null) { if (real === 'select') { el.value = post; } else el.value = post; }
    out.push(el);
  });
  return out;
}
const MOUNTED = {};
function mount(key) {
  const B = BOARDS[key]; const host = document.getElementById('b-' + key);
  if (MOUNTED[key]) return MOUNTED[key];
  const props = Object.assign({}, B.defaults); const inst = new B.cls(props); inst.props = props;
  const tpl = document.getElementById('t-' + key).content;
  let queued = false;
  inst.__render = () => {
    const vals = inst.renderVals ? inst.renderVals() : {};
    const scope = Object.assign(Object.create(null), vals);
    const frag = document.createDocumentFragment(); render(tpl, scope, false).forEach((n) => frag.appendChild(n));
    const y = window.scrollY; host.replaceChildren(frag); window.scrollTo(0, y);
  };
  inst.__queue = () => { if (queued) return; queued = true; Promise.resolve().then(() => { queued = false; inst.__render(); }); };
  host.addEventListener('click', (e) => {
    const a = e.target.closest('a[href]'); if (!a) return;
    const h = a.getAttribute('href');
    if (h === '#') { e.preventDefault(); return; }
    const m = h.match(/([A-Za-z]+)\.dc\.html$/); if (m && BOARDS[m[1]]) { e.preventDefault(); show(m[1]); }
  });
  inst.__render(); MOUNTED[key] = inst; return inst;
}
function show(key) {
  if (!BOARDS[key]) key = 'Home';
  if (!BOARDS[key]) key = Object.keys(BOARDS)[0];
  document.querySelectorAll('.board').forEach((b) => { b.hidden = b.id !== 'b-' + key; });
  document.querySelectorAll('#bar button[data-k]').forEach((b) => b.classList.toggle('on', b.dataset.k === key));
  const inst = mount(key);
  const B = BOARDS[key]; const tg = document.getElementById('toggles'); tg.replaceChildren();
  B.toggles.forEach((t) => {
    const lab = document.createElement('label'); const cb = document.createElement('input'); cb.type = 'checkbox'; cb.checked = !!inst.props[t];
    cb.addEventListener('change', () => { inst.props[t] = cb.checked; inst.__render(); });
    lab.appendChild(cb); lab.appendChild(document.createTextNode(' ' + t.replace(/^recipe/, 'recipe ').replace(/([A-Z])/g, ' $1').toLowerCase()));
    tg.appendChild(lab);
  });
  tg.hidden = !B.toggles.length;
  if (location.hash.slice(1) !== key) history.replaceState(null, '', '#' + key);
  window.scrollTo(0, 0);
}
document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('#bar button[data-k]').forEach((b) => b.addEventListener('click', () => show(b.dataset.k)));
  show(location.hash.slice(1) || 'Home');
});
window.addEventListener('hashchange', () => show(location.hash.slice(1)));
'''

boards_html = ''.join('<div class="board%s" id="b-%s" hidden></div>' % (' fixed' if f else '', k) for k, t, f in nav)

page = '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Jopen batch report · mockup</title>
<style>
html,body{margin:0;background:#f6f4ee}
#bar{position:sticky;top:0;z-index:40;background:#1c2b26;color:#fff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,Helvetica,sans-serif;display:flex;flex-wrap:wrap;align-items:center;gap:6px 14px;padding:8px 16px;font-size:13px}
#bar .t{font-weight:700;margin-right:6px}
#bar .grp{display:flex;flex-wrap:wrap;gap:4px;align-items:center}
#bar .grp span{opacity:.6;font-size:11px;text-transform:uppercase;letter-spacing:.08em;margin-right:2px}
#bar button{background:transparent;color:#dfe7da;border:1px solid rgba(255,255,255,.18);border-radius:16px;padding:5px 11px;font:inherit;cursor:pointer}
#bar button:hover{border-color:#fff;color:#fff}
#bar button.on{background:#b4772c;border-color:#b4772c;color:#fff;font-weight:700}
#toggles{display:flex;gap:12px;flex-wrap:wrap;margin-left:auto;font-size:12px;color:#dfe7da}
#toggles label{display:inline-flex;gap:5px;align-items:center;cursor:pointer}
#note{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,Helvetica,sans-serif;font-size:12px;color:#6b6355;background:#fdf1d8;padding:6px 16px}
.board.fixed{display:flex;justify-content:center;padding:24px 0;overflow:auto}
.board[hidden]{display:none}
%s
</style>
</head>
<body>
<div id="bar">
  <span class="t">Batch report · mockup</span>
  <div class="grp"><span>Home</span>%s</div>
  <div class="grp"><span>Batch</span>%s</div>
  <div class="grp"><span>Extra</span>%s</div>
  <div id="toggles" hidden></div>
</div>
<div id="note">Mockup with example data — nothing is saved. Calculated fields update when you leave an input field. Scenario switches (top right) show variants, e.g. a recipe with Nagardo.</div>
%s
%s
<script>
%s
%s
</script>
</body>
</html>''' % ('\n'.join(parts_css), home_nav, main_nav, extra_nav, boards_html, '\n'.join(parts_tpl), RUNTIME, '\n'.join(parts_js))
open(OUT, 'w').write(page)
print('written', len(page))
