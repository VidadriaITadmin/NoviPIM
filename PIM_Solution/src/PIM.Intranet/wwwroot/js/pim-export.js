// Odpre prenos na isti nacin kot klik na povezavo. Klicati ga je treba takoj po uporabnikovem
// kliku (stran /izdelki ga klice iz obdelave gumba »Izvozi«): samo tak prenos brskalnik steje za
// uporabnikovega, ga pokaze v svojem polju prenosov in ga ne zadrzi kot sumljivega (»Obdrži«).
// Atribut download (in data-enhance-nav) ga umakne izboljsani navigaciji Blazorja, ki bi klik
// na povezavo pod osnovnim naslovom sicer prestregla kot premik po straneh.
window.pimDownloadFile = function (url) {
  const link = document.createElement('a');
  link.href = url;
  link.rel = 'noopener';
  link.setAttribute('download', '');
  link.setAttribute('data-enhance-nav', 'false');
  document.body.appendChild(link);
  link.click();
  link.remove();
};

// Okno izvozov v kotu vsake strani (MainLayout: #pim-export-tray). Izvoz pripada uporabniku, ne
// strani, ki ga je sprozila — uporabnik 2026-09-22 je kliknil »Izvozi«, takoj za tem »Uvozi«, in
// obvestilo je izginilo skupaj s stranjo, gradnja pa je tekla naprej brez sledi. Okno zato bere
// GET /izvoz/opravila na vsaki strani, med tekom na sekundo in pol, ko ni nicesar aktivnega pa
// sploh ne. Samo prenosa ne sprozi: prenos odpre klik na »Izvozi« (brskalnik ga kaze sam), okno
// ponudi gumb »Prenesi« le, kadar brskalnik prenosa nima odprtega (preklican ali prekinjen).
window.pimExports = (function () {
  const TRAY_ID = 'pim-export-tray';
  const ACTIVE_POLL_MS = 1500;
  const RETRY_MS = 5000;
  const numbers = new Intl.NumberFormat('sl-SI');

  let timer = null;
  let inFlight = false;
  let again = false;
  // Kaj je ta dokument ze pokazal. Izboljsana navigacija Blazorja dokumenta ne zamenja, zato to
  // prezivi klike med stranmi; ob polni osvezitvi pomaga streznik (downloaded).
  const shown = new Set();

  function tray() { return document.getElementById(TRAY_ID); }

  function schedule(delay) {
    if (timer) return;
    timer = setTimeout(function () { timer = null; refresh(); }, delay);
  }

  async function refresh() {
    const host = tray();
    if (!host) return;
    if (inFlight) { again = true; return; }
    inFlight = true;
    let jobs = null;
    let failed = false;
    try {
      const response = await fetch('izvoz/opravila', {
        cache: 'no-store', credentials: 'same-origin', headers: { Accept: 'application/json' },
      });
      // Potekla prijava vrne preusmeritev na /prijava (HTML), ne JSON — takrat okno utihne.
      if (response.ok && (response.headers.get('content-type') || '').indexOf('json') >= 0) jobs = await response.json();
    } catch (error) {
      failed = true;
    } finally {
      inFlight = false;
    }

    if (jobs) render(host, jobs);
    if (again) { again = false; schedule(0); return; }
    const active = jobs ? jobs.some(needsPolling) : failed && host.querySelector('.export-card-active');
    if (active) schedule(failed ? RETRY_MS : ACTIVE_POLL_MS);
  }

  function isActive(job) { return job.status === 'Queued' || job.status === 'Running'; }

  // Gotov zvezek, ki ga brskalnik se prevzema, bere okno se nekaj trenutkov: sicer bi obstalo
  // pri »shranjujem«, ceprav je datoteka ze v prenosih.
  function needsPolling(job) {
    return isActive(job) || (job.status === 'Completed' && job.browserWaiting && !job.downloaded);
  }

  // Prenesen izvoz se ob polni osvezitvi ne vraca v okno — sicer bi dve uri visel na vsaki strani.
  // Na strani, ki ga je ze pokazala, ostane, dokler ga uporabnik ne zapre.
  function visible(job) {
    return !(job.status === 'Completed' && job.downloaded && !shown.has(job.id));
  }

  // Nespremenjena kartica ostane isti element: fokus na »Prenesi« ali »Zapri« ne skace ob
  // vsakem branju. Tekoca se spremeni vsakic (napredek, cas) in se izrise znova.
  function render(host, jobs) {
    const list = jobs.filter(visible);
    const existing = new Map();
    host.querySelectorAll(':scope > .export-card').forEach(function (node) { existing.set(node.dataset.key, node); });
    host.replaceChildren.apply(host, list.map(function (job) {
      const signature = JSON.stringify(job);
      const previous = existing.get(job.id);
      if (previous && previous.dataset.signature === signature) return previous;
      const node = card(job);
      node.dataset.key = job.id;
      node.dataset.signature = signature;
      return node;
    }));
    list.forEach(function (job) { shown.add(job.id); });
  }

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  function n(value) { return numbers.format(value || 0); }

  function duration(seconds) {
    if (seconds < 60) return 'manj kot minuto';
    const minutes = Math.round(seconds / 60);
    if (minutes < 60) return minutes + ' min';
    return Math.floor(minutes / 60) + ' h ' + (minutes % 60) + ' min';
  }

  function progressBar(fraction, label) {
    const bar = el('div', 'export-progress');
    bar.setAttribute('role', 'progressbar');
    bar.setAttribute('aria-label', label);
    const fill = el('div', 'export-progress-fill');
    if (fraction === null) {
      bar.classList.add('export-progress-indeterminate');
    } else {
      const percent = Math.max(0, Math.min(100, Math.round(fraction * 100)));
      bar.setAttribute('aria-valuemin', '0');
      bar.setAttribute('aria-valuemax', '100');
      bar.setAttribute('aria-valuenow', String(percent));
      fill.style.width = percent + '%';
    }
    bar.appendChild(fill);
    return bar;
  }

  function card(job) {
    const status = job.status.toLowerCase();
    const node = el('section', 'export-card export-card-' + status + (isActive(job) ? ' export-card-active' : ''));
    node.setAttribute('aria-label', 'Izvoz izdelkov');

    const head = el('div', 'export-card-head');
    head.appendChild(el('span', 'export-card-icon', null));
    const title = el('strong', 'export-card-title');
    head.appendChild(title);
    node.appendChild(head);

    if (job.status === 'Queued') {
      title.textContent = 'Izvoz čaka v vrsti';
      node.appendChild(el('p', 'export-card-detail',
        'Pred tabo: ' + n(job.queuePosition) + '. Hkrati tečeta največ dva izvoza; tvoj se začne sam.'));
      node.appendChild(progressBar(null, 'Izvoz čaka v vrsti'));
    } else if (job.status === 'Running') {
      const known = job.total !== null && job.total !== undefined && job.total > 0;
      const writing = job.phase === 'Writing';
      title.textContent = writing ? 'Izvoz: zapisujem vrstice' : 'Izvoz: berem seznam izdelkov';
      const step = writing ? 'Korak 2 od 2' : 'Korak 1 od 2';
      node.appendChild(el('p', 'export-card-detail',
        step + (known ? ' · ' + n(job.done) + ' od ' + n(job.total) + ' vrstic' : ' · pripravljam …')));
      const fraction = known ? job.done / job.total : null;
      node.appendChild(progressBar(fraction, title.textContent));
      const meta = el('p', 'export-card-meta');
      const parts = [];
      if (fraction !== null) parts.push(Math.round(fraction * 100) + ' %');
      if (writing && job.remainingSeconds !== null && job.remainingSeconds !== undefined) parts.push('še približno ' + duration(job.remainingSeconds));
      parts.push('teče ' + duration(job.elapsedSeconds));
      meta.textContent = parts.join(' · ');
      node.appendChild(meta);
      node.appendChild(el('p', 'export-card-hint', job.browserWaiting
        ? 'Prenos je že odprt v brskalniku; datoteka se shrani sama, ko bo gotova. Vmes lahko delaš naprej.'
        : 'Vmes lahko delaš naprej na drugih straneh; ko bo gotov, ga preneseš tu.'));
    } else if (job.status === 'Completed') {
      const delivered = job.downloaded || job.browserWaiting;
      title.textContent = delivered ? 'Izvoz je končan' : 'Izvoz je pripravljen';
      node.appendChild(el('p', 'export-card-detail', n(job.done) + ' vrstic · ' + (job.fileName || '')));
      if (delivered) {
        node.appendChild(el('p', 'export-card-meta', job.downloaded
          ? 'Datoteka je v prenosih brskalnika.'
          : 'Datoteka se shranjuje v prenose brskalnika …'));
      }
      const actions = el('div', 'export-card-actions');
      const link = el('a', delivered ? 'export-card-download export-card-download-again' : 'export-card-download',
        delivered ? 'Prenesi znova' : 'Prenesi');
      link.href = job.downloadUrl;
      link.setAttribute('download', job.fileName || '');
      link.setAttribute('data-enhance-nav', 'false');
      actions.appendChild(link);
      node.appendChild(actions);
    } else {
      title.textContent = 'Izvoz ni uspel';
      node.appendChild(el('p', 'export-card-detail', job.error || 'Neznana napaka.'));
    }

    if (!isActive(job)) {
      const close = el('button', 'export-card-close');
      close.type = 'button';
      close.setAttribute('aria-label', 'Zapri obvestilo o izvozu');
      close.title = 'Zapri';
      close.addEventListener('click', function () { dismiss(job.id, node); });
      head.appendChild(close);
    }
    return node;
  }

  async function dismiss(id, node) {
    node.remove();
    try {
      await fetch('izvoz/opravila/' + encodeURIComponent(id) + '/skrij', { method: 'POST', credentials: 'same-origin' });
    } catch (error) { /* naslednje branje ga pokaze znova, ce zapiranje ni uspelo */ }
  }

  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') refresh();
  });
  if (window.Blazor && typeof window.Blazor.addEventListener === 'function') {
    window.Blazor.addEventListener('enhancedload', refresh);
  }
  refresh();

  return { refresh: refresh };
})();
