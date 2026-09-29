export const meta = {
  name: 'pim-naloge',
  description: 'Izvede naloge s table PIM: analiza vpliva, razvoj v lastni delovni kopiji, vrata in preverjanje kot človek, popravki do uspeha',
  whenToUse: 'Ko lastnik reče »delaj naloge« ali ko je na tabli (scripts/Koordinacija.ps1) več pripravljenih nalog brez prekrivanja. args: {ids: [številke nalog], seja: "ime"}',
  phases: [
    { title: 'Vpliv', detail: 'pim-vpliv: veriga podatka, avtomatika, območje, načrt preverjanja' },
    { title: 'Razvoj', detail: 'pim-razvijalec v lastni delovni kopiji do uspešnih vrat' },
    { title: 'Preverjanje', detail: 'pim-preverjalec: vrata, brskalnik, scenarij, hitrost' },
    { title: 'Popravki', detail: 'razvijalec popravi najdbe preverjalca (največ 2 kroga)' },
  ],
}

const ids = (args && args.ids) || []
const seja = (args && args.seja) || 'Tok nalog'
if (!ids.length) throw new Error('Podaj args.ids — številke nalog s table.')

const KOORD = 'powershell -ExecutionPolicy Bypass -File scripts/Koordinacija.ps1'
// Vloge so v .claude/agents/*.md. Seja jih naloži samo ob zagonu, zato jih agent prebere sam —
// tok deluje tudi v sejah, odprtih pred nastankom vloge.
const vloga = (ime) => "Najprej preberi datoteko .claude/agents/" + ime + ".md (v korenu repozitorija ali svoje delovne kopije; glavna kopija je C:/Users/David/Documents/GitHub/PIM) — vse za drugo vrstico --- — in delaj natanko po tej vlogi. "

