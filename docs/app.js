const DATA_URL = 'data/teetimes.json';

const state = {
  data: null,
  filters: { day: '', time: '', price: '', course: '', holes: '' },
};

const els = {
  lastUpdated: document.getElementById('last-updated'),
  results: document.getElementById('results'),
  filterDay: document.getElementById('filter-day'),
  filterTime: document.getElementById('filter-time'),
  filterPrice: document.getElementById('filter-price'),
  filterCourse: document.getElementById('filter-course'),
  filterHoles: document.getElementById('filter-holes'),
  reset: document.getElementById('reset-filters'),
};

const DAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const DAY_NAMES_LONG = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function parseISODate(s) {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d);
}

function formatDayHeading(dateStr) {
  const d = parseISODate(dateStr);
  return `${DAY_NAMES_LONG[d.getDay()]} ${d.getDate()} ${MONTHS[d.getMonth()]}`;
}

function formatTime(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  const meridiem = h < 12 ? 'am' : 'pm';
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}:${String(m).padStart(2, '0')}${meridiem}`;
}

function timeBucket(hhmm) {
  const h = parseInt(hhmm.split(':')[0], 10);
  if (h < 12) return 'morning';
  if (h < 16) return 'afternoon';
  return 'twilight';
}

function cheapestTier(slot) {
  if (!slot.price_tiers || !slot.price_tiers.length) return null;
  return slot.price_tiers.reduce((min, t) => (min === null || t.amount < min.amount ? t : min), null);
}

function isTwilightTier(tier) {
  return tier && /twilight/i.test(tier.label);
}

function formatLastUpdated(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  const day = DAY_NAMES[d.getDay()];
  const dd = d.getDate();
  const mon = MONTHS[d.getMonth()];
  let h = d.getHours();
  const m = d.getMinutes();
  const mer = h < 12 ? 'am' : 'pm';
  h = h % 12 === 0 ? 12 : h % 12;
  return `Last updated ${day} ${dd} ${mon}, ${h}:${String(m).padStart(2, '0')}${mer}`;
}

function populateFilters() {
  const dates = new Set();
  const courses = new Map();
  for (const c of state.data.courses) {
    courses.set(c.slug, c.name);
    for (const s of c.slots) dates.add(s.date);
  }
  const sortedDates = [...dates].sort();
  for (const d of sortedDates) {
    const opt = document.createElement('option');
    opt.value = d;
    opt.textContent = formatDayHeading(d);
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
  if (state.filters.price) {
    const max = parseFloat(state.filters.price);
    const cheapest = cheapestTier(slot);
    if (!cheapest || cheapest.amount > max) return false;
  }
  return true;
}

function render() {
  els.results.innerHTML = '';
  const byDate = new Map();
  for (const course of state.data.courses) {
    if (course.error) {
      // Render an error row at the top of every day group via a synthetic structure later if needed.
      // For v1 skip silently — these are visible in JSON for debugging.
    }
    for (const slot of course.slots) {
      if (!filterSlot(course, slot)) continue;
      if (!byDate.has(slot.date)) byDate.set(slot.date, new Map());
      const byCourse = byDate.get(slot.date);
      if (!byCourse.has(course.slug)) byCourse.set(course.slug, { course, slots: [] });
      byCourse.get(course.slug).slots.push(slot);
    }
  }

  if (byDate.size === 0) {
    const p = document.createElement('p');
    p.className = 'empty';
    p.textContent = 'No tee times match those filters.';
    els.results.appendChild(p);
    return;
  }

  const sortedDates = [...byDate.keys()].sort();
  for (const date of sortedDates) {
    const dayDiv = document.createElement('section');
    dayDiv.className = 'day-group';
    const h2 = document.createElement('h2');
    h2.className = 'day-heading';
    h2.textContent = formatDayHeading(date);
    dayDiv.appendChild(h2);

    const courseEntries = [...byDate.get(date).values()].sort((a, b) =>
      (a.course.drive_minutes_from_bondi || 999) - (b.course.drive_minutes_from_bondi || 999)
    );

    for (const { course, slots } of courseEntries) {
      const block = document.createElement('div');
      block.className = 'course-block';

      const header = document.createElement('div');
      header.className = 'course-header';
      const name = document.createElement('span');
      name.className = 'course-name';
      name.textContent = course.name;
      header.appendChild(name);

      const metaBits = [];
      if (course.drive_minutes_from_bondi != null) metaBits.push(`${course.drive_minutes_from_bondi}min`);
      if (course.holes) metaBits.push(`${course.holes} holes`);
      if (course.region) metaBits.push(course.region);
      if (metaBits.length) {
        const meta = document.createElement('span');
        meta.className = 'course-meta';
        meta.textContent = metaBits.join(' • ');
        header.appendChild(meta);
      }
      block.appendChild(header);

      const list = document.createElement('div');
      list.className = 'slot-list';
      slots.sort((a, b) => a.time.localeCompare(b.time));
      for (const slot of slots) {
        const a = document.createElement('a');
        a.className = 'slot';
        a.href = slot.booking_url;
        a.target = '_blank';
        a.rel = 'noopener';

        const left = document.createElement('div');
        const t = document.createElement('div');
        t.className = 'slot-time';
        t.textContent = formatTime(slot.time);
        left.appendChild(t);
        const sub = document.createElement('div');
        sub.className = 'slot-info';
        sub.textContent = `${slot.spots_available} spot${slot.spots_available === 1 ? '' : 's'}`;
        left.appendChild(sub);
        a.appendChild(left);

        const right = document.createElement('div');
        const cheapest = cheapestTier(slot);
        if (cheapest) {
          const price = document.createElement('div');
          price.className = 'slot-price';
          if (isTwilightTier(cheapest)) price.classList.add('twilight');
          price.textContent = `$${Math.round(cheapest.amount)}`;
          right.appendChild(price);
        }
        a.appendChild(right);

        list.appendChild(a);
      }
      block.appendChild(list);
      dayDiv.appendChild(block);
    }
    els.results.appendChild(dayDiv);
  }
}

function bindFilters() {
  const updateAndRender = (key) => (e) => {
    state.filters[key] = e.target.value;
    render();
  };
  els.filterDay.addEventListener('change', updateAndRender('day'));
  els.filterTime.addEventListener('change', updateAndRender('time'));
  els.filterPrice.addEventListener('change', updateAndRender('price'));
  els.filterCourse.addEventListener('change', updateAndRender('course'));
  els.filterHoles.addEventListener('change', updateAndRender('holes'));
  els.reset.addEventListener('click', () => {
    state.filters = { day: '', time: '', price: '', course: '', holes: '' };
    els.filterDay.value = '';
    els.filterTime.value = '';
    els.filterPrice.value = '';
    els.filterCourse.value = '';
    els.filterHoles.value = '';
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
