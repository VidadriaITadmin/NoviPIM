// Klikalnik: odpre vsako stran intraneta v brskalniku Edge (brez dodatnih paketov, prek CDP),
// počaka na interaktivnost in preveri: napake ob nalaganju, filtre (ali spremenijo rezultat),
// varne gumbe (ali se kaj zgodi), razvrščanje, povezave (ali obstajajo) in absolutne href-e.
// Nikoli ne klikne gumbov, ki pišejo (shrani, izbriši, pošlji, zaženi, uvozi ...).
//
// Uporaba:  node klikalnik.mjs [osnova=http://localhost:5000/] [filter poti, npr. izdelki]
// Rezultat: porocilo/klikalnik.json in porocilo/klikalnik.md (+ posnetki zaslona).

import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const tu = dirname(fileURLToPath(import.meta.url));
const OSNOVA = (process.argv[2] ?? 'http://localhost:5000/').replace(/\/?$/, '/');
// Več strani: vejica (npr. "izdelki/odprodaja,cene"); prazno = vse.
const SAMO = (process.argv[3] ?? '').split(',').map(x => x.trim().replace(/^\//, '')).filter(Boolean);
const izbrana = pot => !SAMO.length || SAMO.some(x => pot.replace(/^\//, '').startsWith(x) || pot.includes(x));
// Vzporedno: KLIKALNIK_DEL="0/3" pregleda vsako tretjo stran; `node klikalnik.mjs --zdruzi` združi dele.
const [DEL, DELOV] = (process.env.KLIKALNIK_DEL ?? '0/1').split('/').map(Number);
const PRIPONA = DELOV > 1 ? '-' + DEL : '';
// KLIKALNIK_IZHOD: vrata naloge pišejo poročilo in posnetke v mapo preverjanja (vidi jih nadzorna plošča).
const IZHOD = process.env.KLIKALNIK_IZHOD || join(tu, 'porocilo');
mkdirSync(join(IZHOD, 'posnetki'), { recursive: true });

const EDGE = [
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
].find(p => { try { return statSync(p).isFile(); } catch { return false; } });

// ---------- poti iz @page ----------
function poti() {
  const koren = join(tu, '../../src/PIM.Intranet/Components');
  const out = [];
  const hodi = d => {
    for (const f of readdirSync(d)) {
      const p = join(d, f);
      if (statSync(p).isDirectory()) hodi(p);
      else if (f.endsWith('.razor')) {
        for (const m of readFileSync(p, 'utf8').matchAll(/^@page "([^"]+)"/gm)) out.push({ pot: m[1], datoteka: p.slice(koren.length + 1) });
      }
    }
  };
  hodi(koren);
  return out.filter(x => !['/prijava', '/Error', '/brez-dostopa'].includes(x.pot));
}

// ---------- minimalen CDP ----------
class Cdp {
  constructor(ws) { this.ws = ws; this.id = 0; this.cak = new Map(); this.posl = [];
    ws.onmessage = e => { const m = JSON.parse(e.data);
      if (m.id && this.cak.has(m.id)) { const { ok, ne } = this.cak.get(m.id); this.cak.delete(m.id); m.error ? ne(new Error(m.error.message)) : ok(m.result); }
      else if (m.method) this.posl.forEach(f => f(m)); }; }
  static async povezi(url) { const ws = new WebSocket(url); await new Promise((ok, ne) => { ws.onopen = ok; ws.onerror = ne; }); return new Cdp(ws); }
  poslji(method, params = {}) { const id = ++this.id; this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((ok, ne) => { this.cak.set(id, { ok, ne }); setTimeout(() => { if (this.cak.has(id)) { this.cak.delete(id); ne(new Error('CDP timeout ' + method)); } }, 180000); }); }
  na(f) { this.posl.push(f); }
}

const spi = ms => new Promise(r => setTimeout(r, ms));

async function js(cdp, izraz) {
  const r = await cdp.poslji('Runtime.evaluate', { expression: izraz, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r.result.value;
}

// V stran vbrizgan pomočnik (window.__k): prstni odtis, stabilnost, popis kontrolnikov.
const POMOCNIK = String.raw`
(() => {
  if (window.__k) return;
  const Ws = window.WebSocket;
  window.__blazor = { odprt: false, sporocil: 0 };
  window.WebSocket = function (u, p) { const w = p ? new Ws(u, p) : new Ws(u);
    if (String(u).includes('_blazor')) { w.addEventListener('open', () => window.__blazor.odprt = true);
      w.addEventListener('message', () => window.__blazor.sporocil++); }
    return w; };
  window.WebSocket.prototype = Ws.prototype; Object.assign(window.WebSocket, Ws);
  const fold = s => (s || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/\s+/g, ' ').trim();
  const vidno = el => { if (!el || !el.isConnected) return false; const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
  const glavno = () => document.querySelector('main') || document.body;
  const vDialogu = el => !!el.closest('dialog,[role=dialog],[aria-modal=true]');
  // Kontrolnik v urejevalnem delu (blizu gumba Shrani/Potrdi) ni filter; tega ne spreminjamo.
  const vUrejanju = el => { let a = el.parentElement;
    for (let i = 0; a && a !== document.body && i < 5; i++, a = a.parentElement)
      if ([...a.querySelectorAll('button,input[type=submit]')].some(b => /(shrani|potrdi|uveljavi|posodobi)/.test(fold(b.innerText || b.value)))) return true;
    return false; };
  const opis = el => { const t = fold(el.innerText || el.value || el.getAttribute('aria-label') || el.title || '');
    return t.slice(0, 80) || fold(el.getAttribute('aria-label') || el.name || el.id || el.className || el.tagName); };
  // Vse oznake gumba skupaj (besedilo, aria-label, title): gumb je nevaren tudi, če nevarna beseda
  // stoji samo v aria-label ali title (naloga #57).
  const oznake = el => fold([el.innerText, el.value, el.getAttribute('aria-label'), el.title].filter(Boolean).join(' '));
  window.__k = {
    fold, vidno,
    odtis() { const m = glavno(); const t = m.innerText;
      let h = 0; for (let i = 0; i < t.length; i++) h = (h * 31 + t.charCodeAt(i)) | 0;
      const vrstice = m.querySelectorAll('tbody tr').length;
      const st = (t.match(/(\d[\d.]*)\s+(izdelk|zadet|vrstic|artikl|strank|pravil|zapis|napak|kandidat|uvoz|tek|dogod|posl)/i) || [])[0] || null;
      return { h, dolzina: t.length, vrstice, stevec: st, url: location.href,
        dialog: !!document.querySelector('dialog[open],[role=dialog],[aria-modal=true]') }; },
    napake() { const out = [];
      const eu = document.getElementById('blazor-error-ui'); if (eu && vidno(eu)) out.push('Blazor napaka: ' + fold(eu.innerText).slice(0, 200));
      // Samo prava napaka; opozorilo ob praznem vnosu (»Vpiši šifro«) je pričakovano vedenje.
      document.querySelectorAll('[role=alert]').forEach(a => { const t = a.innerText.trim().replace(/\s+/g, ' ');
        if (vidno(a) && /(napak|ni mogoce|ni bilo mogoce|ni uspel|exception|error|izjem|timeout|casovn|ne obstaja)/.test(fold(t))) out.push('Napaka na strani: ' + t.slice(0, 240)); });
      const rc = document.getElementById('components-reconnect-modal'); if (rc && vidno(rc)) out.push('Povezava s strežnikom prekinjena');
      return out; },
    kontrolniki() {
      // Ključ je določljiv (vrsta + opis + zaporedje), zato ga po ponovnem izrisu Blazorja najdemo znova.
      const m = glavno(); const st = new Map();
      const oznaci = el => { const osnova = el.tagName + '|' + opis(el.labels?.[0] || el); const n = (st.get(osnova) || 0) + 1; st.set(osnova, n);
        el.dataset.kid = osnova + '|' + n; return el.dataset.kid; };
      const polja = [...m.querySelectorAll('input,select,textarea')].filter(el => vidno(el) && !el.disabled && !vDialogu(el))
        .map(el => ({ id: oznaci(el), tag: el.tagName.toLowerCase(), tip: (el.type || '').toLowerCase(), opis: opis(el.labels?.[0] || el),
          vForm: !!el.closest('form'), vUrejanju: vUrejanju(el), vGlavi: !!el.closest('thead'), vTabeli: !!el.closest('tbody'), readonly: el.readOnly,
          moznosti: el.tagName === 'SELECT' ? [...el.options].map(o => o.value) : null, vrednost: el.value }));
      const gumbi = [...m.querySelectorAll('button,[role=button],a.pim-btn,input[type=submit]')].filter(el => vidno(el) && !vDialogu(el))
        .map(el => ({ id: oznaci(el), opis: opis(el), oznake: oznake(el), onemogocen: el.disabled || el.getAttribute('aria-disabled') === 'true',
          vGlavi: !!el.closest('thead'), vTabeli: !!el.closest('tbody'), tip: el.getAttribute('type') || '', href: el.getAttribute('href'),
          aktiven: el.getAttribute('aria-selected') === 'true' || el.getAttribute('aria-pressed') === 'true' || el.getAttribute('aria-current') != null || /(^|\s)(active|is-active|selected|aktiven)(\s|$)/.test(el.className) }));
      const povezave = [...document.querySelectorAll('a[href]')].map(a => a.getAttribute('href'))
        .filter(h => h && !h.startsWith('#') && !h.startsWith('mailto:') && !h.startsWith('javascript:'));
      const vrstica = m.querySelector('tbody tr');
      const klikVrstica = vrstica && (getComputedStyle(vrstica).cursor === 'pointer' || vrstica.onclick) ? oznaci(vrstica) : null;
      const tabele = [...m.querySelectorAll('table')].map(t => ({ caption: !!t.querySelector('caption'), vrstic: t.querySelectorAll('tbody tr').length }));
      return { polja, gumbi, povezave: [...new Set(povezave)], klikVrstica, tabele,
        naslov: (document.querySelector('h1')?.innerText || document.title).trim() };
    },
    el(id) { this.kontrolniki(); return [...document.querySelectorAll('[data-kid]')].find(e => e.dataset.kid === id) || null; },
  };
})();`;

async function stabilno(cdp, maxMs = 45000, mirno = 1200) {
  const t0 = Date.now(); let zadnji = null, od = Date.now();
  while (Date.now() - t0 < maxMs) {
    const o = await js(cdp, `JSON.stringify([document.readyState, window.__k ? window.__k.odtis() : null, window.__blazor?.sporocil ?? 0, !!document.querySelector('.pim-state--loading,[aria-busy=true]') || /(Nalaganje|Nalagam|nalaga se|Berem)/.test((document.querySelector('main')||document.body).innerText)])`).catch(() => null);
    if (o !== zadnji) { zadnji = o; od = Date.now(); }
    else if (Date.now() - od >= mirno && o && !JSON.parse(o)[3]) return Date.now() - t0;
    await spi(250);
  }
  return -1;
}

async function interaktivna(cdp, maxMs = 30000) {
  const t0 = Date.now();
  while (Date.now() - t0 < maxMs) { if (await js(cdp, `!!window.__blazor?.odprt && window.__blazor.sporocil > 0`).catch(() => false)) return true; await spi(200); }
  return false;
}

async function pojdi(cdp, url) {
  const t0 = Date.now();
  await cdp.poslji('Page.navigate', { url });
  await spi(300);
  // Oznake Blazor so v HTML; počakamo, da je dokument prebran (največ 15 s).
  for (let i = 0; i < 75 && await js(cdp, `document.readyState === 'loading'`).catch(() => true); i++) await spi(200);
  // Statične strani (SSR, brez @rendermode) nimajo povezave Blazor — to ni napaka.
  // Interaktivna komponenta pusti v HTML oznako <!--Blazor:{"type":"server"…}-->; glava (zvonec, Odjava)
  // so navadni obrazci in stran ne naredijo interaktivne (#23: /nadzorna-plosca je čakala 30 s zaman).
  const staticna = await js(cdp, `(() => {
    if (window.__blazor?.odprt) return false;
    const w = document.createTreeWalker(document, NodeFilter.SHOW_COMMENT);
    for (let c = w.nextNode(); c; c = w.nextNode()) if (/^\\s*Blazor:\\s*\\{[^}]*"type"\\s*:\\s*"(server|auto|webassembly)"/.test(c.data)) return false;
    return true; })()`).catch(() => false);
  const inter = staticna ? true : await interaktivna(cdp, 30000);
  const s = await stabilno(cdp);
  return { ms: Date.now() - t0, interaktivna: inter, stabilna: s >= 0 };
}

// Besede, pri katerih gumba nikoli ne kliknemo (lahko piše, pošilja ali zaganja).
// »Poženi« na /sistem je 2026-09-29 oddal zahtevo za zagon izvoza kataloga, zato tudi pozen/zahtev/da,.
const NEVARNO = /(pozen|zahtev|^da\b|da, |shrani|izbris|brisi|odstran|poslj|posli|zazeni|zagon|uvoz|potrdi|odobri|zavrni|razveljav|povrni|objavi|sprejmi|ustvari|dodaj|nastavi|spremeni|prevzemi|zaklen|odklen|ponovi|obdelaj|validir|preracun|generir|prevedi|\bai\b|kopiraj|podvoji|odjav|izvoz|prenesi|excel|csv|pripravi|oznaci kot|zakljuci|umakni|vrni|aktiviraj|deaktiviraj|izklopi|vklopi|preklici tek|ustavi|odpri v saop|sinhron|osvezi iz|preberi iz|nalozi|prenesi v|premakni|zdruzi|razdruzi|uveljavi|zapri|resi|dodeli)/;
const VARNO_IZJEME = /(pocisti|filtr|isci|poisci|prikazi|naprej|nazaj|prejsnj|naslednj|vec|manj|razsiri|skrci|zavih|stran \d)/;

function varenGumb(g) {
  if (g.onemogocen || g.vTabeli) return false;
  // Nevarna beseda v kateri koli oznaki (tudi samo v aria-label/title) gumb izloči (#57).
  if (g.oznake && NEVARNO.test(g.oznake) && !VARNO_IZJEME.test(g.opis)) return false;
  if (g.tip === 'submit') return VARNO_IZJEME.test(g.opis);
  if (VARNO_IZJEME.test(g.opis)) return !/(shrani|izbris|poslj)/.test(g.opis);
  return !NEVARNO.test(g.opis);
}

async function klikni(cdp, id) {
  return js(cdp, `(() => { const e = window.__k.el(${JSON.stringify(id)}); if (!e) return false; e.scrollIntoView({block:'center'}); e.click(); return true; })()`);
}

async function nastaviSelect(cdp, id, vrednost) {
  return js(cdp, `(() => { const e = window.__k.el(${JSON.stringify(id)}); if (!e) return false; e.value = ${JSON.stringify(vrednost)};
    e.dispatchEvent(new Event('input', {bubbles:true})); e.dispatchEvent(new Event('change', {bubbles:true})); return true; })()`);
}

async function vpisi(cdp, id, besedilo) {
  if (!await js(cdp, `(() => { const e = window.__k.el(${JSON.stringify(id)}); if (!e) return false; e.scrollIntoView({block:'center'}); e.focus(); e.select?.(); return true; })()`)) return false;
  await cdp.poslji('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 });
  await cdp.poslji('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 });
  if (besedilo) await cdp.poslji('Input.insertText', { text: besedilo });
  await js(cdp, `(() => { const e = window.__k.el(${JSON.stringify(id)}); e && e.dispatchEvent(new Event('input', {bubbles:true})); })()`);
  await cdp.poslji('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' });
  await cdp.poslji('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  await js(cdp, `(() => { const e = window.__k.el(${JSON.stringify(id)}); e && e.dispatchEvent(new Event('change', {bubbles:true})); e && e.blur(); })()`);
  return true;
}

const odtis = cdp => js(cdp, 'window.__k.odtis()');
const enako = (a, b) => a.h === b.h && a.url === b.url && a.dialog === b.dialog;

async function posnetek(cdp, ime) {
  const r = await cdp.poslji('Page.captureScreenshot', { format: 'png' }).catch(() => null);
  if (r) writeFileSync(join(IZHOD, 'posnetki', ime + '.png'), Buffer.from(r.data, 'base64'));
}

// ---------- pregled ene strani ----------
async function preglej(cdp, pot, dnevnik) {
  const url = OSNOVA + pot.replace(/^\//, '');
  const rez = { pot, url, najdbe: [], cas: {}, stevila: {} };
  const najdi = (resnost, vrsta, opis) => rez.najdbe.push({ resnost, vrsta, opis });
  dnevnik.length = 0;

  const n = await pojdi(cdp, url);
  rez.cas.nalaganjeMs = n.ms;
  if (!n.interaktivna) najdi('VISOKA', 'stanje', 'Stran ni postala interaktivna (gumbi in filtri ne morejo delovati).');
  if (!n.stabilna) najdi('SREDNJA', 'stanje', 'Stran se ni umirila v 45 s (neskončno nalaganje ali stalno osveževanje).');
  if (n.ms > 15000) najdi(n.ms > 45000 ? 'VISOKA' : 'SREDNJA', 'hitrost', `Nalaganje traja ${(n.ms / 1000).toFixed(0)} s.`);
  for (const e of await js(cdp, 'window.__k.napake()')) najdi('VISOKA', 'stanje', e);
  const koncniUrl = await js(cdp, 'location.href');
  if (/prijava|brez-dostopa/.test(koncniUrl)) { najdi('VISOKA', 'stanje', 'Preusmeritev na ' + koncniUrl); return rez; }
  await posnetek(cdp, pot.replace(/[^a-z0-9]+/gi, '_').replace(/^_|_$/g, '') || 'domov');

  let k = await js(cdp, 'window.__k.kontrolniki()');
  rez.naslov = k.naslov;
  rez.stevila = { polj: k.polja.length, gumbov: k.gumbi.length, povezav: k.povezave.length, tabel: k.tabele.length };
  k.tabele.forEach((t, i) => { if (!t.caption) najdi('NIZKA', 'dostopnost', `Tabela ${i + 1} nima <caption>.`); });
  for (const h of k.povezave) if (h.startsWith('/') && !h.startsWith('//')) najdi('NIZKA', 'povezava', `Absolutna povezava "${h}" (mora biti brez začetne /).`);

  const osnovno = await odtis(cdp);
  const obnovi = async () => { const s = await odtis(cdp); if (s.url !== url || s.dialog || !enako(s, osnovno)) { await pojdi(cdp, url); } };

  // Filtri: spustni seznami
  for (const p of k.polja.filter(p => p.tag === 'select' && !p.vTabeli && !p.vUrejanju && p.moznosti?.length > 1).slice(0, 4)) {
    const druga = p.moznosti.find(v => v !== p.vrednost);
    const pred = await odtis(cdp);
    if (!await nastaviSelect(cdp, p.id, druga)) continue;
    await spi(300); await stabilno(cdp, 20000, 900);
    const po = await odtis(cdp);
    const napake = await js(cdp, 'window.__k.napake()');
    if (napake.length) najdi('VISOKA', 'filter', `Izbira "${druga}" v "${p.opis}" sproži napako: ${napake[0]}`);
    else if (enako(pred, po)) najdi('SREDNJA', 'filter', `Spustni seznam "${p.opis}": izbira "${druga}" ne spremeni ničesar na strani.`);
    else if (!p.vForm && po.url === pred.url && /\?|=/.test(pred.url + po.url) === false && !pot.includes('{'))
      najdi('NIZKA', 'filter', `Filter "${p.opis}" ni zapisan v naslovu strani (povezave ni mogoče deliti, »nazaj« ga izgubi).`);
    await obnovi();
  }

  // Filtri: iskalna polja
  const iskalna = k.polja.filter(p => p.tag === 'input' && ['search', 'text', ''].includes(p.tip) && !p.vTabeli && !p.readonly && !p.vUrejanju).slice(0, 2);
  for (const p of iskalna) {
    const pred = await odtis(cdp);
    if (!await vpisi(cdp, p.id, 'zzqxw')) continue;
    await spi(700); await stabilno(cdp, 20000, 1000);
    const po = await odtis(cdp);
    const napake = await js(cdp, 'window.__k.napake()');
    if (napake.length) najdi('VISOKA', 'filter', `Iskanje v "${p.opis}" sproži napako: ${napake[0]}`);
    else if (enako(pred, po)) najdi(pred.vrstice > 0 ? 'SREDNJA' : 'NIZKA', 'filter',
      `Polje "${p.opis}": vpis nesmiselnega niza (in Enter) ne spremeni prikaza${pred.vrstice ? ` — ${pred.vrstice} vrstic ostane` : ''}.`);
    else if (po.vrstice >= pred.vrstice && pred.vrstice > 0 && po.url === pred.url) najdi('NIZKA', 'filter', `Polje "${p.opis}": po iskanju nesmisla je vrstic enako ali več (${pred.vrstice} → ${po.vrstice}).`);
    await obnovi();
  }

  // Razvrščanje po stolpcih
  const glave = k.gumbi.filter(g => g.vGlavi && !g.onemogocen).slice(0, 1);
  for (const g of glave) {
    const pred = await odtis(cdp);
    await klikni(cdp, g.id); await spi(300); await stabilno(cdp, 12000, 800);
    const po = await odtis(cdp);
    if (enako(pred, po) && pred.vrstice > 1) najdi('NIZKA', 'gumb', `Klik na glavo stolpca "${g.opis}" ne spremeni vrstnega reda.`);
    await obnovi();
  }

  // Varni gumbi
  k = await js(cdp, 'window.__k.kontrolniki()');
  const varni = k.gumbi.filter(g => !g.vGlavi && varenGumb(g) && !g.href);
  const preskoceni = k.gumbi.filter(g => !g.vGlavi && !varenGumb(g) && !g.onemogocen && !g.vTabeli).map(g => g.opis);
  rez.preskoceniGumbi = [...new Set(preskoceni)];
  const videni = new Set();
  for (const g of varni.slice(0, 8)) {
    if (videni.has(g.opis)) continue; videni.add(g.opis);
    const pred = await odtis(cdp);
    if (!await klikni(cdp, g.id)) continue;
    await spi(400); await stabilno(cdp, 15000, 800);
    const po = await odtis(cdp);
    const napake = await js(cdp, 'window.__k.napake()');
    if (napake.length) najdi('VISOKA', 'gumb', `Gumb "${g.opis}" sproži napako: ${napake[0]}`);
    else if (enako(pred, po) && !g.aktiven && !/(uporabi|pocisti|prikazi)/.test(g.opis))
      najdi(/osvez/.test(g.opis) ? 'NIZKA' : 'SREDNJA', 'gumb', /osvez/.test(g.opis)
        ? `Gumb "${g.opis}" ne pove, ali je osvežil (ni sporočila ali časa zadnje osvežitve).`
        : `Gumb "${g.opis}" nima vidnega odziva.`);
    await obnovi();
  }

  // Klik na vrstico
  if (k.klikVrstica) {
    const pred = await odtis(cdp);
    await klikni(cdp, k.klikVrstica); await spi(500); await stabilno(cdp, 20000, 900);
    const po = await odtis(cdp);
    if (enako(pred, po)) najdi('SREDNJA', 'gumb', 'Vrstica je videti klikljiva (kazalec roka), klik pa nič ne odpre.');
    await obnovi();
  } else if (k.tabele.some(t => t.vrstic > 0) && !k.povezave.length) {
    najdi('NIZKA', 'manjka', 'Tabela brez povezav ali klika na vrstico — podrobnosti ni mogoče odpreti.');
  }

  for (const d of dnevnik) najdi(d.resnost, 'konzola', d.opis);
  rez.povezave = k.povezave;
  return rez;
}

// ---------- glavni tok ----------
async function main() {
  if (!EDGE) throw new Error('Ni brskalnika (Edge ali Chrome).');
  const port = 9300 + Math.floor(Math.random() * 500);
  const profil = join(tmpdir(), 'klikalnik-edge-' + port);
  const edge = spawn(EDGE, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profil}`, '--no-first-run',
    '--disable-extensions', '--window-size=1440,1000', 'about:blank'], { stdio: 'ignore' });
  let cilji;
  for (let i = 0; i < 60; i++) { try { cilji = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); if (cilji.length) break; } catch {} await spi(250); }
  const stran = cilji.find(c => c.type === 'page');
  const cdp = await Cdp.povezi(stran.webSocketDebuggerUrl);
  const dnevnik = [];
  cdp.na(m => {
    if (m.method === 'Runtime.exceptionThrown') dnevnik.push({ resnost: 'VISOKA', opis: 'JS izjema: ' + (m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text).split('\n')[0].slice(0, 200) });
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') dnevnik.push({ resnost: 'SREDNJA', opis: 'Napaka v konzoli: ' + m.params.args.map(a => a.value ?? a.description ?? '').join(' ').split('\n')[0].slice(0, 240) });
    if (m.method === 'Network.responseReceived' && m.params.response.status >= 400 && m.params.response.url.startsWith(OSNOVA))
      dnevnik.push({ resnost: 'SREDNJA', opis: `HTTP ${m.params.response.status}: ${m.params.response.url.slice(OSNOVA.length - 1)}` });
  });
  await cdp.poslji('Page.enable'); await cdp.poslji('Runtime.enable'); await cdp.poslji('Network.enable');
  await cdp.poslji('Page.addScriptToEvaluateOnNewDocument', { source: POMOCNIK });
  await cdp.poslji('Browser.setDownloadBehavior', { behavior: 'deny' }).catch(() => {});

  const vse = poti();
  const moj = (_, i) => i % DELOV === DEL;
  const staticne = vse.filter(p => !p.pot.includes('{') && izbrana(p.pot)).filter(moj);
  const parametricne = vse.filter(p => p.pot.includes('{') && (!SAMO.length || SAMO.some(x => p.pot.includes(x.split('/')[0])))).filter(moj);
  const rezultati = [];
  const vsePovezave = new Set();

  const zabelezi = r => { rezultati.push(r); r.povezave?.forEach(h => vsePovezave.add(h));
    writeFileSync(join(IZHOD, 'klikalnik' + PRIPONA + '.json'), JSON.stringify(rezultati, null, 1));
    console.log(`${r.pot.padEnd(42)} ${String(Math.round((r.cas.nalaganjeMs ?? 0) / 1000)).padStart(4)} s  najdb: ${r.najdbe.length}`); };

  for (const p of staticne) {
    try { const r = await preglej(cdp, p.pot, dnevnik); r.datoteka = p.datoteka; zabelezi(r); }
    catch (e) { zabelezi({ pot: p.pot, datoteka: p.datoteka, cas: {}, najdbe: [{ resnost: 'VISOKA', vrsta: 'klikalnik', opis: 'Pregled se je ustavil: ' + e.message }] }); }
  }

  // Parametrične poti: prvi primer iz povezav, ki smo jih videli na drugih straneh.
  for (const p of parametricne) {
    const vzorec = new RegExp('^/?' + p.pot.replace(/^\//, '').replace(/\{[^}]+\}/g, '[^/?#]+') + '(?:[?#].*)?$');
    const primer = [...vsePovezave].find(h => vzorec.test(h));
    if (!primer) { zabelezi({ pot: p.pot, datoteka: p.datoteka, cas: {}, najdbe: [{ resnost: 'NIZKA', vrsta: 'pokritost', opis: 'Nobena druga stran ne vodi sem (ni primera za preizkus).' }] }); continue; }
    try { const r = await preglej(cdp, primer.replace(/^\//, ''), dnevnik); r.vzorec = p.pot; r.datoteka = p.datoteka; zabelezi(r); }
    catch (e) { zabelezi({ pot: p.pot, datoteka: p.datoteka, cas: {}, najdbe: [{ resnost: 'VISOKA', vrsta: 'klikalnik', opis: 'Pregled se je ustavil: ' + e.message }] }); }
  }

  // Mrtve povezave: vsako notranjo povezavo preveri, ali vodi na obstoječo pot.
  const vzorci = vse.map(p => new RegExp('^' + p.pot.replace(/\{[^}]+\}/g, '[^/]+') + '$', 'i'));
  for (const h of vsePovezave) {
    if (/^(https?:)?\/\//.test(h) || /\.(csv|xlsx|pdf|png|jpg|zip)(\?|$)/i.test(h) || h.startsWith('api/') || h.startsWith('/api/') || h.includes('_framework')) continue;
    const pot = '/' + h.replace(/^\//, '').split(/[?#]/)[0].replace(/\/$/, '');
    if (pot === '/' || vzorci.some(v => v.test(pot)) || /^\/(prijava|odjava|izvoz|prenos|datoteke|slike)/.test(pot)) continue;
    const kje = rezultati.filter(r => r.povezave?.includes(h)).map(r => r.pot).slice(0, 3).join(', ');
    rezultati.push({ pot: '(povezave)', cas: {}, najdbe: [{ resnost: 'SREDNJA', vrsta: 'povezava', opis: `Povezava "${h}" (na ${kje}) vodi na neobstoječo stran.` }] });
  }

  writeFileSync(join(IZHOD, 'klikalnik' + PRIPONA + '.json'), JSON.stringify(rezultati, null, 1));
  const red = { VISOKA: 0, SREDNJA: 1, NIZKA: 2 };
  const vrstice = rezultati.flatMap(r => r.najdbe.map(n => ({ ...n, pot: r.pot, naslov: r.naslov })))
    .sort((a, b) => red[a.resnost] - red[b.resnost] || a.pot.localeCompare(b.pot));
  let md = `# Klikalnik — ${new Date().toISOString().slice(0, 16)}\n\nPregledanih strani: ${rezultati.filter(r => r.pot !== '(povezave)').length}, najdb: ${vrstice.length}\n\n`;
  md += '| Resnost | Stran | Vrsta | Najdba |\n|---|---|---|---|\n' + vrstice.map(v => `| ${v.resnost} | ${v.pot} | ${v.vrsta} | ${v.opis.replace(/\|/g, '/')} |`).join('\n');
  md += '\n\n## Časi nalaganja\n\n' + rezultati.filter(r => r.cas.nalaganjeMs).sort((a, b) => b.cas.nalaganjeMs - a.cas.nalaganjeMs)
    .map(r => `- ${r.pot}: ${(r.cas.nalaganjeMs / 1000).toFixed(1)} s`).join('\n') + '\n';
  writeFileSync(join(IZHOD, 'klikalnik' + PRIPONA + '.md'), md);
  console.log(`\nKončano. Najdb: ${vrstice.length}. Poročilo: ${join(IZHOD, 'klikalnik' + PRIPONA + '.md')}`);
  edge.kill();
  process.exit(0);
}

function porocilo(rezultati, ime) {
  const red = { VISOKA: 0, SREDNJA: 1, NIZKA: 2 };
  const vrstice = rezultati.flatMap(r => r.najdbe.map(n => ({ ...n, pot: r.pot })))
    .sort((a, b) => red[a.resnost] - red[b.resnost] || a.pot.localeCompare(b.pot));
  let md = `# Klikalnik — ${new Date().toISOString().slice(0, 16)}\n\nPregledanih strani: ${rezultati.filter(r => r.pot !== '(povezave)').length}, najdb: ${vrstice.length}\n\n`;
  md += '| Resnost | Stran | Vrsta | Najdba |\n|---|---|---|---|\n' + vrstice.map(v => `| ${v.resnost} | ${v.pot} | ${v.vrsta} | ${v.opis.replace(/\|/g, '/').replace(/\n/g, ' ')} |`).join('\n');
  md += '\n\n## Časi nalaganja\n\n' + rezultati.filter(r => r.cas?.nalaganjeMs).sort((a, b) => b.cas.nalaganjeMs - a.cas.nalaganjeMs)
    .map(r => `- ${r.pot}: ${(r.cas.nalaganjeMs / 1000).toFixed(1)} s`).join('\n') + '\n';
  writeFileSync(join(IZHOD, ime), md);
  return vrstice.length;
}

if (process.argv[2] === '--zdruzi') {
  const vsi = readdirSync(IZHOD).filter(f => /^klikalnik-\d+\.json$/.test(f)).flatMap(f => JSON.parse(readFileSync(join(IZHOD, f), 'utf8')));
  writeFileSync(join(IZHOD, 'klikalnik.json'), JSON.stringify(vsi, null, 1));
  console.log('Združeno, najdb: ' + porocilo(vsi, 'klikalnik.md'));
  process.exit(0);
}

main().catch(e => { console.error(e); process.exit(1); });
