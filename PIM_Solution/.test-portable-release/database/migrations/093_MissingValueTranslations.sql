/*
  093 — manjkajoci prevodi vrednosti dobaviteljev, po lastnosti in ne globalno.

  Odlocitev uporabnika 2026-08-24: "prevode je treba iz te tabele prebrati, kar manjka se
  nacelom lahko uporabi AI, da vse zapolni prevajalne tabele, drugace pa bi uporabnik to mogel,
  samo mu je potrebno omogociti."

  --- Zakaj po lastnosti ------------------------------------------------------------------

  map.ValueLookup je imel 6.316 vrstic in vse z Domain = '*', torej en prevod na besedo za cel
  katalog. Prav zato je 2026-08-21 nastala datoteka docs\Prevodi_sporni.csv z 236 besedami, ki
  imajo vec slovenskih ustreznic: "White" je pri barvi "bela", pri materialu pa "bel". Globalen
  slovar tega ne more lociti in vrednost je zato ostala v anglescini.

  Postopek map.ApplyValueTransforms to zna ze od migracije 049, le da se ni bilo uporabljeno:

      AND lookup.Domain IN (N'*', scope.Domain)
      ORDER BY CASE WHEN lookup.Domain = N'*' THEN 1 ELSE 0 END

  Prevod, vezan na lastnost, ima prednost pred globalnim. Ta migracija zato ne vpise nobene
  vrstice z '*', ampak vsako veze na svojo lastnost. "Wooden" je tako pri
  "Prevladujoca barva SLO" barva (lesena), pri "Prevladujoc material SLO" pa snov (les) — ista
  angleska beseda, dva pravilna prevoda, brez spora.

  --- Kaj je vpisano ----------------------------------------------------------------------

  Vseh 213 vrstic iz map.MissingTranslation, skupaj 78,709 pojavitev v katalogu.
  Po lastnostih:

    Prevladujoč material SLO          66
    Prevladujoča barva SLO            49
    Dopolnilni material I SLO         19
    Način montaže SLO                 16
    Dopolnilna barva I SLO            12
    Slog SLO                          11
    Dopolnilni material II SLO        10
    Uporaba SLO                        8
    Dopolnilna barva II SLO            7
    Oblika odprtine SLO                3
    Način polnjenja SLO                3
    Zatemnljivo SLO                    2
    Vrsta svetlobnega vira SLO         2
    Oblika svetilke SLO                2
    Režim nujne osvetlitve SLO         2
    Dopolnilni material III SLO        1

  Prevodi so PREDLOG strojnega prevoda in ne odlocitev. Vsak je navadna vrstica registra:
  popravek je UPDATE map.ValueLookup.TargetValue, izklop je IsActive = 0, oboje brez posega v
  program. Stolpec Note pove, od kod vrstica je, da se pozneje loci od potrjenih.

  --- Delovni seznam ----------------------------------------------------------------------

  map.MissingTranslation je zapisnik in ne seznam odprtega dela: vrstice se ne brisejo, ko
  prevod nastane, zato bi po tej migraciji se vedno kazal 213 vrstic. Nastane pogled
  map.MissingTranslationOpen, ki pokaze samo tisto, kar prevoda se nima — enako kot
  map.SourceCategoryToMap pri kategorijah (091). Nicesar ne brisemo.
*/

SET XACT_ABORT ON;

