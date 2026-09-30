export const meta = {
  name: 'pim-naloge',
  description: 'Ekipa agentov izvede naloge s table PIM: vpliv, razvoj v lastni kopiji, vrata, preverjanje kot človek, popravki, združevanje, nadzor',
  whenToUse: 'Ko lastnik reče »delaj naloge« (vse pripravljene ali naštete številke). Dispečer najprej prebere tablo (scripts/Koordinacija.ps1 -Ukaz Json) in poda args: {ids: [številke], seja: "ime", zdruzi: true}',
  phases: [
    { title: 'Vpliv', detail: 'pim-vpliv: veriga podatka, avtomatika, območje za zaklep, poslovna vprašanja' },
    { title: 'Razvoj', detail: 'pim-razvijalec v kopiji naloge (-Ukaz Kopija, veja naloga/N iz integracijske veje) do uspešnih vrat' },
    { title: 'Preverjanje', detail: 'pim-preverjalec: vrata, brskalnik v lastnem zavihku, scenarij, hitrost, baza' },
    { title: 'Popravki', detail: 'razvijalec popravi najdbe preverjalca (največ 2 kroga)' },
    { title: 'Združevanje', detail: 'integrator: posodobi vejo, ponovni build, združi v integracijsko vejo; konflikt -> razvijalec' },
    { title: 'Nadzor', detail: 'nadzornik: skladnost table, pozabljeni zaklepi, nepotrjene spremembe, poročilo' },
  ],
}

const ids = ((args && args.ids) || []).map(Number).filter(Boolean)
const seja = (args && args.seja) || 'Ekipa'
const zdruzi = !(args && args.zdruzi === false)
// Nočni način: lastnik spi, rok je jutro. Ekipa ne čaka odgovorov, razen kjer bi napačna izbira škodila.
const nocni = !!(args && args.nocni)
const NOCNI = nocni ? ' NOČNI NAČIN (lastnik spi, rok jutro): ne čakaj lastnika. Pri poslovni nejasnosti izberi NAJBOLJ VARNO možnost, jo zapiši z -Ukaz Sporocilo kot »PRIVZETO ZA NOČ: …, lastnik lahko spremeni« in nadaljuj. Blokiraj (odlocitevBlokira=true) SAMO, če bi napačna izbira trajno pokvarila podatke, šla v SAOP ali na produkcijo. Pri velikih nalogah naredi najpomembnejši del do konca in preostanek zapiši kot nove naloge (-Ukaz Nova).' : ''
if (!ids.length) throw new Error('Podaj args.ids — številke nalog s table (dispečer jih izbere z -Ukaz Json).')

const KOORD = 'powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Koordinacija.ps1'
const ime = (vloga, id) => `${vloga} #${id}`
// Vsak agent se javlja na tablo: tako lastnik na nadzorni plošči (scripts/Tabla.cmd) vidi, kdo dela kaj.
const tabla = (vloga, id) =>
  `\n\nTABLA: tvoje ime (Seja) je "${ime(vloga, id)}". Vse ukaze table kliči z -Seja "${ime(vloga, id)}". ` +
  `Takoj na začetku in ob vsakem večjem koraku (vsaj vsakih 10 min) javi utrip: ` +
  `${KOORD} -Ukaz Utrip -Seja "${ime(vloga, id)}" -Vloga ${vloga} -Id ${id} -Besedilo "<kratko, kaj delaš zdaj>". ` +
  `Na koncu (uspeh ali ne) OBVEZNO: ${KOORD} -Ukaz Odjava -Seja "${ime(vloga, id)}" -Besedilo "<izid v enem stavku>". ` +
  `Če se ustaviš, preden je naloga v pregledu (prekrivanje, napaka, čakanje na drugo nalogo), pred odjavo OBVEZNO ${KOORD} -Ukaz Sprosti -Id ${id}, sicer naloga ostane »v delu« brez agenta in blokira druge. ` +
  `Vsako čakanje v Bashu ima časovno mejo (največ 15 min). Lastnik ni programer: vprašanja zanj piši po domače.`

