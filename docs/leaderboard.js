const SUPABASE_URL = 'https://ptfnuqwebttcknvsoajx.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB0Zm51cXdlYnR0Y2tudnNvYWp4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg4MDM2MDgsImV4cCI6MjA5NDM3OTYwOH0.WRdou-W-gcruMc6qA8gXkV5hf_IDkQ4G3vNK2A2ljSI';

const NAME_KEY = 'golf.lastPlayerName';
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const lbEls = {
  openSubmit: document.getElementById('open-submit'),
  cancelSubmit: document.getElementById('cancel-submit'),
  form: document.getElementById('submit-form'),
  formMessage: document.getElementById('form-message'),
  fName: document.getElementById('f-name'),
  fCourse: document.getElementById('f-course'),
  fDate: document.getElementById('f-date'),
  fHoles: document.getElementById('f-holes'),
  fScore: document.getElementById('f-score'),
  fHandicap: document.getElementById('f-handicap'),
  fNotes: document.getElementById('f-notes'),
  tabs: document.querySelectorAll('.lb-tab'),
  content: document.getElementById('leaderboard-content'),
  roundOfWeekWrap: document.getElementById('round-of-week'),
  roundOfWeek: document.getElementById('row-callout'),
};

const lb = {
  scores: [],
  courses: [],
  view: 'recent',
};

const MONTHS_SHORT_LB = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function el(tag, className, text) {
  const e = document.createElement(tag);
  if (className) e.className = className;
  if (text != null) e.textContent = text;
  return e;
}

function parForRound(score) {
  const c = lb.courses.find(c => c.slug === score.course_slug);
  if (!c || c.par == null) return null;
  if (score.holes === c.holes) return c.par;
  if (score.holes === 9 && c.holes === 18) return Math.round(c.par / 2);
  return c.par;
}

function toParGross(score) {
  const par = parForRound(score);
  return par == null ? null : score.gross_score - par;
}

function netScore(score) {
  if (score.handicap == null) return null;
  const hcpApplied = score.holes === 9 ? score.handicap / 2 : score.handicap;
  return score.gross_score - hcpApplied;
}

function toParNet(score) {
  const par = parForRound(score);
  const net = netScore(score);
  if (par == null || net == null) return null;
  return net - par;
}

function formatToPar(v) {
  if (v == null) return '';
  const rounded = Math.round(v * 10) / 10;
  if (rounded === 0) return 'E';
  return rounded > 0 ? `+${rounded}` : `${rounded}`;
}

function toParClass(v) {
  if (v == null) return '';
  if (v < 0) return 'tp-under';
  if (v === 0) return 'tp-even';
  if (v <= 5) return 'tp-near';
  return 'tp-over';
}

function bestForRanking(score) {
  // Lower is better. Prefer net-to-par, fall back to gross-to-par, fall back to gross.
  const n = toParNet(score);
  if (n != null) return n;
  const g = toParGross(score);
  if (g != null) return g;
  return score.gross_score;
}

function formatDateShort(iso) {
  if (!iso) return '';
  const [y, m, d] = iso.split('T')[0].split('-').map(Number);
  return `${d} ${MONTHS_SHORT_LB[m - 1]}`;
}

function todayISO() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function populateCourseSelect() {
  lbEls.fCourse.innerHTML = '';
  for (const c of lb.courses) {
    const opt = document.createElement('option');
    opt.value = c.slug;
    opt.textContent = c.name;
    lbEls.fCourse.appendChild(opt);
  }
  const other = document.createElement('option');
  other.value = '__other__';
  other.textContent = 'Other (not listed)';
  lbEls.fCourse.appendChild(other);
}

function showForm() {
  lbEls.form.hidden = false;
  lbEls.fDate.value = todayISO();
  const savedName = localStorage.getItem(NAME_KEY);
  if (savedName && !lbEls.fName.value) lbEls.fName.value = savedName;
  const savedHcp = localStorage.getItem('golf.lastHandicap');
  if (savedHcp && !lbEls.fHandicap.value) lbEls.fHandicap.value = savedHcp;
  lbEls.fName.focus();
  lbEls.openSubmit.hidden = true;
}

function hideForm() {
  lbEls.form.hidden = true;
  lbEls.openSubmit.hidden = false;
  lbEls.formMessage.textContent = '';
  lbEls.formMessage.className = 'form-message';
}

async function fetchScores() {
  const { data, error } = await sb
    .from('scores')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(500);
  if (error) {
    lbEls.content.innerHTML = `<p class="empty">Could not load scores: ${error.message}</p>`;
    return;
  }
  lb.scores = data || [];
  renderRoundOfWeek();
  renderView();
}

