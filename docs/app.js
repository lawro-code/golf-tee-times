const DATA_URL = 'data/teetimes.json';

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

function formatLastUpdated(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  const day = DAY_NAMES_SHORT[d.getDay()];
  const dd = d.getDate();
  const mon = MONTHS_SHORT[d.getMonth()];
  let h = d.getHours();
  const m = d.getMinutes();
  const mer = h < 12 ? 'am' : 'pm';
  h = h % 12 === 0 ? 12 : h % 12;
  return `Refreshed ${day} ${dd} ${mon} · ${h}:${String(m).padStart(2, '0')} ${mer}`;
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
    dayDiv.appendChild(el('h2', 'day-heading', formatDayHeadingLong(date)));

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

async function init() {
  try {
    const resp = await fetch(`${DATA_URL}?t=${Date.now()}`);
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    state.data = await resp.json();
  } catch (e) {
    els.results.innerHTML = `<p class="empty">Could not load tee times: ${e.message}</p>`;
    els.lastUpdated.textContent = '';
    return;
  }
  els.lastUpdated.textContent = formatLastUpdated(state.data.generated_at);
  populateFilters();
  bindFilters();
  render();
}

init();