const VPLIV = {
  type: 'object',
  properties: {
    povzetek: { type: 'string' },
    obmocje: { type: 'array', items: { type: 'string' } },
    strani: { type: 'array', items: { type: 'string' }, description: 'poti strani intraneta brez začetne poševnice' },
    testi: { type: 'array', items: { type: 'string' }, description: 'filtri testnih projektov, npr. F7' },
    tveganja: { type: 'array', items: { type: 'string' } },
    nacrtPreverjanja: { type: 'string' },
    odlocitevPotrebna: { type: 'string', description: 'prazno, če ni poslovnega vprašanja' },
    odlocitevBlokira: { type: 'boolean', description: 'true samo, če brez odgovora lastnika naloge ni mogoče pravilno izvesti' },
  },
  required: ['povzetek', 'obmocje', 'strani', 'testi', 'tveganja', 'nacrtPreverjanja', 'odlocitevPotrebna', 'odlocitevBlokira'],
}
const RAZVOJ = {
  type: 'object',
  properties: {
    uspeh: { type: 'boolean' },
    pot: { type: 'string', description: 'absolutna pot delovne kopije s spremembami' },
    veja: { type: 'string' },
    vrata: { type: 'string', description: 'povzetek zadnjih vrat' },
    kajJeNarejeno: { type: 'string' },
    zaustavljeno: { type: 'string', description: 'razlog, če se je ustavil' },
    prekrivanjeZ: { type: 'array', items: { type: 'number' }, description: 'številke nalog, s katerimi se območje prekriva (Prevzemi zavrnil)' },
  },
  required: ['uspeh', 'pot', 'veja', 'vrata', 'kajJeNarejeno', 'zaustavljeno', 'prekrivanjeZ'],
}
const PREVERBA = {
  type: 'object',
  properties: {
    sprejeto: { type: 'boolean' },
    napake: { type: 'array', items: { type: 'string' } },
    casiStrani: { type: 'array', items: { type: 'string' } },
    dokazi: { type: 'string', description: 'posnetki, poizvedbe, kaj je bilo kliknjeno' },
  },
  required: ['sprejeto', 'napake', 'casiStrani', 'dokazi'],
}
const ZDRUZITEV = {
  type: 'object',
  properties: {
    zdruzeno: { type: 'boolean' },
    commit: { type: 'string' },
    konflikt: { type: 'boolean', description: 'true, če je Zdruzi javil konflikt ali padel build po posodobitvi' },
    sporocilo: { type: 'string' },
  },
  required: ['zdruzeno', 'commit', 'konflikt', 'sporocilo'],
}
const NADZOR = {
  type: 'object',
  properties: {
    povzetek: { type: 'string' },
    tezave: { type: 'array', items: { type: 'string' } },
    popravljeno: { type: 'array', items: { type: 'string' } },
  },
  required: ['povzetek', 'tezave', 'popravljeno'],
}

// Naloga, ki čaka zaradi prekrivanja, počaka konec druge naloge v istem teku in poskusi znova.
const konec = {}
const razresi = {}
for (const id of ids) konec[id] = new Promise((r) => { razresi[id] = r })

