// Spustni seznam obvestil v glavi (MainLayout: <details class="notification-menu">) se odpre brez
// JavaScripta, a <details> se sam zapre samo ob ponovnem kliku na zvonec. Uporabnik pricakuje, da
// ga klik kamorkoli drugam, tipka Escape ali premik fokusa iz seznama zaprejo — samo to doda ta
// skript. Poslusalci so na dokumentu in odprt seznam poiscejo sele ob dogodku, zato prezivijo
// izboljsano navigacijo Blazorja (ta zamenja vsebino strani, poslusalcev na dokumentu pa ne).
(function () {
  const MENU = 'details.notification-menu';

  function closeOpenMenus(except) {
    document.querySelectorAll(MENU + '[open]').forEach(function (menu) {
      if (menu !== except) menu.removeAttribute('open');
    });
  }

  function menuOf(node) {
    return node instanceof Element ? node.closest(MENU) : null;
  }

  // Klik (ali dotik) zunaj seznama ga zapre; klik na zvonec ali v seznam pusti <details> pri miru,
  // da zvonec se naprej sam preklaplja in da gumbi "prebrano" ter povezava normalno delujejo.
  document.addEventListener('pointerdown', function (event) {
    closeOpenMenus(menuOf(event.target));
  });

  // Escape zapre seznam in vrne fokus na zvonec, ce je bil fokus v seznamu.
  document.addEventListener('keydown', function (event) {
    if (event.key !== 'Escape') return;
    document.querySelectorAll(MENU + '[open]').forEach(function (menu) {
      const hadFocus = menu.contains(document.activeElement);
      menu.removeAttribute('open');
      const summary = menu.querySelector(':scope > summary');
      if (hadFocus && summary) summary.focus();
    });
  });

  // Tabulator iz seznama na drug element strani ga zapre. relatedTarget je null tudi ob kliku na
  // besedilo v seznamu ali ob izgubi fokusa okna — takrat seznama ne zapiramo.
  document.addEventListener('focusout', function (event) {
    const menu = menuOf(event.target);
    if (!menu || !menu.open) return;
    const next = event.relatedTarget;
    if (next instanceof Element && !menu.contains(next)) menu.removeAttribute('open');
  });
})();

// Izbirnik podjetja strani (Components/Shared/PimOrganizationScope.razor) se odda takoj ob
// izbiri; gumb »Preklopi« ostane za tipkovnico in brskalnik brez skript. Poslusalec je na
// dokumentu, ker Blazor izbirnik izrise sele po nalaganju in ga ob navigaciji zamenja.
(function () {
  document.addEventListener('change', function (event) {
    const select = event.target;
    if (!(select instanceof HTMLSelectElement) || !select.hasAttribute('data-pim-autosubmit')) return;
    if (select.form) select.form.requestSubmit();
  });
})();

// #84: pogovorna okna (role="dialog" aria-modal="true"), ki jih izrise Blazor brez <dialog>.
// Ob odprtju gre fokus v okno (na gumb z data-pim-close, sicer na prvi fokusabilni element),
// Tab in Shift+Tab ostaneta v oknu, Escape klikne gumb data-pim-close (samo ce ga okno ima —
// tako Esc nikoli ne sprozi dejanja, ki ni zapiranje), ob zaprtju pa se fokus vrne na gumb,
// ki je okno odprl. Opazovalec je na dokumentu, zato prezivi izboljsano navigacijo Blazorja.
(function () {
  const DIALOG = '[role="dialog"][aria-modal="true"]';
  const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
  const stack = []; // { dialog, returnTo }
  let lastFocus = null;

  function visible(el) { return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length); }
  function focusables(dialog) { return Array.prototype.filter.call(dialog.querySelectorAll(FOCUSABLE), visible); }
  function top() { return stack.length ? stack[stack.length - 1].dialog : null; }

  // Zadnji fokus zunaj okna: gumb, ki je okno odprl (Safari ob kliku gumbu ne da fokusa, zato
  // si zapomnimo tudi zadnji pritisnjeni gumb).
  document.addEventListener('focusin', function (event) {
    if (event.target instanceof Element && !event.target.closest(DIALOG)) lastFocus = event.target;
  });
  document.addEventListener('pointerdown', function (event) {
    const button = event.target instanceof Element ? event.target.closest('button, a[href]') : null;
    if (button && !button.closest(DIALOG)) lastFocus = button;
  }, true);

  function focusInto(dialog) {
    if (dialog.contains(document.activeElement)) return;
    const target = dialog.querySelector('[data-pim-close]') || focusables(dialog)[0];
    if (target) { target.focus(); return; }
    if (!dialog.hasAttribute('tabindex')) dialog.setAttribute('tabindex', '-1');
    dialog.focus();
  }

  function sync() {
    // Zaprta okna (odstranjena iz DOM): vrni fokus, ce je ostal brez mesta.
    for (let i = stack.length - 1; i >= 0; i--) {
      const entry = stack[i];
      if (entry.dialog.isConnected) continue;
      stack.splice(i, 1);
      const active = document.activeElement;
      const lost = !active || active === document.body || !active.isConnected;
      if (lost && entry.returnTo && entry.returnTo.isConnected) entry.returnTo.focus();
    }
    // Nova okna.
    document.querySelectorAll(DIALOG).forEach(function (dialog) {
      if (stack.some(function (entry) { return entry.dialog === dialog; })) return;
      stack.push({ dialog: dialog, returnTo: lastFocus && lastFocus.isConnected ? lastFocus : null });
      focusInto(dialog);
    });
  }

  function start() {
    new MutationObserver(function (mutations) {
      for (let i = 0; i < mutations.length; i++) {
        if (mutations[i].addedNodes.length || mutations[i].removedNodes.length) { sync(); return; }
      }
    }).observe(document.documentElement, { childList: true, subtree: true });
    sync();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();

  document.addEventListener('keydown', function (event) {
    const dialog = top();
    if (!dialog || !dialog.isConnected) return;
    if (event.key === 'Escape') {
      const close = dialog.querySelector('[data-pim-close]');
      if (close) { event.preventDefault(); close.click(); }
      return;
    }
    if (event.key !== 'Tab') return;
    const items = focusables(dialog);
    if (items.length === 0) { event.preventDefault(); return; }
    const first = items[0], last = items[items.length - 1];
    const inside = dialog.contains(document.activeElement);
    if (event.shiftKey && (document.activeElement === first || !inside)) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && (document.activeElement === last || !inside)) { event.preventDefault(); first.focus(); }
  });
})();