function renderRoundOfWeek() {
  const now = new Date();
  const weekAgo = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
  const recent = lb.scores.filter(s => new Date(s.played_at) >= weekAgo);
  if (!recent.length) {
    lbEls.roundOfWeekWrap.hidden = true;
    return;
  }
  // Best score in the last 7 days by best-to-par (net if available, else gross-to-par, else gross).
  const best = recent.reduce((m, s) => (bestForRanking(s) < bestForRanking(m) ? s : m), recent[0]);

  lbEls.roundOfWeekWrap.hidden = false;
  lbEls.roundOfWeek.innerHTML = '';

  const left = el('div', 'row-callout-left');
  const tp = toParNet(best) != null ? toParNet(best) : toParGross(best);
  if (tp != null) {
    const scoreEl = el('div', 'row-score', formatToPar(tp));
    if (tp < 0) scoreEl.classList.add('under-par');
    left.appendChild(scoreEl);
    left.appendChild(el('div', 'row-score-sub', toParNet(best) != null ? 'net to par' : 'to par'));
  } else {
    left.appendChild(el('div', 'row-score', best.gross_score));
    left.appendChild(el('div', 'row-score-sub', `${best.holes} holes`));
  }
  lbEls.roundOfWeek.appendChild(left);

  const right = el('div', 'row-callout-right');
  right.appendChild(el('div', 'row-player', best.player_name));
  right.appendChild(el('div', 'row-course', `${best.course_name} · ${best.gross_score} gross · ${best.holes}H`));
  right.appendChild(el('div', 'row-date', formatDateShort(best.played_at)));
  if (best.notes) right.appendChild(el('div', 'row-notes', `“${best.notes}”`));
  lbEls.roundOfWeek.appendChild(right);
}

function renderView() {
  if (!lb.scores.length) {
    lbEls.content.innerHTML = `
      <div class="empty-state">
        <svg class="empty-flag" aria-hidden="true"><use href="#i-flag"/></svg>
        <p class="empty">No rounds in the clubhouse yet.</p>
        <p class="empty-sub">Be the first to sign the scorecard.</p>
      </div>`;
    return;
  }
  if (lb.view === 'recent') return renderRecent();
  if (lb.view === 'best') return renderBest();
  if (lb.view === 'players') return renderPlayers();
}

function buildTable(headers, rows) {
  const wrap = el('div', 'lb-table-wrap');
  const table = el('table', 'lb-table');
  const thead = el('thead');
  const trh = el('tr');
  for (const h of headers) trh.appendChild(el('th', null, h));
  thead.appendChild(trh);
  table.appendChild(thead);
  const tbody = el('tbody');
  for (const r of rows) {
    const tr = el('tr');
    for (const cell of r) {
      if (cell instanceof Node) {
        const td = el('td');
        td.appendChild(cell);
        tr.appendChild(td);
      } else {
        tr.appendChild(el('td', null, cell == null ? '' : String(cell)));
      }
    }
    tbody.appendChild(tr);
  }
  table.appendChild(tbody);
  wrap.appendChild(table);
  return wrap;
}

function renderRecent() {
  lbEls.content.innerHTML = '';
  const rows = lb.scores.slice(0, 50).map((s) => {
    const tp = toParGross(s);
    const tpCell = tp != null
      ? el('span', `lb-topar ${toParClass(tp)}`, formatToPar(tp))
      : '';
    return [
      formatDateShort(s.played_at),
      s.player_name,
      s.course_name,
      `${s.holes}H`,
      el('span', 'lb-score', s.gross_score),
      tpCell,
      s.notes || '',
    ];
  });
  lbEls.content.appendChild(buildTable(['Date', 'Player', 'Course', '', 'Gross', 'To Par', 'Notes'], rows));
}

function renderBest() {
  lbEls.content.innerHTML = '';
  // Best score per player by best-to-par (net preferred), 18-hole only.
  const eighteens = lb.scores.filter(s => s.holes === 18);
  if (!eighteens.length) {
    lbEls.content.innerHTML = '<p class="empty">No 18-hole rounds yet.</p>';
    return;
  }
  const bestByPlayer = new Map();
  for (const s of eighteens) {
    const key = s.player_name.toLowerCase();
    const prev = bestByPlayer.get(key);
    if (!prev || bestForRanking(s) < bestForRanking(prev)) bestByPlayer.set(key, s);
  }
  const ranked = [...bestByPlayer.values()].sort((a, b) => bestForRanking(a) - bestForRanking(b));
  const rows = ranked.map((s, i) => {
    const rank = el('span', `lb-rank rank-${i + 1}`, `${i + 1}`);
    const gross = el('span', 'lb-score', s.gross_score);
    const tpGross = toParGross(s);
    const tpGrossCell = tpGross != null
      ? el('span', `lb-topar ${toParClass(tpGross)}`, formatToPar(tpGross))
      : '';
    const tpNet = toParNet(s);
    const tpNetCell = tpNet != null
      ? el('span', `lb-topar ${toParClass(tpNet)}`, formatToPar(tpNet))
      : '—';
    const hcpCell = s.handicap != null ? String(s.handicap) : '—';
    return [rank, s.player_name, s.course_name, formatDateShort(s.played_at), gross, tpGrossCell, hcpCell, tpNetCell];
  });
  lbEls.content.appendChild(buildTable(['#', 'Player', 'Course', 'Date', 'Gross', 'To Par', 'HCP', 'Net'], rows));
}