async function razvijaj(id, vpliv, poskus) {
  return agent(
    `Izvedi nalogo #${id} s table PIM. Analiza vpliva:\n${JSON.stringify(vpliv, null, 2)}\n\n` +
    `Delaš v svoji delovni kopiji naloge, ki jo naredi tabla iz integracijske veje: ${KOORD} -Ukaz Kopija -Id ${id} -Seja "${ime('razvijalec', id)}" ` +
    `(zadnja vrstica izpisa je pot). OD TU NAPREJ vsak ukaz poganjaj v tej mapi (cd "<pot>" && ...), datoteke beri in urejaj samo pod to potjo, ` +
    `tudi tablo kliči iz nje (powershell ... -File scripts/Koordinacija.ps1). Glavne kopije ne spreminjaj. Nato ` +
    `${KOORD} -Ukaz Prevzemi -Id ${id} -Seja "${ime('razvijalec', id)}" (iz kopije). Če Prevzemi zavrne zaradi prekrivanja, NE nadaljuj: ` +
    `vrni uspeh=false in v prekrivanjeZ številke nalog iz sporočila. ` +
    `Območje, strani in teste iz analize zapiši na nalogo (-Ukaz Nastavi -Polje obmocje / strani / testi), če se razlikujejo. ` +
    `Končaj z uspešnimi vrati (-Ukaz Preveri -Id ${id}) in commitom na veji. Ne kliči Koncaj. ` + NOCNI + ' ' +
    (vpliv.odlocitevPotrebna ? `Odprto vprašanje, ki te naloge ne blokira: "${vpliv.odlocitevPotrebna}" — ustvari zanj ločeno nalogo (-Ukaz Nova) z -Ukaz Odlocitev in nadaljuj po najbolj varni poti. ` : '') +
    `Če potrebuješ odločitev lastnika, jo zapiši (-Ukaz Odlocitev) in se ustavi.` + tabla('razvijalec', id),
    // Brez isolation: 'worktree' — ta kopija izhaja iz main (prazen GitHub začetek) in prepove zagon table.
    { agentType: 'pim-razvijalec', phase: 'Razvoj', label: `razvoj #${id}${poskus ? ' (znova)' : ''}`, schema: RAZVOJ })
}

async function popravi(id, razvoj, navodilo, faza, oznaka) {
  return agent(
    `Popravi nalogo #${id}. Delaš SAMO v delovni kopiji ${razvoj.pot} (veja ${razvoj.veja}) — vsak ukaz poganjaj tam (cd). ` +
    navodilo + `\nPo popravku ponovno zaženi vrata (-Ukaz Preveri -Id ${id}) in commitaj. Vrni isto pot in vejo.` + tabla('razvijalec', id),
    { agentType: 'pim-razvijalec', phase: faza, label: oznaka, schema: RAZVOJ })
}

async function zdruzuj(id, razvoj, krog) {
  return agent(
    `Združi nalogo #${id} v integracijsko vejo. Delovna kopija naloge: ${razvoj.pot} (veja ${razvoj.veja}). ` +
    `Zaženi iz te mape: ${KOORD} -Ukaz Zdruzi -Id ${id} -Seja "${ime('integrator', id)}" -Vloga integrator ` +
    `(ukaz sam počaka v vrsti, posodobi vejo z integracijsko vejo, ponovno zgradi in združi; lahko traja do 30 min — Bash timeout 1800000). ` +
    `Ničesar ne popravljaj sam. Če javi konflikt ali padel build, vrni konflikt=true in točno sporočilo. ` +
    `commit = kratki hash iz izpisa »združena v … (hash)«.` + tabla('integrator', id),
    { agentType: 'general-purpose', model: 'sonnet', effort: 'low', phase: 'Združevanje', label: `združi #${id}${krog ? ' (znova)' : ''}`, schema: ZDRUZITEV })
}

