# -*- coding: utf-8 -*-
"""
Iz izpisa Matrike mastrov starega PIM-a in registra atributov NoviPIM naredi seznam kandidatov
(drevo, kategorija, koda atributa, zasedenost, mastri) za nabore po kategorijah.

Odlocitve (master -> kategorija, ime -> koda) so v tej datoteki in v
docs/NABORI_ATRIBUTOV_IZ_MASTROV.md. Skripta NE pise v bazo: raven (REQUIRED/RECOMMENDED) doloci SQL
po pravilu iz dokumenta, rezultat pa se zapise kot migracija (prva je 173). Ce se Matrika spremeni,
se naredi nova migracija.

Uporaba:
  python tools/Mastri/build_category_attribute_sets.py \
    --seed ../PIM_test/sql/migrations/tools/Seed_CategoryAttributeImport_Mastri.sql \
    --register register.tsv --out candidates.tsv

  register.tsv: AttributeCode|sl|IsUnitCandidate  (sqlcmd -u, iconv UTF-16 -> UTF-8), npr.
    SELECT d.AttributeCode, sl = (SELECT TOP 1 Name FROM canon.AttributeTranslation t
      WHERE t.AttributeCode = d.AttributeCode AND LanguageCode = 'sl'), d.IsUnitCandidate
    FROM canon.AttributeDefinition d WHERE d.IsActive = 1;
"""
import argparse, re, unicodedata, collections, statistics

parser = argparse.ArgumentParser()
parser.add_argument('--seed', required=True, help='Seed_CategoryAttributeImport_Mastri.sql iz PIM_test')
parser.add_argument('--register', required=True, help='register.tsv (AttributeCode|sl|IsUnitCandidate)')
parser.add_argument('--out', required=True, help='candidates.tsv')
parser.add_argument('--unmatched', default=None, help='neujeta imena s stevilom pojavitev')
args = parser.parse_args()

def norm(s):
    s = unicodedata.normalize('NFKD', s); s = ''.join(c for c in s if not unicodedata.combining(c))
    return ' '.join(s.lower().replace('.', ' ').replace('-', ' ').replace('/', ' ').split())

register = {}
codes = set()
for line in open(args.register, encoding='utf-8'):
    p = line.rstrip('\n').split('|')
    if len(p) < 3 or p[0] == 'AttributeCode' or p[0].startswith('-'): continue
    code, sl, unit = p[0].strip(), p[1].strip(), p[2].strip()
    if unit == '1': continue           # enote niso atributi nabora
    codes.add(code); register[norm(sl)] = code; register[norm(code)] = code

src = open(args.seed, encoding='utf-8-sig').read()
rows = [(m, a.replace("''", "'"), g, int(f)) for _, m, a, g, f in
        re.findall(r"\(@BatchId, (\d+), N'MASTRI', N'([^']+)', N'((?:[^']|'')+)', N'([^']+)', (\d+)\)", src)]
