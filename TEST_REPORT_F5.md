# TEST_REPORT_F5

Datum: 2026-07-31

## TDD

- RED extractor: `CS0246`, ker `PIM.XmlMapping` še ni obstajal.
- GREEN extractor: `F5 behavior: generična XPath ekstrakcija in config-only prihodnji vir PASS.`
- RED SQL pogodba: manjkali so 016, `map.ExtractedValue`, `map.UnmappedValue`, generični apply in generični file worker.
- GREEN SQL pogodba: `F5 contract: generična staging/apply pot PASS.`
- RED SAOP priklop: `SAOP worker ni priklopljen na generični extract/apply.`
- GREEN SAOP priklop: contract test PASS.
- RED F3 regresija po odstranitvi SQL XPath ekstrakcije: testni `raw.Inbox` je ostal `Pending`.
- GREEN F3 regresija po priklopu istega C# extractorja: vsi trije F3 integracijski dokazi PASS.

## Migracije na razvojni MSSQL

Prvi tek:

- 001–014 preskočene kot že uporabljene.
- `016_CreateGenericXmlMappingPipeline.sql` uporabljena.
- `Migracije so uspešno uporabljene.`

Drugi tek:

- 001–014 in 016 preskočene kot že uporabljene.
- `Migracije so uspešno uporabljene.`

Migracije 011–015 niso bile spremenjene.

## Končni preverjeni izhodi

- F5 contract: generična staging/apply pot PASS.
- F5 behavior: generična XPath ekstrakcija in config-only prihodnji vir PASS.
- F5 integration: EAN enrichment category/media/attribute, B2C validation, pim in CSV PASS.
- Integracija je preverila tudi nespremenjen `raw.Inbox.PayloadXml`, sled `InboxId`/`FieldMappingId`/`MappingVersion`/`RecordOrdinal`, generično `UnmappedValue` vrsto in odsotnost `.nodes(` ter `sp_executesql` v SQL apply.
- F3 statični kontrakt je izpolnjen.
- F3 vedenjski testi: izdelki=25, cene=70, opisi=1.
- F3 integracija: CSV vrstic=18; XML deklaracija in ERP upravičenost preverjeni; karantenski requeue preverjen.
- `dotnet build PIM.sln`: uspeh, 0 opozoril, 0 napak.
- `npm test`: 1 datoteka in 1 test uspešna.
- `npm run lint`: uspeh; obstoječi skript izpiše `(lint se doda kasneje)`.

`PIM_test` ni bil spremenjen; dokazna integracija je tekla samo proti razvojni povezavi `Pim`.