async function obdelaj(id) {
  const izid = { id }
  try {
    // 1) Vpliv
    const vpliv = await agent(
      `Analiziraj vpliv naloge #${id} s table PIM (${KOORD} -Ukaz Json; besedilo naloge je v <git-common-dir>/pim-koordinacija/naloge/${String(id).padStart(4, '0')}.md). ` +
      `Predlagaj natančno območje datotek za zaklep, strani za klikalnik in teste. Preveri, ali se območje prekriva z nalogami v delu. ` +
      `Če je potrebna poslovna odločitev, ki blokira nalogo, jo SAM zapiši na tablo: ${KOORD} -Ukaz Odlocitev -Id ${id} -Besedilo "<vprašanje po domače, z možnostmi>".` + NOCNI +
      tabla('vpliv', id),
      { agentType: 'pim-vpliv', phase: 'Vpliv', label: `vpliv #${id}`, schema: VPLIV })
    izid.vpliv = vpliv
    if (!vpliv) { izid.ustavljeno = 'analiza vpliva ni uspela'; return izid }
    if (vpliv.odlocitevPotrebna && vpliv.odlocitevBlokira) { izid.ustavljeno = 'čaka odločitev lastnika: ' + vpliv.odlocitevPotrebna; return izid }

    // 2) Razvoj (ob prekrivanju z nalogo iz istega teka počaka njen konec in poskusi še enkrat)
    let razvoj = await razvijaj(id, vpliv, 0)
    if (razvoj && !razvoj.uspeh && razvoj.prekrivanjeZ && razvoj.prekrivanjeZ.length) {
      const nasi = razvoj.prekrivanjeZ.filter((x) => konec[x] && x !== id)
      if (nasi.length === razvoj.prekrivanjeZ.length) {
        log(`#${id} čaka konec #${nasi.join(', #')} (isto območje), nato znova.`)
        await Promise.all(nasi.map((x) => konec[x]))
        razvoj = await razvijaj(id, vpliv, 1)
      }
    }
    izid.razvoj = razvoj
    if (!razvoj || !razvoj.uspeh) { izid.ustavljeno = razvoj ? razvoj.zaustavljeno : 'razvijalec ni odgovoril'; return izid }

    // 3) Preverjanje kot človek, 4) največ dva kroga popravkov
    let preverba = null
    for (let krog = 0; krog < 3; krog++) {
      preverba = await agent(
        `Preveri nalogo #${id} kot človek. Spremembe so v delovni kopiji ${razvoj.pot} (veja ${razvoj.veja}) — vse ukaze poganjaj tam. ` +
        `Načrt preverjanja iz analize: ${vpliv.nacrtPreverjanja}\nStrani: ${(vpliv.strani || []).join(', ') || '(iz naloge)'}\n` +
        `Testni intranet zaženi iz TE kopije na vratih ${5100 + (id % 800)} (KLIKALNIK_PORT, KLIKALNIK_STREZNIK = razvojniStreznik iz <git-common-dir>/pim-koordinacija/nastavitve.json). ` +
        `V brskalniku odpri SVOJ zavihek (mcp__Claude_Browser__tabs_create) in vse klice delaj z njegovim tabId; na koncu ga zapri — hkrati preverja več agentov. ` +
        `Če je vse v redu, pokliči -Ukaz Koncaj -Id ${id} z opisom dokazov. Sicer vrni seznam napak (konkretno, kako ponoviti).` + tabla('preverjalec', id),
        { agentType: 'pim-preverjalec', phase: 'Preverjanje', label: `preverjanje #${id} (${krog + 1})`, schema: PREVERBA })
      if (!preverba || preverba.sprejeto || krog === 2) break
      const pop = await popravi(id, razvoj, 'Najdbe preverjalca:\n- ' + preverba.napake.join('\n- '), 'Popravki', `popravki #${id} (${krog + 1})`)
      if (!pop || !pop.uspeh) { izid.ustavljeno = 'popravek ni uspel: ' + (pop ? pop.zaustavljeno : 'agent ni odgovoril'); break }
      razvoj = { ...razvoj, ...pop, pot: pop.pot || razvoj.pot, veja: pop.veja || razvoj.veja }
    }
    izid.razvoj = razvoj
    izid.preverba = preverba
    if (!preverba || !preverba.sprejeto || !zdruzi) return izid

    // 5) Združevanje; ob konfliktu razvijalec posodobi vejo in poskusimo še enkrat
    let z = await zdruzuj(id, razvoj, 0)
    if (z && !z.zdruzeno && z.konflikt) {
      const pop = await popravi(id, razvoj,
        `Združevanje ni uspelo: ${z.sporocilo}\nV svoji kopiji združi integracijsko vejo (glavnaVeja iz nastavitve.json): git merge <glavnaVeja>, razreši konflikte ` +
        `tako, da ohraniš tudi tuje spremembe, zgradi, zaženi vrata, commitaj in nalogo vrni v pregled: -Ukaz Nastavi -Id ${id} -Polje stanje -Vrednost pregled.`,
        'Združevanje', `konflikt #${id}`)
      if (pop && pop.uspeh) z = await zdruzuj(id, razvoj, 1)
    }
    izid.zdruzitev = z
    return izid
  } finally {
    razresi[id]()
  }
}

