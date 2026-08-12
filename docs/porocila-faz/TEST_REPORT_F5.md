# TEST_REPORT_F5

Datum: 2026-07-31

## TDD

- RED sanacija neodvisnega pregleda: F5 contract je izpisal manjkajočo
  `017_HardenGenericXmlMappingPipeline.sql` in vseh osem manjkajočih varovalk.
- RED realna integracija: required `NULL` inbox je bil napačno `Processed` namesto
  `Quarantined`.
- GREEN sanacija: `F5 review integration: required NULL, unmatched, invalid
  price/VAT/date, atomicity, dedupe in config-only source PASS.`
- RED extractor: `CS0246`, ker `PIM.XmlMapping` še ni obstajal.
- GREEN extractor: `F5 behavior: generična XPath ekstrakcija in config-only prihodnji vir PASS.`
- RED SQL pogodba: manjkali so 016, `map.ExtractedValue`, `map.UnmappedValue`, generični apply in generični file worker.
- GREEN SQL pogodba: `F5 contract: generična staging/apply pot PASS.`
- RED SAOP priklop: `SAOP worker ni priklopljen na generični extract/apply.`
- GREEN SAOP priklop: contract test PASS.
- RED F3 regresija po odstranitvi SQL XPath ekstrakcije: testni `raw.Inbox` je ostal `Pending`.
- GREEN F3 regresija po priklopu istega C# extractorja: vsi trije F3 integracijski dokazi PASS.

## Migracije na razvojni MSSQL

Predhodna F5 izvedba 016:

- prvi tek: 001–014 preskočene, `016_CreateGenericXmlMappingPipeline.sql`
  uporabljena;
- drugi tek: 001–014 in 016 preskočene;
- oba teka: `Migracije so uspešno uporabljene.`

Sanacija 017:

- prvi tek: `Uporabljena migracija: 017_HardenGenericXmlMappingPipeline.sql`;
- drugi tek: `Preskočena že uporabljena migracija:
  017_HardenGenericXmlMappingPipeline.sql`;
- oba teka: `Migracije so uspešno uporabljene.`

Za sanacijo je bil uporabljen izoliran migracijski imenik, zato obstoječe
011–016 niso bile ponovno izvedene.

017 je izrecno forward-only in je odvisna od že uporabljenih 011–015 ter 016.
To ni dokaz ali trditev o samozadostnem svežem bootstrapu. Migracije 011–015
niso bile spremenjene, izbrisane ali prepisane.

## Končni preverjeni izhodi

- F5 contract: generična staging/apply pot PASS.
- F5 behavior: generična XPath ekstrakcija in config-only prihodnji vir PASS.
- F5 review integration: required `NULL`, neujemajoč ItemID/EAN, neveljavna
  Price Net/VAT/date, atomska zavrnitev brez delne uporabe in deduplikacija
  podvojenih ciljnih preslikav v config-only prihodnjem viru PASS.
- F5 integration: EAN enrichment category/media/attribute, B2C validation, pim in CSV PASS.
- Integracija je preverila tudi nespremenjen `raw.Inbox.PayloadXml`, sled `InboxId`/`FieldMappingId`/`MappingVersion`/`RecordOrdinal`, generično `UnmappedValue` vrsto in odsotnost `.nodes(` ter `sp_executesql` v SQL apply.
- F3 statični kontrakt je izpolnjen.
- F3 vedenjski testi: izdelki=25, cene=70, opisi=1.
- F3 integracija: CSV vrstic=18; XML deklaracija in ERP upravičenost preverjeni; karantenski requeue preverjen.
- `dotnet build PIM.sln`: uspeh, 0 opozoril, 0 napak.
- `npm test`: 1 datoteka in 1 test uspešna.
- `npm run lint`: uspeh; obstoječi skript izpiše `(lint se doda kasneje)`.

`PIM_test` ni bil spremenjen; dokazna integracija je tekla samo proti razvojni povezavi `Pim`.
