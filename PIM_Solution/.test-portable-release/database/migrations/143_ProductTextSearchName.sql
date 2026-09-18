/*
  143 — canon.ProductText sme nositi ime za iskanje.

  Zakaj: migracija 137 je dodala vhodno preslikavo
  GeneralData/ItemSearchName -> ProductText.SEARCH_NAME.sl in odhodno pogodbo, ni pa
  razsirila omejitve CK_CanonProductText_Type. Ta je od migracije 080 dovoljevala
  natanko WEB_TITLE, TITLE_ERP, TITLE_ERP2 in druzino DESCRIPTION%.

  Posledica je bila tiha in popolna: preslikava se je izvedla, MERGE v canon.ProductText
  pa je padel na omejitvi, cela stran zajema je sla v karanteno in ime za iskanje ni
  nikoli prislo v katalog. Merjeno 2026-09-02 nad razvojno bazo PIM:

    canon.ProductText WHERE TextType = 'SEARCH_NAME'  ->  0 vrstic
    raw.Inbox, stran 2481 (Ediito, ItemGeneralData)   ->  Quarantined,
      FailureReason: 'The MERGE statement conflicted with the CHECK constraint
      "CK_CanonProductText_Type" ... column TextType.'

  Preverbe migracije 137 tega niso mogle ujeti, ker so preverjale register (map.FieldMapping,
  out.SaopXmlField, out.OwnershipPolicy) in rezultat procedure GetWritableSaopFields —
  torej pravico do pisanja, ne pa, ali kanonicni model vrednost sploh sprejme.

  Zakaj nastevanje ostane. Migracija 080 je nazive nastela namenoma: so pogodba z izvozom
  in nova vrsta naziva mora biti odlocitev, ne stranski ucinek zajema. Opisi so ostali
  druzina (DESCRIPTION%), ker njihovo vrsto doloci vir. SEARCH_NAME je naziv, zato je
  dodan poimensko in ne kot nova druzina.

  Migracija ne dela preslikave. Karantenirane strani vrne v obtok worker:
    dotnet run --project PIM_Solution\workers\PIM.KatalogWorker -- --znova-preslikaj <RunId>
*/

SET XACT_ABORT ON;

/* --- 1) Omejitev pozna se ime za iskanje ------------------------------------------------ */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_CanonProductText_Type')
  ALTER TABLE canon.ProductText DROP CONSTRAINT CK_CanonProductText_Type;

/* WITH CHECK: ce bi v tabeli ze bila vrsta, ki je ta seznam ne pozna, mora migracija pasti
   tu in ne sele takrat, ko bo zajem naletel nanjo. */
ALTER TABLE canon.ProductText WITH CHECK
  ADD CONSTRAINT CK_CanonProductText_Type
  CHECK (TextType IN (N'WEB_TITLE', N'TITLE_ERP', N'TITLE_ERP2', N'SEARCH_NAME')
         OR TextType LIKE N'DESCRIPTION%');

/* --- 2) Varovalke ----------------------------------------------------------------------- */

IF NOT EXISTS
(
  SELECT 1 FROM sys.check_constraints
  WHERE name = N'CK_CanonProductText_Type'
    AND definition LIKE N'%SEARCH\_NAME%' ESCAPE N'\'
)
  THROW 52970, 'Omejitev vrst besedila ne pozna imena za iskanje.', 1;

/* Nepreverjena omejitev bi pomenila, da obstojece vrstice niso bile preverjene; taka
   omejitev optimizatorju ne pomeni nicesar in ne dokazuje, da je model skladen. */
IF EXISTS
(
  SELECT 1 FROM sys.check_constraints
  WHERE name = N'CK_CanonProductText_Type' AND (is_disabled = 1 OR is_not_trusted = 1)
)
  THROW 52971, 'Omejitev vrst besedila ni preverjena nad obstojecimi vrsticami.', 1;

/*
  Pravi dokaz ni besedilo omejitve, ampak da kanonicni model vrednost res sprejme.
  Vstavimo in takoj pobrisemo eno vrstico za izmisljen izdelek, ki ga migracija ustvari
  sama; brisanje je omejeno na natanko to vrstico (AGENTS.md §4.1, izjema za lastne
  testne podatke). Ce bi omejitev se vedno zavracala SEARCH_NAME, migracija tu pade.
*/
DECLARE @ProbeProductId bigint =
  (SELECT TOP (1) ProductId FROM canon.Product ORDER BY ProductId);

IF @ProbeProductId IS NULL
  THROW 52972, 'V katalogu ni nobenega izdelka; zapisa imena za iskanje ni mogoce dokazati.', 1;

IF EXISTS (SELECT 1 FROM canon.ProductText
           WHERE ProductId = @ProbeProductId AND TextType = N'SEARCH_NAME' AND Lang = N'zz')
  THROW 52973, 'Preizkusna vrstica iz prejsnjega zagona ni bila pospravljena.', 1;

INSERT canon.ProductText (ProductId, Lang, TextType, Value)
VALUES (@ProbeProductId, N'zz', N'SEARCH_NAME', N'migracija 143 — preizkus');

IF NOT EXISTS (SELECT 1 FROM canon.ProductText
               WHERE ProductId = @ProbeProductId AND TextType = N'SEARCH_NAME' AND Lang = N'zz')
  THROW 52974, 'Ime za iskanje se vedno ni mogoce zapisati.', 1;

DELETE FROM canon.ProductText
WHERE ProductId = @ProbeProductId AND TextType = N'SEARCH_NAME' AND Lang = N'zz';