const VPLIV = {
  type: 'object',
  properties: {
    povzetek: { type: 'string' },
    obmocje: { type: 'array', items: { type: 'string' } },
    tveganja: { type: 'array', items: { type: 'string' } },
    nacrtPreverjanja: { type: 'string' },
    odlocitevPotrebna: { type: 'string', description: 'prazno, če ni poslovnega vprašanja' },
    odlocitevBlokira: { type: 'boolean', description: 'true samo, če brez odgovora lastnika naloge sploh ni mogoče pravilno izvesti' },
  },
  required: ['povzetek', 'obmocje', 'tveganja', 'nacrtPreverjanja', 'odlocitevPotrebna', 'odlocitevBlokira'],
}
const RAZVOJ = {
  type: 'object',
  properties: {
    uspeh: { type: 'boolean' },
    pot: { type: 'string', description: 'absolutna pot delovne kopije, kjer so spremembe' },
    veja: { type: 'string' },
    vrata: { type: 'string', description: 'povzetek zadnjih vrat' },
    kajJeNarejeno: { type: 'string' },
    zaustavljeno: { type: 'string', description: 'razlog, če se je ustavil (prekrivanje, odločitev ...)' },
  },
  required: ['uspeh', 'pot', 'veja', 'vrata', 'kajJeNarejeno', 'zaustavljeno'],
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

const rezultati = await pipeline(
  ids,
  (id) => agent(
    vloga('pim-vpliv') + `Analiziraj vpliv naloge #${id} s table PIM (preberi jo: ${KOORD} -Ukaz Stanje, datoteka naloge v <git-common-dir>/pim-koordinacija/naloge/${String(id).padStart(4, '0')}.md). ` +
    `Predlagaj natančno območje datotek za zaklep. Če je potrebna poslovna odločitev lastnika, jo opiši v odlocitevPotrebna.`,
    { agentType: 'general-purpose', phase: 'Vpliv', label: `vpliv #${id}`, schema: VPLIV }),

  async (vpliv, id) => {
    if (!vpliv) return { id, ustavljeno: 'analiza vpliva ni uspela' }
    if (vpliv.odlocitevPotrebna && vpliv.odlocitevBlokira) {
      return { id, vpliv, ustavljeno: 'čaka odločitev lastnika: ' + vpliv.odlocitevPotrebna,
        opomba: `Zapiši: ${KOORD} -Ukaz Odlocitev -Id ${id} -Besedilo "..."` }
    }
    const razvoj = await agent(
      vloga('pim-razvijalec') + `Izvedi nalogo #${id} s table PIM kot seja "${seja} #${id}". Analiza vpliva:\n${JSON.stringify(vpliv, null, 2)}\n` +
      `Delaš v svoji delovni kopiji (worktree): najprej ustvari vejo naloga/${id} (git switch -c), nato Prevzemi. ` +
      `Po potrebi dopolni območje z -Ukaz Nastavi -Polje obmocje. Končaj z uspešnimi vrati (-Ukaz Preveri) in commitom na veji. ` +
      (vpliv.odlocitevPotrebna ? `Odprto vprašanje, ki te naloge ne blokira: "${vpliv.odlocitevPotrebna}" — zanj ustvari ločeno nalogo (-Ukaz Nova) in ga zapiši z -Ukaz Odlocitev, nato nadaljuj. ` : '') +
      `Ne kliči Koncaj. Če se območje prekriva z drugo nalogo ali potrebuješ odločitev, se ustavi in to vrni v zaustavljeno.`,
      { agentType: 'general-purpose', phase: 'Razvoj', label: `razvoj #${id}`, isolation: 'worktree', schema: RAZVOJ })
    return { id, vpliv, razvoj }
  },

  async (stanje) => {
    if (!stanje || stanje.ustavljeno || !stanje.razvoj || !stanje.razvoj.uspeh) return stanje
    let { razvoj } = stanje
    let preverba = null
    for (let krog = 0; krog < 3; krog++) {
      preverba = await agent(
        vloga('pim-preverjalec') + `Preveri nalogo #${stanje.id} kot človek. Spremembe so v delovni kopiji ${razvoj.pot} (veja ${razvoj.veja}) — vse ukaze poganjaj tam. ` +
        `Načrt preverjanja iz analize: ${stanje.vpliv.nacrtPreverjanja}\n` +
        `Če je vse v redu, pokliči -Ukaz Koncaj. Vrni seznam napak, ki jih mora razvijalec popraviti.`,
        { agentType: 'general-purpose', phase: 'Preverjanje', label: `preverjanje #${stanje.id} (${krog + 1})`, schema: PREVERBA })
      if (!preverba || preverba.sprejeto || krog === 2) break
      const popravek = await agent(
        vloga('pim-razvijalec') + `Popravi nalogo #${stanje.id} v delovni kopiji ${razvoj.pot} (veja ${razvoj.veja}; delaj samo tam). Najdbe preverjalca:\n- ` +
        preverba.napake.join('\n- ') + `\nPo popravku ponovno zaženi vrata (-Ukaz Preveri) in commitaj.`,
        { agentType: 'general-purpose', phase: 'Popravki', label: `popravki #${stanje.id} (${krog + 1})`, schema: RAZVOJ })
      if (!popravek || !popravek.uspeh) { stanje.ustavljeno = 'popravek ni uspel: ' + (popravek ? popravek.zaustavljeno : 'agent ni odgovoril'); break }
      razvoj = popravek
    }
    return { ...stanje, razvoj, preverba }
  },
)

const koncano = rezultati.filter(r => r && r.preverba && r.preverba.sprejeto)
const odprto = rezultati.filter(r => !r || !(r.preverba && r.preverba.sprejeto))
log(`Sprejetih ${koncano.length} od ${ids.length}; odprtih ${odprto.length}.`)
return rezultati.map(r => r && ({
  id: r.id,
  sprejeto: !!(r.preverba && r.preverba.sprejeto),
  ustavljeno: r.ustavljeno || (r.razvoj && r.razvoj.zaustavljeno) || '',
  veja: r.razvoj && r.razvoj.veja,
  pot: r.razvoj && r.razvoj.pot,
  narejeno: r.razvoj && r.razvoj.kajJeNarejeno,
  vrata: r.razvoj && r.razvoj.vrata,
  napake: r.preverba ? r.preverba.napake : [],
  casi: r.preverba ? r.preverba.casiStrani : [],
  dokazi: r.preverba ? r.preverba.dokazi : '',
}))
