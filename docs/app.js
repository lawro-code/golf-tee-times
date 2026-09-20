// Stage 2. The site used to read a JSON file the old scraper committed to
// git (`docs/data/teetimes.json`); the scraper now writes to Supabase instead
// (BUILD-PLAN.md, track A) and nothing commits that file any more. Below is a
// live fetch against the same project the iOS app reads, reshaped into
// EXACTLY the object this file was already written against — nested
// `course.slots[]`, `slot.date`/`slot.time`/`slot.price_tiers` — so the
// renderer beneath this function needed no changes at all. The two moving
// pieces are `SUPABASE_URL`/`SUPABASE_ANON_KEY` (below) and `fetchLiveData()`;
// everything from `populateFilters()` down is untouched Stage-1-era code.
const SUPABASE_URL = 'https://ipzhqvsyxyjndpbmpibw.supabase.co';
// The anon (publishable) key. Not a secret — every table it can reach is
// behind RLS (supabase/migrations/0004_rls.sql) and this key is meant to sit
// in a public client. The service role key is a different matter and does
// not belong in this file or in git.
const SUPABASE_ANON_KEY = 'sb_publishable_hWDRhTPRgPBSgmHvuzlEWQ_P6TDcWiA';

async function supabaseSelect(table, params) {
  const url = `${SUPABASE_URL}/rest/v1/${table}?${params}`;
  const resp = await fetch(url, {
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` },
  });
  if (!resp.ok) throw new Error(`${table}: HTTP ${resp.status}`);
  return resp.json();
}

async function fetchLiveData() {
  const [courseRows, slotRows, freshnessRows] = await Promise.all([
    supabaseSelect('courses', 'select=slug,name,region,holes,drive_minutes_from_bondi,address,active&active=eq.true&order=sort_order.asc'),
    supabaseSelect('open_slots', 'select=course_slug,tee_date,tee_time,spots_available,price_tiers,booking_url&order=tee_date.asc,tee_time.asc'),
    supabaseSelect('course_freshness', 'select=last_success_at'),
  ]);

  const slotsBySlug = new Map();
  for (const row of slotRows) {
    if (!slotsBySlug.has(row.course_slug)) slotsBySlug.set(row.course_slug, []);
    slotsBySlug.get(row.course_slug).push({
      date: row.tee_date,
      time: row.tee_time,
      spots_available: row.spots_available,
      price_tiers: row.price_tiers || [],
      booking_url: row.booking_url,
    });
  }

  const courses = courseRows.map(c => ({
    slug: c.slug,
    name: c.name,
    region: c.region,
    holes: c.holes,
    drive_minutes_from_bondi: c.drive_minutes_from_bondi,
    address: c.address,
    slots: slotsBySlug.get(c.slug) || [],
  }));

  // The closest live equivalent of the old payload's single `generated_at`
  // stamp: the most recent moment ANY course was actually reached. Nil (every
  // course still `last_success_at: null`) means nothing has scraped yet —
  // an honest state right after Stage 2's migrations land and before the
  // first write with a real service-role key.
  const successTimes = freshnessRows.map(r => r.last_success_at).filter(Boolean);
  const generatedAt = successTimes.length
    ? new Date(Math.max(...successTimes.map(t => new Date(t).getTime()))).toISOString()
    : null;

  return { courses, generated_at: generatedAt };
}

const state = {
  data: null,
  filters: { day: '', time: '', price: '', course: '', holes: '', players: '' },
};

const els = {
  lastUpdated: document.getElementById('last-updated'),
  results: document.getElementById('results'),
  filterDay: document.getElementById('filter-day'),
  filterTime: document.getElementById('filter-time'),
  filterPrice: document.getElementById('filter-price'),
  filterCourse: document.getElementById('filter-course'),
  filterHoles: document.getElementById('filter-holes'),
  filterPlayers: document.getElementById('filter-players'),
  reset: document.getElementById('reset-filters'),
};

const DAY_NAMES_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const DAY_NAMES_LONG = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const MONTHS_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function parseISODate(s) {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d);
}

function formatDayHeadingLong(dateStr) {
  const d = parseISODate(dateStr);
  return `${DAY_NAMES_LONG[d.getDay()]}, ${MONTHS[d.getMonth()]} ${d.getDate()}`;
}

function formatDayHeadingShort(dateStr) {
  const d = parseISODate(dateStr);
  return `${DAY_NAMES_LONG[d.getDay()]}, ${d.getDate()} ${MONTHS_SHORT[d.getMonth()]}`;
}

function formatTime(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  const meridiem = h < 12 ? 'am' : 'pm';
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}:${String(m).padStart(2, '0')} ${meridiem}`;
}

function timeBucket(hhmm) {
  const h = parseInt(hhmm.split(':')[0], 10);
  if (h < 12) return 'morning';
  if (h < 16) return 'afternoon';
  return 'twilight';
}

function sortedTiers(slot) {
  if (!slot.price_tiers || !slot.price_tiers.length) return [];
  return [...slot.price_tiers].sort((a, b) => a.amount - b.amount);
}

function isTwilightTier(tier) {
  return tier && /twilight/i.test(tier.label);
}

// Every other timestamp formatter in this codebase (scraper/cadence.py, the
// Deno edge function's formatSydneyDay/formatSydneyTime, the iOS
// SlotFormatting/ContractDecoding types) pins Australia/Sydney explicitly
// (CONTRACT.md §4: "the client never recomputes it"). This one has to match:
// `new Date(iso)` + `.getDay()/.getHours()/...` reads in the VISITOR's local
// timezone, which silently produced the wrong day/time for anyone whose
// browser clock isn't set to Sydney. Intl's `timeZone` option is the only
// piece of this that must NOT default to the visitor's locale.
const LAST_UPDATED_FORMAT = new Intl.DateTimeFormat('en-AU', {
  timeZone: 'Australia/Sydney',
  weekday: 'short',
  day: 'numeric',
  month: 'short',
  hour: 'numeric',
  minute: '2-digit',
  hour12: true,
});

function formatLastUpdated(iso) {
  if (!iso) return '';
  const parts = LAST_UPDATED_FORMAT.formatToParts(new Date(iso));
  const pick = (type) => parts.find((p) => p.type === type)?.value ?? '';
  // en-AU renders month as "Sept" (four letters) — slice to the three-letter
  // abbreviation this UI uses everywhere else (MONTHS_SHORT above).
  const day = pick('weekday').slice(0, 3);
  const dd = pick('day');
  const mon = pick('month').slice(0, 3);
  const hour = pick('hour');
  const minute = pick('minute');
  const mer = pick('dayPeriod').toLowerCase();
  return `Refreshed ${day} ${dd} ${mon} · ${hour}:${minute} ${mer}`;
}

function el(tag, className, text) {
  const e = document.createElement(tag);
  if (className) e.className = className;
  if (text != null) e.textContent = text;
  return e;
}

function populateFilters() {
  const dates = new Set();
  const courses = new Map();
  for (const c of state.data.courses) {
    courses.set(c.slug, c.name);
    for (const s of c.slots) dates.add(s.date);
  }
  for (const d of [...dates].sort()) {
    const opt = document.createElement('option');
    opt.value = d;
    opt.textContent = formatDayHeadingShort(d);
    els.filterDay.appendChild(opt);
  }
  for (const [slug, name] of [...courses.entries()].sort((a, b) => a[1].localeCompare(b[1]))) {
    const opt = document.createElement('option');
    opt.value = slug;
    opt.textContent = name;
    els.filterCourse.appendChild(opt);
  }
}

function filterSlot(course, slot) {
  if (state.filters.day && slot.date !== state.filters.day) return false;
  if (state.filters.course && course.slug !== state.filters.course) return false;
  if (state.filters.holes && String(course.holes) !== state.filters.holes) return false;
  if (state.filters.time && timeBucket(slot.time) !== state.filters.time) return false;
  if (state.filters.players && slot.spots_available < parseInt(state.filters.players, 10)) return false;
  if (state.filters.price) {
    const max = parseFloat(state.filters.price);
    const tiers = sortedTiers(slot);
    if (!tiers.length || tiers[0].amount > max) return false;
  }
  return true;
}

function mapHref(course) {
  const q = encodeURIComponent(course.address ? course.address : `${course.name} Sydney`);
  return `https://www.google.com/maps/search/?api=1&query=${q}`;
}

function buildCourseMeta(course) {
  const bits = [];
  if (course.drive_minutes_from_bondi != null) bits.push(`${course.drive_minutes_from_bondi} min from Bondi`);
  if (course.holes) bits.push(`${course.holes} holes`);
  if (course.region) bits.push(course.region);

  const wrap = el('span', 'course-meta');
  bits.forEach((b, i) => {
    if (i > 0) wrap.appendChild(el('span', 'course-meta-divider', '·'));
    wrap.appendChild(document.createTextNode(b));
  });

  wrap.appendChild(el('span', 'course-meta-divider', '·'));
  const mapLink = document.createElement('a');
  mapLink.href = mapHref(course);
  mapLink.target = '_blank';
  mapLink.rel = 'noopener';
  mapLink.className = 'course-map-link';
  mapLink.textContent = 'Map';
  wrap.appendChild(mapLink);

  return wrap;
}

function buildSlot(slot) {
  const a = document.createElement('a');
  a.className = 'slot';
  a.href = slot.booking_url;
  a.target = '_blank';
  a.rel = 'noopener';

  const left = el('div', 'slot-left');
  left.appendChild(el('div', 'slot-time', formatTime(slot.time)));
  const subLabel = `${slot.spots_available} spot${slot.spots_available === 1 ? '' : 's'}`;
  left.appendChild(el('div', 'slot-sub', subLabel));
  a.appendChild(left);

  const right = el('div', 'slot-right');
  const tiers = sortedTiers(slot);
  if (tiers.length) {
    const cheapest = tiers[0];
    const priceEl = el('div', 'slot-price', `$${Math.round(cheapest.amount)}`);
    if (isTwilightTier(cheapest)) priceEl.classList.add('twilight');
    right.appendChild(priceEl);

    if (tiers.length > 1) {
      const extra = tiers[tiers.length - 1];
      const label = extra.label ? extra.label.replace(/\s*\d{4}\s*$/, '').trim() : '';
      right.appendChild(el('div', 'slot-price-extra', label ? `or $${Math.round(extra.amount)} ${label}` : `or $${Math.round(extra.amount)}`));
    }
  }
  a.appendChild(right);
  return a;
}

function render() {
  els.results.innerHTML = '';
  const byDate = new Map();
  for (const course of state.data.courses) {
    for (const slot of course.slots) {
      if (!filterSlot(course, slot)) continue;
      if (!byDate.has(slot.date)) byDate.set(slot.date, new Map());
      const byCourse = byDate.get(slot.date);
      if (!byCourse.has(course.slug)) byCourse.set(course.slug, { course, slots: [] });
      byCourse.get(course.slug).slots.push(slot);
    }
  }

  if (byDate.size === 0) {
    els.results.appendChild(el('p', 'empty', 'No tee times match those filters.'));
    return;
  }

  const sortedDates = [...byDate.keys()].sort();
  for (const date of sortedDates) {
    const dayDiv = el('section', 'day-group');
    const heading = el('h2', 'day-heading');
    heading.innerHTML = `<svg class="day-flag" aria-hidden="true"><use href="#i-flag"/></svg><span>${formatDayHeadingLong(date)}</span>`;
    dayDiv.appendChild(heading);

    const courseEntries = [...byDate.get(date).values()].sort((a, b) =>
      (a.course.drive_minutes_from_bondi || 999) - (b.course.drive_minutes_from_bondi || 999)
    );

    for (const { course, slots } of courseEntries) {
      const block = el('div', 'course-block');

      const header = el('div', 'course-header');
      header.appendChild(el('span', 'course-name', course.name));
      header.appendChild(buildCourseMeta(course));
      block.appendChild(header);

      const list = el('div', 'slot-list');
      slots.sort((a, b) => a.time.localeCompare(b.time));
      for (const slot of slots) list.appendChild(buildSlot(slot));
      block.appendChild(list);

      dayDiv.appendChild(block);
    }
    els.results.appendChild(dayDiv);
  }
}

function bindFilters() {
  const onChange = (key) => (e) => { state.filters[key] = e.target.value; render(); };
  els.filterDay.addEventListener('change', onChange('day'));
  els.filterTime.addEventListener('change', onChange('time'));
  els.filterPrice.addEventListener('change', onChange('price'));
  els.filterCourse.addEventListener('change', onChange('course'));
  els.filterHoles.addEventListener('change', onChange('holes'));
  els.filterPlayers.addEventListener('change', onChange('players'));
  els.reset.addEventListener('click', () => {
    state.filters = { day: '', time: '', price: '', course: '', holes: '', players: '' };
    [els.filterDay, els.filterTime, els.filterPrice, els.filterCourse, els.filterHoles, els.filterPlayers].forEach(s => s.value = '');
    render();
  });
}

function bindTabs() {
  const tabs = document.querySelectorAll('.tab');
  const panels = document.querySelectorAll('.panel');
  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      const target = tab.dataset.tab;
      tabs.forEach(t => {
        t.classList.toggle('active', t === tab);
        t.setAttribute('aria-selected', t === tab ? 'true' : 'false');
      });
      panels.forEach(p => p.classList.toggle('active', p.id === `panel-${target}`));
      window.scrollTo({ top: 0, behavior: 'smooth' });
    });
  });
}

async function init() {
  bindTabs();
  try {
    state.data = await fetchLiveData();
  } catch (e) {
    els.results.innerHTML = `<p class="empty">Could not load tee times: ${e.message}</p>`;
    els.lastUpdated.textContent = '';
    return;
  }
  els.lastUpdated.textContent = formatLastUpdated(state.data.generated_at);
  populateFilters();
  bindFilters();
  render();

  window.GOLF_COURSES = state.data.courses;
  window.dispatchEvent(new CustomEvent('golf-courses-ready', { detail: state.data.courses }));
}

init();