# Aliasi: ime v Matriki -> koda registra. Samo nedvoumni pomeni.
ALIAS={
 'Garancija':'GARANCIJA','IP zaščita':'IP_STOPNJA_ZASCITE','Nazivna napetost':'NAZIVNA_NAPETOST','Napetost':'NAPETOST',
 'Napetost od':'NAPETOST','Napetost do':'NAPETOST','Vhodna napetost':'NAPETOST','Vhodna napetost min.':'NAPETOST','Vhodna napetost max.':'NAPETOST','Vrsta napetosti':'NAPETOST',
 'Svetlobni tok':'SVETLOBNI_TOK','CELOTNI SVETLOBNI TOK':'SVETLOBNI_TOK',
 'Temperatura svetlobe':'TEMPERATURA_BARVE','Barva svetlobe':'TEMPERATURA_BARVE','Barva svetlobe (K)':'TEMPERATURA_BARVE','PODOBNA BARVNA TEMPERATURA':'TEMPERATURA_BARVE',
 'Življenjska doba':'ZIVLJENJSKA_DOBA','CRI':'INDEKS_BARVNEGA_VIDEZA_CRI','REPRODUKCIJA BARV':'INDEKS_BARVNEGA_VIDEZA_CRI',
 'Dimmable':'ZATEMNLJIVO','Kot svetenja':'KOT_SVETLOBNEGA_SNOPA','Način montaže':'NACIN_MONTAZE','Vrsta montaže':'NACIN_MONTAZE','Montaža tračne luči':'NACIN_MONTAZE',
 'Dolžina':'DOLZINA','Širina':'SIRINA','Premer':'PREMER','Vidna dim. višina':'VISINA','Vidna dim. širina':'SIRINA','Vidna dim. dolžina':'DOLZINA',
 'Grlo':'GRLO','Frekvence':'FREKVENCA','Frekvenca':'FREKVENCA','Energijski razred':'ENERGIJSKI_RAZRED','Ekvivalent':'EKVIVALENT','Baterija':'BATERIJA',
 'Max moč sijalke':'MAX_MOC_SIJALKE','Moč':'NAZIVNA_MOC','ELEKTRIČNA MOČ':'NAZIVNA_MOC','Max moč':'NAZIVNA_MOC','Max. moč':'NAZIVNA_MOC','Moč max.':'NAZIVNA_MOC',
 'Nazivni tok':'NAZIVNA_JAKOST_TOKA','Barva':'PREVLADUJOCA_BARVA','Barva (nesklanjana)':'PREVLADUJOCA_BARVA','Barva-lastnost':'PREVLADUJOCA_BARVA','Lastnost barve':'PREVLADUJOCA_BARVA','Barva lastnost':'PREVLADUJOCA_BARVA',
 'Material':'PREVLADUJOC_MATERIAL','Material ohišja':'PREVLADUJOC_MATERIAL','Metarial ohišja':'PREVLADUJOC_MATERIAL','OHIŠJE':'PREVLADUJOC_MATERIAL',
 'Uporaba':'UPORABA','Način uporabe':'UPORABA','Presek kabla':'PRESEK_KABLA','Presek žice':'PRESEK_KABLA',
 'Temperaturno območje':'DELOVNA_TEMPERATURA','Temperatura delovanja':'DELOVNA_TEMPERATURA','Temperatura delovanja (min/max)':'DELOVNA_TEMPERATURA',
 'Senzor':'SENZOR_GIBANJA','Vključuje sijalko':'SVETILKA_VKLJUCUJE_SVETLOBNI_VIR','SVETLOBNI VIR':'VRSTA_SVETLOBNEGA_VIRA','Tehnologija LED':'VRSTA_SVETLOBNEGA_VIRA','LED':'VRSTA_SVETLOBNEGA_VIRA','Tip svetlobe':'VRSTA_SVETLOBNEGA_VIRA','Tip sijalke':'VRSTA_SVETLOBNEGA_VIRA',
 'Število sijalk':'STEVILO_SVETLOBNIH_VIROV','STIL':'SLOG','Kot zaznavanja':'KOT_DETEKCIJE','Domet':'RAZDALJA_DETEKCIJE',
 'Kompatibilno':'ZDRUZLJIVO_Z','Kompatibilno z':'ZDRUZLJIVO_Z','Višina montaže':'MONTAZNA_VISINA','AVTONOMIJA':'DELOVNI_CAS','Čas delovanja':'DELOVNI_CAS','Polnjenje':'NACIN_POLNJENJA',
 'Velikost':'VELIKOST','Kabel':'VRSTA_KABLA','Priključni kabel':'VRSTA_KABLA','Klasa':'ELEKTRICNI_RAZRED','Vrsta svetilke':'OBLIKA_SVETILKE','Vrsta svetilke 1':'OBLIKA_SVETILKE','Tip svetilke':'OBLIKA_SVETILKE',
}
LIGHT_ONLY_ALIAS={'Oblika':'OBLIKA_SVETILKE'}   # v elektro mastrih "Oblika" pomeni obliko doze/uvodnice
for a,c in list(ALIAS.items())+list(LIGHT_ONLY_ALIAS.items()):
    assert c in codes, (a,c)

