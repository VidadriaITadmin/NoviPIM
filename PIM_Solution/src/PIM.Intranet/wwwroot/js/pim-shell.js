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