phase('Vpliv')
log(`Ekipa začenja: ${ids.length} nalog (#${ids.join(', #')}), združevanje ${zdruzi ? 'samodejno' : 'ročno (lastnik)'}.`)
const rezultati = (await parallel(ids.map((id) => () => obdelaj(id)))).map((r, i) => r || { id: ids[i], ustavljeno: 'tok za nalogo je padel' })

phase('Nadzor')
const nadzor = await agent(
  `Si nadzornik ekipe PIM. Ekipa je pravkar obdelala naloge #${ids.join(', #')}. Izidi toka:\n${JSON.stringify(rezultati.map((r) => ({
    id: r.id, ustavljeno: r.ustavljeno || '', sprejeto: !!(r.preverba && r.preverba.sprejeto), zdruzeno: !!(r.zdruzitev && r.zdruzitev.zdruzeno), pot: r.razvoj && r.razvoj.pot,
  })), null, 2)}\n\n` +
  `Preveri tablo in pospravi, NE spreminjaj kode:\n` +
  `1. ${KOORD} -Ukaz Json: ali je stanje vsake naloge skladno z izidom (združena=koncana, sprejeta=pregled, ustavljena z razlogom v dnevniku). ` +
  `Nalogo, ki je ostala v-delu brez agenta, vrni: -Ukaz Sprosti -Id N -Besedilo "<razlog>". Razlog ustavitve zapiši z -Ukaz Sporocilo, če ga ni.\n` +
  `2. <git-common-dir>/pim-koordinacija/agenti/*.json za te naloge: agente, ki se niso odjavili, odjavi (-Ukaz Odjava -Seja "<seja>" -Besedilo "pospravil nadzornik").\n` +
  `3. Datoteke .vrata-* in .zdruzevanje, starejše od 60 min brez živega procesa: izbriši.\n` +
  `4. git worktree list: delovne kopije teh nalog z nepotrjenimi spremembami naštej (ne briši).\n` +
  `Vrni povzetek za lastnika (slovensko, po domače): kaj je združeno, kaj čaka njega, kaj je obstalo in zakaj.` + tabla('nadzornik', 0),
  { agentType: 'general-purpose', model: 'sonnet', phase: 'Nadzor', label: 'nadzornik', schema: NADZOR })

const sprejete = rezultati.filter((r) => r.preverba && r.preverba.sprejeto)
const zdruzene = rezultati.filter((r) => r.zdruzitev && r.zdruzitev.zdruzeno)
log(`Sprejetih ${sprejete.length}/${ids.length}, združenih ${zdruzene.length}.`)
return {
  seja,
  nadzor,
  naloge: rezultati.map((r) => ({
    id: r.id,
    sprejeto: !!(r.preverba && r.preverba.sprejeto),
    zdruzeno: !!(r.zdruzitev && r.zdruzitev.zdruzeno),
    commit: r.zdruzitev ? r.zdruzitev.commit : '',
    ustavljeno: r.ustavljeno || (r.razvoj && r.razvoj.zaustavljeno) || (r.zdruzitev && !r.zdruzitev.zdruzeno ? r.zdruzitev.sporocilo : ''),
    veja: r.razvoj && r.razvoj.veja,
    pot: r.razvoj && r.razvoj.pot,
    narejeno: r.razvoj && r.razvoj.kajJeNarejeno,
    vrata: r.razvoj && r.razvoj.vrata,
    napake: r.preverba ? r.preverba.napake : [],
    casi: r.preverba ? r.preverba.casiStrani : [],
    dokazi: r.preverba ? r.preverba.dokazi : '',
  })),
}