# Master -> (drevo, kategorija) ; vec ciljev dovoljenih
V='videlektro'; L='svetila_si'
BRAND=['2A1','2A5','2A6','2A7','2A8','2A9','2A10','2A13']   # splosna svetila po blagovnih znamkah -> korenski nabor svetil
MAP={
 '1A1':[(V,'instalacije___kabli_in_vodniki___kabelski_spoji_in_zalivke')],'1A2':[(V,'instalacije___kabli_in_vodniki___kabelski_spoji_in_zalivke')],
 '1A3':[(V,'instalacije___kabli_in_vodniki___kabelski_koncniki_in_spojke')],'1A4':[(V,'instalacije___kabli_in_vodniki___kabelski_spojni_material')],
 '1A5':[(V,'instalacije___kabli_in_vodniki___podaljski_in_razdelilci')],'1A6':[(V,'instalacije___kabli_in_vodniki')],
 '1B1':[(V,'instalacije___omare_in_stikalna_tehnika___instalacijski_odklopniki')],'1B2':[(V,'instalacije___omare_in_stikalna_tehnika___zbiralke_in_pribor')],
 '1C1':[(V,'instalacije___prikljucni_in_pritrdilni_material___izolirni_trakovi')],'1C2':[(V,'instalacije___prikljucni_in_pritrdilni_material___objemke')],'1C3':[(V,'instalacije___prikljucni_in_pritrdilni_material___uvodnice')],
 '1D1':[(V,'instalacije___stikala_in_vticnice___klasicni_program')],'1D2':[(V,'instalacije___stikala_in_vticnice___modularni_program')],'1D3':[(V,'instalacije___stikala_in_vticnice___zvonci')],
 '1E1':[(V,'orodje___rocno_orodje___predvleke')],'1E5':[(V,'orodje___rocno_orodje___predvleke')],'1E2':[(V,'orodje___rocno_orodje___ostalo_orodje')],'1E3':[(V,'orodje___elektricno_orodje')],'1E4':[(V,'orodje___prenosni_merilni_instrumenti')],
 '1F':[(V,'instalacije___instalacijski_kanali')],'1G':[(V,'instalacije___razvodne_doze')],'1G2':[(V,'instalacije___razvodne_doze')],
 '1H':[(V,'instalacije___elektro_omare_in_razdelilniki')],'1H2':[(V,'instalacije___elektro_omare_in_razdelilniki')],'1I':[(V,'instalacije___vtikaci_in_vticnice')],'1J':[(V,'instalacije___strelovod_in_ozemljitev')],
 '2A2':[(V,'razsvetljava___luci___zasilna_razsvetljava')],'2A3':[(L,'zunanja_svetila___prenosna_svetila')],'2A11':[(L,'cameleon_sistem'),(V,'razsvetljava___luci___cameleon_sistem')],
 '2A15':[(L,'notranja_svetila___dodatki'),(V,'razsvetljava___luci___dodatki')],
 '2B1':[(V,'razsvetljava___led_trakovi_in_profili___led_profili_in_dodatki')],'2B2':[(V,'razsvetljava___led_trakovi_in_profili___led_profili_in_dodatki')],'2B3':[(V,'razsvetljava___led_trakovi_in_profili___led_profili_in_dodatki')],'2B4':[(V,'razsvetljava___led_trakovi_in_profili___led_profili_in_dodatki')],
 '2C1':[(V,'razsvetljava___led_trakovi_in_profili___led_trakovi')],'2D':[(V,'razsvetljava___led_trakovi_in_profili___kontrolerji_in_zatemnilniki')],
 '2E':[(V,'razsvetljava___led_trakovi_in_profili___napajalniki'),(L,'svetlobni_viri_in_dodatki___napajalniki')],
 '2F1':[(V,'razsvetljava___senzorji_gibanja___senzorji')],'2F2':[(V,'razsvetljava___senzorji_gibanja___dodatki_k_senzorjem')],
 '2G1':[(L,'svetlobni_viri_in_dodatki'),(V,'razsvetljava___sijalke')],'2G2':[(L,'svetlobni_viri_in_dodatki'),(V,'razsvetljava___sijalke')],'2G3':[(L,'svetlobni_viri_in_dodatki___dodatki')],
 '2H1':[(L,'tracni_sistemi'),(V,'razsvetljava___tracni_sistemi')],
 '2H2':[(L,c) for c in ['tracni_sistemi___1_fazni_24v_nano_lvm___led_svetilke','tracni_sistemi___1_fazni_48v_lvm___led_svetilke','tracni_sistemi___1_fazni_48v_ut_lvm___led_svetilke','tracni_sistemi___1_fazni_profile___svetila','tracni_sistemi___3_fazni_ctls___svetila']],
}
BRAND_TARGETS=[(L,'notranja_svetila'),(L,'zunanja_svetila'),(V,'razsvetljava___luci')]

unmatched=collections.Counter(); matched=collections.Counter(); skipped_masters=collections.Counter()
cand=collections.defaultdict(lambda: collections.defaultdict(list))  # (tree,cat) -> code -> [(fill,master)]
brand=collections.defaultdict(list)  # code -> [(fill,master)]
def resolve(m,a):
    if a in ALIAS: return ALIAS[a]
    if m.startswith('2') and a in LIGHT_ONLY_ALIAS: return LIGHT_ONLY_ALIAS[a]
    return register.get(norm(a))
for m,a,g,fill in rows:
    code=resolve(m,a)
    if not code: unmatched[a]+=1; continue
    matched[a]+=1
    if m in BRAND: brand[code].append((fill,m)); continue
    if m not in MAP: skipped_masters[m]+=1; continue
    for t in MAP[m]: cand[t][code].append((fill,m))
for code,lst in brand.items():
    if len(lst)>=2:
        for t in BRAND_TARGETS: cand[t][code].append((round(statistics.mean(f for f,_ in lst)),'znamke:'+'+'.join(m for _,m in lst)))
out=[]
for (tree,cat),d in cand.items():
    for code,lst in d.items():
        out.append((tree,cat,code,max(f for f,_ in lst),','.join(m for _,m in lst)))
out.sort()
with open(args.out,'w',encoding='utf-8') as f:
    for r in out: f.write('\t'.join(map(str,r))+'\n')
print('parov',len(rows),'ujetih',sum(matched.values()),'neujetih',sum(unmatched.values()))
print('kandidatov (drevo,kategorija,atribut):',len(out),' kategorij:',len(cand))
print('preskoceni mastri (brez cilja):',dict(skipped_masters))
print('\nNEUJETI (pojavitev v mastrih, po padajoce):')
for a,k in unmatched.most_common(): print(f'{k:3} {a}')
if args.unmatched:
    with open(args.unmatched,'w',encoding='utf-8') as f:
        for a,k in unmatched.most_common(): f.write(f'{a}\t{k}\n')
