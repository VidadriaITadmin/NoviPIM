// Nadzorna plošča razvojne ekipe PIM: živ pogled na tablo nalog, agente, vrata in združevanje.
//
// Zagon: scripts\Tabla.cmd (dvoklik) ali  node scripts/tabla/streznik.mjs  → http://localhost:5099/
// Brez dodatnih paketov. Posluša samo na 127.0.0.1. Bere stanje iz <git-common-dir>/pim-koordinacija
// (isto kot scripts/Koordinacija.ps1) in iz prepisov sej Claude (~/.claude/projects/...).
// Pisanje gre VEDNO prek Koordinacija.ps1 (ista pravila, zaklepi in dnevnik kot pri agentih).

import http from 'node:http';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { promises as fsp, readFileSync, existsSync, watch, statSync } from 'node:fs';
import { join, dirname, resolve, extname, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const tu = dirname(fileURLToPath(import.meta.url));
const KOREN = resolve(tu, '..', '..');
const PORT = Number(process.env.TABLA_PORT || 5099);
const SKUPNA = execFileSync('git', ['-C', KOREN, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim();
const GLAVNA = resolve(SKUPNA, '..');
const MAPA = process.env.TABLA_MAPA ? resolve(process.env.TABLA_MAPA) : join(SKUPNA, 'pim-koordinacija');
const KOORD = join(GLAVNA, 'scripts', 'Koordinacija.ps1');
const PREPISI = join(homedir(), '.claude', 'projects', GLAVNA.replace(/[^A-Za-z0-9]/g, '-'));

const zdaj = () => Date.now();
const beri = async (p) => { try { return (await fsp.readFile(p, 'utf8')).replace(/^﻿/, ''); } catch { return null; } };
const beriJson = async (p) => { const t = await beri(p); if (!t) return null; try { return JSON.parse(t); } catch { return null; } };
const cas = (s) => { if (!s) return null; const t = Date.parse(s.length === 16 ? s.replace(' ', 'T') : s); return Number.isNaN(t) ? null : t; };
const git = (args, cwd = GLAVNA) => new Promise((res) => execFile('git', ['-C', cwd, ...args], { encoding: 'utf8', maxBuffer: 8 << 20 }, (e, out) => res(e ? '' : out)));

// ------------------------------------------------------------------ naloge
const SEZNAMI = new Set(['obmocje', 'strani', 'testi', 'odvisno']);
function razcleniNalogo(besedilo, datoteka) {
  const vrstice = besedilo.split(/\r?\n/);
  const n = { datoteka };
  let i = 1;
  for (; i < vrstice.length; i++) {
    const v = vrstice[i];
    if (v.trim() === '---') break;
    const m = /^([a-z]+):\s?(.*)$/.exec(v);
    if (!m) continue;
    n[m[1]] = SEZNAMI.has(m[1]) ? m[2].trim().replace(/^\[|\]$/g, '').split(',').map(x => x.trim()).filter(Boolean) : m[2].trim();
  }
  const telo = vrstice.slice(i + 1).join('\n');
  const razdelek = (ime) => { const m = new RegExp(`## ${ime}\\n([\\s\\S]*?)(?=\\n## |$)`).exec(telo); return m ? m[1].trim() : ''; };
  n.opis = razdelek('Opis');
  n.kriteriji = razdelek('Kriteriji sprejema');
  n.dnevnik = [];
  for (const v of razdelek('Dnevnik').split('\n')) {
    const m = /^- (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) · (.*?) · (.*)$/.exec(v.trim());
    if (m) n.dnevnik.push({ cas: m[1], seja: m[2], besedilo: m[3] });
  }
  n.id = Number(n.id);
  return n;
}

async function naloge() {
  const mapa = join(MAPA, 'naloge');
  let imena = [];
  try { imena = (await fsp.readdir(mapa)).filter(x => x.endsWith('.md')).sort(); } catch { }
  const izid = [];
  for (const ime of imena) { const t = await beri(join(mapa, ime)); if (t) izid.push(razcleniNalogo(t, ime)); }
  return izid;
}

// Zadnja vrata vsake naloge: <id>-<čas>.json (+ poročilo klikalnika in posnetki).
async function preverjanja() {
  const mapa = join(MAPA, 'preverjanja');
  let imena = [];
  try { imena = await fsp.readdir(mapa); } catch { return {}; }
  const poNalogi = {};
  for (const ime of imena.filter(x => /^\d{4}-\d{8}-\d{6}\.json$/.test(x)).sort()) {
    const j = await beriJson(join(mapa, ime));
    if (!j) continue;
    const osnova = ime.replace(/\.json$/, '');
    const posnetki = [];
    const mapaPos = join(mapa, osnova + '-klikalnik', 'posnetki');
    if (existsSync(mapaPos)) {
      for (const p of (await fsp.readdir(mapaPos)).filter(x => x.endsWith('.png')).slice(0, 24)) posnetki.push(`preverjanja/${osnova}-klikalnik/posnetki/${p}`);
    }
    const klikalnik = existsSync(join(mapa, osnova + '.klikalnik.md')) ? `preverjanja/${osnova}.klikalnik.md` : null;
    const zapis = { ...j, osnova, posnetki, klikalnik,
      koraki: (j.koraki || []).map(k => ({ ...k, izhod: k.izhod ? 'preverjanja/' + relative(mapa, k.izhod).split(sep).join('/') : null })) };
    (poNalogi[j.id] ||= []).push(zapis);
  }
  return poNalogi;
}

// ------------------------------------------------------------------ agenti, mesta, dnevnik
async function agenti() {
  const mapa = join(MAPA, 'agenti');
  let imena = [];
  try { imena = (await fsp.readdir(mapa)).filter(x => x.endsWith('.json')); } catch { }
  const izid = [];
  for (const ime of imena) {
    const a = await beriJson(join(mapa, ime));
    if (!a) continue;
    const starost = (zdaj() - (cas(a.utrip) ?? 0)) / 60000;
    if (a.stanje === 'končal' && starost > 15) continue;
    a.starostMin = Math.round(starost);
    a.trajanjeMin = Math.round((zdaj() - (cas(a.zacetek) ?? zdaj())) / 60000);
    a.zdravje = a.stanje === 'končal' ? 'koncal' : starost < 10 ? 'ziv' : starost < 30 ? 'tiho' : 'zastal';
    izid.push(a);
  }
  return izid.sort((a, b) => (a.id || 0) - (b.id || 0));
}

async function mesta(stMest) {
  const izid = [];
  for (let k = 1; k <= stMest; k++) {
    const j = await beriJson(join(MAPA, `.vrata-${k}`));
    izid.push(j ? { ...j, mesto: k, vrata: 5070 + k, trajanjeMin: Math.round((zdaj() - (cas(j.od) ?? zdaj())) / 60000) } : { mesto: k, vrata: 5070 + k, prosto: true });
  }
  return izid;
}

async function dnevnik(n = 500) {
  const t = await beri(join(MAPA, 'dnevnik.log'));
  if (!t) return [];
  return t.trim().split(/\r?\n/).slice(-n).map(v => { const [c, seja, id, ...b] = v.split('\t'); return { cas: c, seja, id: Number(String(id || '').replace('#', '')) || 0, besedilo: b.join(' ') }; });
}

async function migracije() {
  const t = await beri(join(MAPA, 'migracije.txt'));
  if (!t) return [];
  return t.trim().split(/\r?\n/).slice(-15).reverse().map(v => { const [st, ime, id, seja, c] = v.split('\t'); return { st, ime, id, seja, cas: c }; });
}

// ------------------------------------------------------------------ git (predpomnjeno, ker je počasno)
let gitPredpomnilnik = { cas: 0, podatki: null };
async function gitStanje(glavnaVeja) {
  if (gitPredpomnilnik.podatki && zdaj() - gitPredpomnilnik.cas < 20000) return gitPredpomnilnik.podatki;
  const kopije = []; let cur = null;
  for (const v of (await git(['worktree', 'list', '--porcelain'])).split(/\r?\n/)) {
    if (v.startsWith('worktree ')) { if (cur) kopije.push(cur); cur = { pot: v.slice(9), veja: '' }; }
    else if (v.startsWith('branch ')) cur.veja = v.slice(7).replace('refs/heads/', '');
    else if (v === 'prunable' || v.startsWith('prunable')) cur.manjka = true;
  }
  if (cur) kopije.push(cur);
  await Promise.all(kopije.map(async k => {
    if (k.manjka || !existsSync(k.pot)) { k.manjka = true; return; }
    k.spremembe = (await git(['status', '--porcelain', '--untracked-files=no'], k.pot)).split('\n').filter(Boolean).length;
    k.zadnji = (await git(['log', '-1', '--format=%cr · %s'], k.pot)).trim();
    k.naprej = Number((await git(['rev-list', '--count', `${glavnaVeja}..HEAD`], k.pot)).trim() || 0);
  }));
  const integracija = (await git(['log', '-25', '--format=%h\t%cI\t%an\t%s', glavnaVeja])).trim().split('\n').filter(Boolean)
    .map(v => { const [hash, c, avtor, ...s] = v.split('\t'); return { hash, cas: c, avtor, sporocilo: s.join(' ') }; });
  gitPredpomnilnik = { cas: zdaj(), podatki: { kopije, integracija } };
  return gitPredpomnilnik.podatki;
}

// ------------------------------------------------------------------ seje Claude (prepisi)
// Resnični znak življenja: prepis seje/podagenta se spremeni ob vsakem koraku. Tako plošča vidi
// agente tudi, če pozabijo na utrip.
async function seje() {
  const izid = { seje: [], podagenti: [] };
  if (!existsSync(PREPISI)) return izid;
  const meja = zdaj() - 60 * 60000;
  for (const ime of await fsp.readdir(PREPISI)) {
    if (!ime.endsWith('.jsonl')) continue;
    const pot = join(PREPISI, ime);
    const st = statSync(pot);
    if (st.mtimeMs < meja) continue;
    const id = ime.replace('.jsonl', '');
    const naslov = (await beriJson(join(PREPISI, id, 'custom-title.json')))?.customTitle || 'seja ' + id.slice(0, 8);
    izid.seje.push({ id, naslov, starostMin: Math.round((zdaj() - st.mtimeMs) / 60000) });
    // podagenti te seje (tudi agenti tokov), aktivni v zadnjih 15 min
    const mapaPod = join(PREPISI, id, 'subagents');
    if (!existsSync(mapaPod)) continue;
    const pregledaj = async (mapa, tok) => {
      for (const e of await fsp.readdir(mapa, { withFileTypes: true })) {
        const p = join(mapa, e.name);
        if (e.isDirectory()) { await pregledaj(p, e.name.startsWith('wf_') ? e.name : tok); continue; }
        if (!e.name.endsWith('.jsonl') || !e.name.startsWith('agent-')) continue;
        const s = statSync(p);
        if (s.mtimeMs < zdaj() - 15 * 60000) continue;
        const meta = await beriJson(p.replace(/\.jsonl$/, '.meta.json')) || {};
        izid.podagenti.push({ seja: naslov, tok, opis: meta.description || e.name, faza: meta.workflowPhase || '', starostMin: Math.round((zdaj() - s.mtimeMs) / 60000) });
      }
    };
    try { await pregledaj(mapaPod, null); } catch { }
  }
  izid.seje.sort((a, b) => a.starostMin - b.starostMin);
  izid.podagenti.sort((a, b) => a.starostMin - b.starostMin);
  return izid;
}

// ------------------------------------------------------------------ skupno stanje
function faza(n, agentiNaloge, vNaMestu) {
  if (n.stanje === 'koncana') return 'zdruzeno';
  if (n.stanje === 'opuscena') return 'opuscena';
  if (n.stanje === 'blokirana') return 'blokirana';
  if (n.stanje === 'pregled') return 'zdruzitev';
  if (vNaMestu || n.stanje === 'preverjanje') return 'vrata';
  const vloge = agentiNaloge.filter(a => a.zdravje !== 'koncal').map(a => a.vloga);
  if (vloge.includes('preverjalec')) return 'preverjanje';
  if (vloge.includes('integrator')) return 'zdruzitev';
  if (n.stanje === 'v-delu') return vloge.includes('vpliv') && !vloge.includes('razvijalec') ? 'vpliv' : 'razvoj';
  if (vloge.includes('vpliv')) return 'vpliv';
  return n.stanje === 'pripravljena' ? 'pripravljena' : 'predlog';
}

async function stanje() {
  const nastavitve = await beriJson(join(MAPA, 'nastavitve.json')) || {};
  const glavnaVeja = nastavitve.glavnaVeja || (await git(['rev-parse', '--abbrev-ref', 'HEAD'])).trim();
  const stMest = Number(nastavitve.vrataHkrati || 3);
  const [nal, ag, me, dn, pr, mig, g, s] = await Promise.all([naloge(), agenti(), mesta(stMest), dnevnik(), preverjanja(), migracije(), gitStanje(glavnaVeja), seje()]);
  for (const n of nal) {
    const aN = ag.filter(a => a.id === n.id);
    n.agenti = aN.map(a => a.seja);
    n.faza = faza(n, aN, me.some(m => !m.prosto && m.id === n.id));
    n.vrata = (pr[n.id] || []).slice(-5).reverse();
  }
  return {
    cas: new Date().toISOString(), glavna: GLAVNA, glavnaVeja, nastavitve, naloge: nal, agenti: ag, mesta: me,
    zdruzevanje: existsSync(join(MAPA, '.zdruzevanje')), preizkusi: javno(), dnevnik: dn, migracije: mig, ...g, ...s,
  };
}

// ------------------------------------------------------------------ ukazi (samo prek Koordinacija.ps1)
const UKAZI = {
  Nova: (b) => ['-Naslov', b.naslov, '-Opis', b.opis || '', '-Prednost', b.prednost || 'S', '-Vrsta', b.vrsta || 'napaka',
    ...(b.strani ? ['-Strani', b.strani] : []), '-Zacetno', b.zacetno === 'predlog' ? 'predlog' : 'pripravljena', '-Vir', 'plošča'],
  Odlocitev: (b) => ['-Id', String(b.id), '-Odgovor', b.odgovor],
  Sporocilo: (b) => ['-Id', String(b.id), '-Besedilo', b.besedilo],
  Zdruzi: (b) => ['-Id', String(b.id)],
  Nastavi: (b) => {
    if (!['prednost', 'stanje'].includes(b.polje)) throw new Error('Polje ni dovoljeno.');
    return ['-Id', String(b.id), '-Polje', b.polje, '-Vrednost', b.vrednost];
  },
};
function izvediUkaz(ukaz, telo) {
  if (!UKAZI[ukaz]) return Promise.reject(new Error('Neznan ukaz.'));
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', KOORD, '-Ukaz', ukaz, '-Seja', 'Lastnik (plošča)', ...UKAZI[ukaz](telo)];
  return new Promise((res) => execFile('powershell.exe', args, { cwd: GLAVNA, encoding: 'utf8', timeout: ukaz === 'Zdruzi' ? 30 * 60000 : 60000, maxBuffer: 8 << 20 },
    (e, out, err) => res({ ok: !e, izhod: (out || '') + (err ? '\n' + err : ''), koda: e?.code ?? 0 })));
}

// ------------------------------------------------------------------ preizkus v aplikaciji (lastnik pred »Združi«)
// Intranet iz KOPIJE naloge (klikalnikov gostitelj: razvojna baza, vgrajen skrbnik, brez prijave) na vratih 5200+id.
const preizkusi = new Map();
async function zazeniPreizkus(id) {
  const obstojec = preizkusi.get(id);
  if (obstojec && obstojec.stanje !== 'napaka') return obstojec;
  const nal = (await naloge()).find(n => n.id === id);
  if (!nal || !nal.pot || !existsSync(nal.pot)) throw new Error('Naloga nima delovne kopije (pot).');
  const nastavitve = await beriJson(join(MAPA, 'nastavitve.json')) || {};
  const streznik = nastavitve.razvojniStreznik, baza = nastavitve.razvojnaBaza || 'PIM';
  if (!streznik) throw new Error('V nastavitve.json ni razvojniStreznik.');
  const port = 5200 + id, mapaK = join(nal.pot, 'PIM_Solution', 'tools', 'PIM.Klikalnik');
  const p = { id, port, url: `http://localhost:${port}/`, stanje: 'gradim', sporocilo: 'Sestavljam aplikacijo iz kopije naloge (1–3 min) …', od: new Date().toISOString() };
  preizkusi.set(id, p);
  const env = { ...process.env, KLIKALNIK_PORT: String(port), KLIKALNIK_STREZNIK: streznik,
    PIM_CONNECTION_STRING: `Server=${streznik};Database=${baza};Integrated Security=True;Encrypt=True;TrustServerCertificate=True` };
  execFile('dotnet', ['build', '-c', 'Release', '-nologo', '-v', 'q', '-nodeReuse:false'], { cwd: mapaK, env, maxBuffer: 16 << 20, timeout: 15 * 60000 }, async (e, out) => {
    if (e) { p.stanje = 'napaka'; p.sporocilo = 'Sestavljanje ni uspelo: ' + String(out || e.message).split(/\r?\n/).filter(v => /error/i.test(v)).slice(0, 2).join(' ').slice(0, 300); return; }
    p.sporocilo = 'Zaganjam aplikacijo …';
    p.proc = spawn('dotnet', [join('bin', 'Release', 'net10.0', 'PIM.Klikalnik.dll')], { cwd: mapaK, env, stdio: 'ignore', windowsHide: true });
    p.proc.on('exit', () => { if (p.stanje !== 'ustavljen') { p.stanje = 'napaka'; p.sporocilo = 'Aplikacija se je ustavila.'; } });
    for (let i = 0; i < 80 && p.stanje === 'gradim'; i++) {
      try { const r = await fetch(p.url + 'brez-dostopa'); if (r.ok) { p.stanje = 'tece'; p.sporocilo = 'Aplikacija teče — razvojna baza, skrbnik brez prijave.'; break; } } catch { }
      await new Promise(r => setTimeout(r, 3000));
    }
    if (p.stanje === 'gradim') { p.stanje = 'napaka'; p.sporocilo = 'Aplikacija se ni odzvala v 4 min.'; }
  });
  return p;
}
function ustaviPreizkus(id) {
  const p = preizkusi.get(id);
  if (p?.proc && !p.proc.killed) { p.stanje = 'ustavljen'; try { execFileSync('taskkill', ['/PID', String(p.proc.pid), '/T', '/F']); } catch { } }
  preizkusi.delete(id);
}
process.on('exit', () => { for (const id of preizkusi.keys()) ustaviPreizkus(id); });
const javno = () => [...preizkusi.values()].map(({ proc, ...p }) => p);

// ------------------------------------------------------------------ strežnik
const TIPI = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.png': 'image/png', '.md': 'text/plain; charset=utf-8', '.txt': 'text/plain; charset=utf-8', '.err': 'text/plain; charset=utf-8' };
const odjemalci = new Set();
let zakasnitev = null;
try {
  watch(MAPA, { recursive: true }, () => {
    clearTimeout(zakasnitev);
    zakasnitev = setTimeout(() => { for (const o of odjemalci) o.write('event: sprememba\ndata: {}\n\n'); }, 300);
  });
} catch (e) { console.error('Opazovanje mape ne deluje, plošča se osvežuje na 10 s:', e.message); }
setInterval(() => { for (const o of odjemalci) o.write('event: utrip\ndata: {}\n\n'); }, 15000);

const strežnik = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const poslji = (koda, tip, telo) => { res.writeHead(koda, { 'content-type': tip, 'cache-control': 'no-store' }); res.end(telo); };
  try {
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) return poslji(200, TIPI['.html'], readFileSync(join(tu, 'index.html')));
    if (req.method === 'GET' && url.pathname === '/api/stanje') return poslji(200, TIPI['.json'], JSON.stringify(await stanje()));
    if (req.method === 'GET' && url.pathname === '/api/dogodki') {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
      res.write('event: utrip\ndata: {}\n\n');
      odjemalci.add(res); req.on('close', () => odjemalci.delete(res));
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/datoteka') {
      const p = resolve(MAPA, url.searchParams.get('p') || '');
      if (!p.startsWith(MAPA + sep) || !existsSync(p)) return poslji(404, TIPI['.txt'], 'Ni datoteke.');
      return poslji(200, TIPI[extname(p)] || TIPI['.txt'], await fsp.readFile(p));
    }
    const mp = /^\/api\/preizkus\/(\d+)(\/ustavi)?$/.exec(url.pathname);
    if (req.method === 'POST' && mp) {
      if (req.headers['x-tabla'] !== '1') return poslji(403, TIPI['.txt'], 'Prepovedano.');
      const id = Number(mp[1]);
      if (mp[2]) { ustaviPreizkus(id); return poslji(200, TIPI['.json'], JSON.stringify({ ok: true })); }
      try { const p = await zazeniPreizkus(id); const { proc, ...j } = p; return poslji(200, TIPI['.json'], JSON.stringify({ ok: true, ...j })); }
      catch (e) { return poslji(400, TIPI['.json'], JSON.stringify({ ok: false, izhod: e.message })); }
    }
    if (req.method === 'POST' && url.pathname.startsWith('/api/ukaz/')) {
      // Varovalka: samo lastna stran (glava, ki je tuja stran brez predhodnega preverjanja ne more poslati).
      if (req.headers['x-tabla'] !== '1') return poslji(403, TIPI['.txt'], 'Prepovedano.');
      let telo = '';
      for await (const kos of req) telo += kos;
      const r = await izvediUkaz(url.pathname.slice('/api/ukaz/'.length), JSON.parse(telo || '{}'));
      gitPredpomnilnik.cas = 0;
      return poslji(r.ok ? 200 : 400, TIPI['.json'], JSON.stringify(r));
    }
    poslji(404, TIPI['.txt'], 'Ni.');
  } catch (e) {
    poslji(500, TIPI['.txt'], String(e?.message || e));
  }
});
strežnik.on('error', (e) => {
  if (e.code === 'EADDRINUSE') { console.log(`Plošča že teče: http://localhost:${PORT}/`); process.exit(0); }
  throw e;
});
strežnik.listen(PORT, '127.0.0.1', () => console.log(`Nadzorna plošča PIM: http://localhost:${PORT}/  (tabla: ${MAPA})`));