function renderPlayers() {
  lbEls.content.innerHTML = '';
  const stats = new Map();
  for (const s of lb.scores) {
    const key = s.player_name.trim();
    if (!stats.has(key)) stats.set(key, { name: key, count: 0, bestTp: Infinity, bestRound: null, totalTp: 0, tpCount: 0 });
    const st = stats.get(key);
    st.count += 1;
    if (s.holes === 18) {
      const tp = toParNet(s) != null ? toParNet(s) : toParGross(s);
      if (tp != null) {
        if (tp < st.bestTp) {
          st.bestTp = tp;
          st.bestRound = s;
        }
        st.totalTp += tp;
        st.tpCount += 1;
      }
    }
  }
  const ranked = [...stats.values()].sort((a, b) => {
    if (a.bestTp !== b.bestTp) return a.bestTp - b.bestTp;
    return b.count - a.count;
  });
  const rows = ranked.map((p, i) => {
    const bestCell = p.bestTp === Infinity
      ? '—'
      : el('span', `lb-topar ${toParClass(p.bestTp)}`, formatToPar(p.bestTp));
    const avgCell = p.tpCount > 0
      ? el('span', `lb-topar ${toParClass(p.totalTp / p.tpCount)}`, formatToPar(p.totalTp / p.tpCount))
      : '—';
    return [`${i + 1}`, p.name, p.count, bestCell, avgCell];
  });
  lbEls.content.appendChild(buildTable(['#', 'Player', 'Rounds', 'Best to par (18)', 'Avg to par (18)'], rows));
}

function bindLeaderboardTabs() {
  lbEls.tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      lbEls.tabs.forEach(t => {
        t.classList.toggle('active', t === tab);
        t.setAttribute('aria-selected', t === tab ? 'true' : 'false');
      });
      lb.view = tab.dataset.view;
      renderView();
    });
  });
}

async function handleSubmit(e) {
  e.preventDefault();
  lbEls.formMessage.textContent = '';
  lbEls.formMessage.className = 'form-message';

  const courseSlug = lbEls.fCourse.value;
  let courseName = '';
  if (courseSlug === '__other__') {
    courseName = prompt('Course name?');
    if (!courseName) return;
  } else {
    const c = lb.courses.find(x => x.slug === courseSlug);
    courseName = c ? c.name : courseSlug;
  }

  const hcpVal = lbEls.fHandicap.value.trim();
  const payload = {
    player_name: lbEls.fName.value.trim(),
    course_slug: courseSlug,
    course_name: courseName,
    played_at: lbEls.fDate.value,
    holes: parseInt(lbEls.fHoles.value, 10),
    gross_score: parseInt(lbEls.fScore.value, 10),
    handicap: hcpVal === '' ? null : parseFloat(hcpVal),
    notes: lbEls.fNotes.value.trim() || null,
  };

  if (!payload.player_name || !payload.played_at || !payload.holes || !payload.gross_score) {
    lbEls.formMessage.textContent = 'Please fill in name, date, holes and score.';
    lbEls.formMessage.classList.add('error');
    return;
  }

  const submitBtn = lbEls.form.querySelector('button[type=submit]');
  submitBtn.disabled = true;
  submitBtn.textContent = 'Saving…';

  const { error } = await sb.from('scores').insert(payload);

  submitBtn.disabled = false;
  submitBtn.textContent = 'Save round';

  if (error) {
    lbEls.formMessage.textContent = `Save failed: ${error.message}`;
    lbEls.formMessage.classList.add('error');
    return;
  }

  localStorage.setItem(NAME_KEY, payload.player_name);
  if (payload.handicap != null) localStorage.setItem('golf.lastHandicap', String(payload.handicap));
  lbEls.fScore.value = '';
  lbEls.fNotes.value = '';
  lbEls.formMessage.textContent = 'Round saved.';
  lbEls.formMessage.classList.add('success');
  await fetchScores();
  setTimeout(hideForm, 1200);
}

function initLeaderboard(courses) {
  lb.courses = courses;
  populateCourseSelect();
  lbEls.fDate.value = todayISO();
  lbEls.openSubmit.addEventListener('click', showForm);
  lbEls.cancelSubmit.addEventListener('click', hideForm);
  lbEls.form.addEventListener('submit', handleSubmit);
  bindLeaderboardTabs();
  fetchScores();
}

if (window.GOLF_COURSES) {
  initLeaderboard(window.GOLF_COURSES);
} else {
  window.addEventListener('golf-courses-ready', (e) => initLeaderboard(e.detail));
}