MERGE map.ValueLookup AS target
USING (VALUES
  (N'Prevladujoča barva SLO',N'White',N'SL',N'bela'),
  (N'Slog SLO',N'Modern',N'SL',N'moderen'),
  (N'Prevladujoča barva SLO',N'Black',N'SL',N'črna'),
  (N'Zatemnljivo SLO',N'Not-Dimmable',N'SL',N'ne'),
  (N'Vrsta svetlobnega vira SLO',N'Replaceable',N'SL',N'zamenljiv'),
  (N'Oblika svetilke SLO',N'Non-Directional',N'SL',N'neusmerjena'),
  (N'Prevladujoč material SLO',N'Painted steel',N'SL',N'barvano jeklo'),
  (N'Način montaže SLO',N'Direct assembly',N'SL',N'neposredna montaža'),
  (N'Način montaže SLO',N'Bracket',N'SL',N'nosilec'),
  (N'Dopolnilni material I SLO',N'Painted steel',N'SL',N'barvano jeklo'),
  (N'Uporaba SLO',N'Hall',N'SL',N'hodnik'),
  (N'Dopolnilna barva I SLO',N'White',N'SL',N'bela'),
  (N'Prevladujoč material SLO',N'Metal',N'SL',N'kovina'),
  (N'Oblika svetilke SLO',N'Directional',N'SL',N'usmerjena'),
  (N'Prevladujoč material SLO',N'Plastic',N'SL',N'plastika'),
  (N'Dopolnilna barva I SLO',N'Black',N'SL',N'črna'),
  (N'Dopolnilni material I SLO',N'Plastic',N'SL',N'plastika'),
  (N'Način montaže SLO',N'Recessed assembly',N'SL',N'vgradna montaža'),
  (N'Dopolnilni material I SLO',N'Glass',N'SL',N'steklo'),
  (N'Uporaba SLO',N'Dinning room',N'SL',N'jedilnica'),
  (N'Prevladujoč material SLO',N'Aluminium-PC',N'SL',N'aluminij-PC'),
  (N'Prevladujoč material SLO',N'Glass',N'SL',N'steklo'),
  (N'Prevladujoč material SLO',N'Fabric',N'SL',N'blago'),
  (N'Oblika odprtine SLO',N'Round',N'SL',N'okrogla'),
  (N'Prevladujoča barva SLO',N'Grey',N'SL',N'siva'),
  (N'Prevladujoča barva SLO',N'Beige',N'SL',N'bež'),
  (N'Način montaže SLO',N'Works with Profile System',N'SL',N'združljivo s sistemom Profile'),
  (N'Način montaže SLO',N'Works with CTLS - Commercial Track Light System',N'SL',N'združljivo s sistemom CTLS'),
  (N'Slog SLO',N'Industrial',N'SL',N'industrijski'),
  (N'Uporaba SLO',N'Garden',N'SL',N'vrt'),
  (N'Uporaba SLO',N'Elevation/Terrace',N'SL',N'fasada / terasa'),
  (N'Prevladujoč material SLO',N'PC+PC',N'SL',N'PC-PC'),
  (N'Prevladujoč material SLO',N'Aluminum',N'SL',N'aluminij'),
  (N'Prevladujoč material SLO',N'PA+PC',N'SL',N'PA-PC'),
  (N'Uporaba SLO',N'Bathroom',N'SL',N'kopalnica'),
  (N'Način montaže SLO',N'Free-standing product',N'SL',N'prostostoječ izdelek'),
  (N'Prevladujoča barva SLO',N'Black-Black',N'SL',N'črna - črna'),
  (N'Prevladujoča barva SLO',N'Silver',N'SL',N'srebrna'),
  (N'Prevladujoč material SLO',N'FPCB',N'SL',N'FPCB'),
  (N'Prevladujoča barva SLO',N'Graphite',N'SL',N'grafitna'),
  (N'Dopolnilna barva I SLO',N'Gold',N'SL',N'zlata'),
  (N'Slog SLO',N'Modern classic',N'SL',N'moderno klasičen'),
  (N'Prevladujoča barva SLO',N'Transparent',N'SL',N'prozorna'),
  (N'Način montaže SLO',N'Works with LVM system',N'SL',N'združljivo s sistemom LVM'),
  (N'Prevladujoča barva SLO',N'Gray',N'SL',N'siva'),
  (N'Dopolnilni material II SLO',N'Painted steel',N'SL',N'barvano jeklo'),
  (N'Uporaba SLO',N'Office',N'SL',N'pisarna'),
  (N'Prevladujoča barva SLO',N'Dark Grey',N'SL',N'temno siva'),
  (N'Prevladujoč material SLO',N'Aluminium+PC',N'SL',N'aluminij-PC'),
  (N'Prevladujoča barva SLO',N'Golden',N'SL',N'zlata'),
  (N'Dopolnilni material I SLO',N'Chrome plated steel',N'SL',N'kromirano jeklo'),
  (N'Prevladujoč material SLO',N'Metal-Glass',N'SL',N'kovina-steklo'),
  (N'Prevladujoč material SLO',N'Plywood',N'SL',N'vezana plošča'),
  (N'Oblika odprtine SLO',N'Rectangular',N'SL',N'pravokotna'),
  (N'Dopolnilna barva I SLO',N'Transparent',N'SL',N'prozorna'),
  (N'Prevladujoč material SLO',N'PBT-PC',N'SL',N'PBT-PC'),
  (N'Dopolnilni material II SLO',N'Plastic',N'SL',N'plastika'),
  (N'Prevladujoča barva SLO',N'Silk gray',N'SL',N'svileno siva'),
  (N'Slog SLO',N'Japandi',N'SL',N'japandi'),
  (N'Dopolnilna barva II SLO',N'White',N'SL',N'bela'),
  (N'Dopolnilni material I SLO',N'Steel',N'SL',N'jeklo'),
  (N'Prevladujoč material SLO',N'ABS+PC',N'SL',N'ABS-PC'),
  (N'Prevladujoč material SLO',N'Zinc aluminum alloy',N'SL',N'cinkovo-aluminijeva zlitina'),
  (N'Prevladujoča barva SLO',N'Cream',N'SL',N'kremna'),
  (N'Način montaže SLO',N'Do systemu LVM Ultra Thin',N'SL',N'združljivo s sistemom LVM Ultra Thin'),
  (N'Slog SLO',N'Scandinavian',N'SL',N'skandinavski'),
  (N'Prevladujoč material SLO',N'PC+PS',N'SL',N'PC-PS'),
  (N'Slog SLO',N'Classic',N'SL',N'klasičen'),
  (N'Način montaže SLO',N'Works with NANO-LVM system',N'SL',N'združljivo s sistemom NANO-LVM'),
  (N'Prevladujoča barva SLO',N'Gold',N'SL',N'zlata'),
  (N'Slog SLO',N'Glamour',N'SL',N'glamurozen'),
  (N'Prevladujoč material SLO',N'Ceramic housing',N'SL',N'keramično ohišje'),
  (N'Prevladujoč material SLO',N'PP+Copper',N'SL',N'PP-baker'),
  (N'Prevladujoč material SLO',N'PP+PP',N'SL',N'PP-PP'),
  (N'Način montaže SLO',N'Direct assembly + line',N'SL',N'neposredna montaža z vrvico'),
  (N'Prevladujoč material SLO',N'FPCB-PVC',N'SL',N'FPCB-PVC'),
  (N'Prevladujoča barva SLO',N'Wooden',N'SL',N'lesena'),
  (N'Prevladujoča barva SLO',N'Green',N'SL',N'zelena'),
  (N'Dopolnilni material I SLO',N'Brass-plated steel',N'SL',N'jeklo z medeninasto prevleko'),
  (N'Način montaže SLO',N'Free-standing/Pin for ground/Sheet metal for hard base',N'SL',N'prostostoječe / zatič za zemljo / plošča za trdo podlago'),
  (N'Prevladujoč material SLO',N'Metallized glass',N'SL',N'metalizirano steklo'),
  (N'Prevladujoč material SLO',N'Metal-PC',N'SL',N'kovina-PC'),
  (N'Prevladujoč material SLO',N'Aluminium-Glass',N'SL',N'aluminij-steklo'),
  (N'Dopolnilna barva I SLO',N'Beige',N'SL',N'bež'),
  (N'Dopolnilna barva II SLO',N'Black',N'SL',N'črna'),
  (N'Prevladujoč material SLO',N'PC+Copper',N'SL',N'PC-baker'),
  (N'Prevladujoč material SLO',N'Plastic PE',N'SL',N'plastika PE'),
  (N'Prevladujoča barva SLO',N'Black-Golden',N'SL',N'črna - zlata'),
  (N'Prevladujoča barva SLO',N'White-White',N'SL',N'bela - bela'),
  (N'Dopolnilni material I SLO',N'Braided cable',N'SL',N'pleten kabel'),
  (N'Način montaže SLO',N'Bracket + lines',N'SL',N'nosilec z vrvicami'),
  (N'Prevladujoč material SLO',N'Brass-plated steel',N'SL',N'jeklo z medeninasto prevleko'),
  (N'Prevladujoč material SLO',N'Metal+PS',N'SL',N'kovina-PS'),
  (N'Prevladujoča barva SLO',N'Brushed gold',N'SL',N'brušeno zlata'),
  (N'Prevladujoča barva SLO',N'Smoked',N'SL',N'dimna'),
  (N'Slog SLO',N'Art Deco',N'SL',N'art deco'),
  (N'Slog SLO',N'Mid - century modern',N'SL',N'sredina 20. stoletja'),
  (N'Vrsta svetlobnega vira SLO',N'Replaceable and integrated',N'SL',N'zamenljiv in vgrajen'),
  (N'Dopolnilna barva I SLO',N'Brushed gold',N'SL',N'brušeno zlata'),
  (N'Prevladujoč material SLO',N'ABS+PS',N'SL',N'ABS-PS'),
  (N'Prevladujoč material SLO',N'Crystal',N'SL',N'kristal'),
  (N'Prevladujoč material SLO',N'MDF',N'SL',N'MDF'),
  (N'Prevladujoč material SLO',N'Steel',N'SL',N'jeklo'),
  (N'Dopolnilna barva I SLO',N'Silk gray',N'SL',N'svileno siva'),
  (N'Oblika odprtine SLO',N'Square',N'SL',N'kvadratna'),
  (N'Dopolnilna barva II SLO',N'Transparent',N'SL',N'prozorna'),
  (N'Dopolnilni material I SLO',N'Plastic PA',N'SL',N'plastika PA'),
  (N'Način montaže SLO',N'Direct or rope assembly',N'SL',N'neposredna ali vrvična montaža'),
  (N'Prevladujoč material SLO',N'ABS-PC',N'SL',N'ABS-PC'),
  (N'Prevladujoč material SLO',N'FPCB+PVC',N'SL',N'FPCB-PVC'),
  (N'Prevladujoč material SLO',N'Metal-PVC',N'SL',N'kovina-PVC'),
  (N'Zatemnljivo SLO',N'Step Dim',N'SL',N'stopenjsko'),
  (N'Način montaže SLO',N'lamp hanger',N'SL',N'obešalo za svetilko'),
  (N'Dopolnilna barva I SLO',N'Silver',N'SL',N'srebrna'),
  (N'Prevladujoč material SLO',N'Chrome plated steel',N'SL',N'kromirano jeklo'),
  (N'Prevladujoč material SLO',N'Metal+PP',N'SL',N'kovina-PP'),
  (N'Prevladujoča barva SLO',N'Black+Wooden',N'SL',N'črna - lesena'),
  (N'Prevladujoča barva SLO',N'Opal+Black',N'SL',N'opalna - črna'),
  (N'Dopolnilni material II SLO',N'Steel',N'SL',N'jeklo'),
  (N'Prevladujoč material SLO',N'ABS-Copper',N'SL',N'ABS-baker'),
  (N'Prevladujoč material SLO',N'Metal+Wooden',N'SL',N'kovina-les'),
  (N'Prevladujoč material SLO',N'TPE-Copper',N'SL',N'TPE-baker'),
  (N'Dopolnilna barva I SLO',N'Smoked',N'SL',N'dimna'),
  (N'Dopolnilni material I SLO',N'Fabric',N'SL',N'blago'),
  (N'Prevladujoč material SLO',N'Metal-ABS',N'SL',N'kovina-ABS'),
  (N'Prevladujoč material SLO',N'Metal-PMMA',N'SL',N'kovina-PMMA'),
  (N'Dopolnilni material I SLO',N'Ceramic housing',N'SL',N'keramično ohišje'),
  (N'Dopolnilni material I SLO',N'Flexible stem',N'SL',N'gibljivo steblo'),
  (N'Dopolnilni material II SLO',N'Braided cable',N'SL',N'pleten kabel'),
  (N'Prevladujoč material SLO',N'Braided cable',N'SL',N'pleten kabel'),
  (N'Prevladujoč material SLO',N'Metal+PC',N'SL',N'kovina-PC'),
  (N'Prevladujoča barva SLO',N'Brown',N'SL',N'rjava'),
  (N'Prevladujoča barva SLO',N'Navy blue-gold',N'SL',N'mornarsko modra - zlata'),
  (N'Dopolnilna barva I SLO',N'Brown',N'SL',N'rjava'),
  (N'Dopolnilna barva I SLO',N'Umbra gary',N'SL',N'umbra siva'),
  (N'Dopolnilni material I SLO',N'Copper-clad steel',N'SL',N'jeklo z bakreno prevleko'),
  (N'Dopolnilni material I SLO',N'Plywood',N'SL',N'vezana plošča'),
  (N'Dopolnilni material II SLO',N'Flexible stem',N'SL',N'gibljivo steblo'),
  (N'Način polnjenja SLO',N'USB Type C',N'SL',N'USB Type-C'),
  (N'Prevladujoča barva SLO',N'Blue',N'SL',N'modra'),
  (N'Prevladujoča barva SLO',N'Red',N'SL',N'rdeča'),
  (N'Prevladujoča barva SLO',N'Black with a golden patina',N'SL',N'črna z zlato patino'),
  (N'Način montaže SLO',N'Pin for ground',N'SL',N'zatič za zemljo'),
  (N'Dopolnilni material II SLO',N'Plastic PA',N'SL',N'plastika PA'),
  (N'Prevladujoč material SLO',N'Aluminium+PS',N'SL',N'aluminij-PS'),
  (N'Prevladujoč material SLO',N'Aluminium-PMMA',N'SL',N'aluminij-PMMA'),
  (N'Prevladujoč material SLO',N'PP-PMMA',N'SL',N'PP-PMMA'),
  (N'Prevladujoča barva SLO',N'Antique brass',N'SL',N'starinska medenina'),
  (N'Prevladujoča barva SLO',N'Black with a copper patina',N'SL',N'črna z bakreno patino'),
  (N'Prevladujoča barva SLO',N'Golden-Black',N'SL',N'zlata - črna'),
  (N'Prevladujoča barva SLO',N'Pink',N'SL',N'roza'),
  (N'Prevladujoča barva SLO',N'White-Golden',N'SL',N'bela - zlata'),
  (N'Prevladujoča barva SLO',N'Yellow',N'SL',N'rumena'),
  (N'Slog SLO',N'New York',N'SL',N'new york'),
  (N'Prevladujoča barva SLO',N'Multicolour',N'SL',N'večbarvna'),
  (N'Uporaba SLO',N'Children room',N'SL',N'otroška soba'),
  (N'Dopolnilni material I SLO',N'Stainless steel',N'SL',N'nerjavno jeklo'),
  (N'Prevladujoč material SLO',N'304 SS',N'SL',N'nerjavno jeklo 304'),
  (N'Prevladujoč material SLO',N'ABS-PS',N'SL',N'ABS-PS'),
  (N'Prevladujoč material SLO',N'FPCB-PU',N'SL',N'FPCB-PU'),
  (N'Prevladujoč material SLO',N'Metal+Rattan',N'SL',N'kovina-ratan'),
  (N'Prevladujoč material SLO',N'PC+PP',N'SL',N'PC-PP'),
  (N'Prevladujoč material SLO',N'Silicone',N'SL',N'silikon'),
  (N'Prevladujoč material SLO',N'Wooden',N'SL',N'les'),
  (N'Prevladujoča barva SLO',N'Chocolate',N'SL',N'čokoladna'),
  (N'Prevladujoča barva SLO',N'Cooper',N'SL',N'bakrena'),
  (N'Prevladujoča barva SLO',N'Milky White',N'SL',N'mlečno bela'),
  (N'Prevladujoča barva SLO',N'Wooden-Black',N'SL',N'lesena - črna'),
  (N'Dopolnilna barva II SLO',N'Graphite',N'SL',N'grafitna'),
  (N'Dopolnilni material I SLO',N'Zinc aluminum alloy',N'SL',N'cinkovo-aluminijeva zlitina'),
  (N'Dopolnilni material II SLO',N'Chrome plated steel',N'SL',N'kromirano jeklo'),
  (N'Dopolnilni material III SLO',N'Flexible stem',N'SL',N'gibljivo steblo'),
  (N'Način montaže SLO',N'Bracket + cable with plug',N'SL',N'nosilec s kablom in vtičem'),
  (N'Prevladujoč material SLO',N'Aluminium-304SS',N'SL',N'aluminij - nerjavno jeklo 304'),
  (N'Prevladujoč material SLO',N'Aluminium-PVC',N'SL',N'aluminij-PVC'),
  (N'Prevladujoč material SLO',N'Chrome plated aluminum',N'SL',N'kromiran aluminij'),
  (N'Prevladujoč material SLO',N'NON F.PP',N'SL',N'PP (negorljiv)'),
  (N'Prevladujoč material SLO',N'PA+PP',N'SL',N'PA-PP'),
  (N'Prevladujoč material SLO',N'Paper rope',N'SL',N'papirnata vrv'),
  (N'Prevladujoč material SLO',N'Plastic PA',N'SL',N'plastika PA'),
  (N'Prevladujoč material SLO',N'PP-Copper',N'SL',N'PP-baker'),
  (N'Prevladujoča barva SLO',N'Black+Opal',N'SL',N'črna - opalna'),
  (N'Prevladujoča barva SLO',N'Black-Silver',N'SL',N'črna - srebrna'),
  (N'Prevladujoča barva SLO',N'Brushed Silver',N'SL',N'brušeno srebrna'),
  (N'Prevladujoča barva SLO',N'Burgundy',N'SL',N'bordo'),
  (N'Prevladujoča barva SLO',N'Milky+Glass',N'SL',N'mlečna - steklo'),
  (N'Prevladujoča barva SLO',N'Yellow-Green',N'SL',N'rumeno zelena'),
  (N'Režim nujne osvetlitve SLO',N'AC-DC Mode',N'SL',N'način AC-DC'),
  (N'Režim nujne osvetlitve SLO',N'Dual Mode',N'SL',N'dvojni način'),
  (N'Uporaba SLO',N'Stairs',N'SL',N'stopnišče'),
  (N'Dopolnilni material I SLO',N'Plastic PC/ABS',N'SL',N'plastika PC/ABS'),
  (N'Dopolnilna barva I SLO',N'Red',N'SL',N'rdeča'),
  (N'Dopolnilna barva II SLO',N'Brushed gold',N'SL',N'brušeno zlata'),
  (N'Dopolnilna barva II SLO',N'Gold',N'SL',N'zlata'),
  (N'Dopolnilna barva II SLO',N'Yellow',N'SL',N'rumena'),
  (N'Dopolnilni material I SLO',N'Plastic LLDPE',N'SL',N'plastika LLDPE'),
  (N'Dopolnilni material I SLO',N'Plastic PP',N'SL',N'plastika PP'),
  (N'Dopolnilni material I SLO',N'Plastic PS',N'SL',N'plastika PS'),
  (N'Dopolnilni material II SLO',N'Copper-clad steel',N'SL',N'jeklo z bakreno prevleko'),
  (N'Dopolnilni material II SLO',N'Plastic PP',N'SL',N'plastika PP'),
  (N'Dopolnilni material II SLO',N'Szkło',N'SL',N'steklo'),
  (N'Način polnjenja SLO',N'AC/DC',N'SL',N'AC/DC'),
  (N'Način polnjenja SLO',N'USB-C',N'SL',N'USB Type-C'),
  (N'Prevladujoč material SLO',N'ABS-PP',N'SL',N'ABS-PP'),
  (N'Prevladujoč material SLO',N'Metal+Fabric',N'SL',N'kovina-blago'),
  (N'Prevladujoč material SLO',N'PC-Glass',N'SL',N'PC-steklo'),
  (N'Prevladujoč material SLO',N'Stainless steel',N'SL',N'nerjavno jeklo'),
  (N'Prevladujoča barva SLO',N'Amber',N'SL',N'jantarna'),
  (N'Prevladujoča barva SLO',N'Amber+Golden',N'SL',N'jantarna - zlata'),
  (N'Prevladujoča barva SLO',N'Black+Yellow',N'SL',N'črna - rumena'),
  (N'Prevladujoča barva SLO',N'Black-White',N'SL',N'črna - bela'),
  (N'Prevladujoča barva SLO',N'White-Chrome',N'SL',N'bela - krom'),
  (N'Slog SLO',N'Boho',N'SL',N'boho')
) AS source(Domain,SourceValue,Language,TargetValue)
  ON target.Domain = source.Domain AND target.SourceValue = source.SourceValue
    AND target.Language = source.Language
/* SourceKey je racunan stolpec (lower(ltrim(rtrim(SourceValue)))), zato ga ne vpisujemo —
   normalizacijo, ki jo isce map.ApplyValueTransforms, naredi baza sama. */
WHEN MATCHED THEN UPDATE SET
  TargetValue = source.TargetValue,
  IsActive = 1
WHEN NOT MATCHED THEN INSERT (Domain, SourceValue, Language, TargetValue, Note, IsActive)
  VALUES (source.Domain, source.SourceValue, source.Language, source.TargetValue,
          N'093 strojni prevod, uporabnik potrdi', 1);

EXEC(N'
/* Kaj od prevodov se dejansko caka. map.MissingTranslation ostaja zapisnik vsega, kar je
   kdaj manjkalo; ta pogled odsteje tisto, kar je medtem dobilo prevod. */
CREATE OR ALTER VIEW map.MissingTranslationOpen
AS
SELECT
  manjka.Domain,
  manjka.Language,
  manjka.SourceValue,
  manjka.SeenCount,
  manjka.FirstSeenUtc,
  manjka.LastSeenUtc
FROM map.MissingTranslation manjka
WHERE NOT EXISTS
(
  SELECT 1 FROM map.ValueLookup slovar
  WHERE slovar.IsActive = 1
    AND slovar.Language = manjka.Language
    AND slovar.SourceKey = LOWER(LTRIM(RTRIM(manjka.SourceValue)))
    AND slovar.Domain IN (N''*'', manjka.Domain)
);
');
