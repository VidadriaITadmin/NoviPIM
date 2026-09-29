/*
  285 — katalog.csv iz več podjetij: artikli IQ Lighting in Vidadria v eni datoteki, en artikel = ena vrstica.

  Uporabnik 2026-09-25: »treba je nek sistem pogruntat kako bodo sli IQ in Vid artikli v katalog brez podvajanj
  … Gledali bi kljukico svetila in videlektro … eni artikli bodo imeli samo videlektro pa bodo samo na vidadria.«
  Na vprašanje, kaj velja, ko ima IQ kartica kljukico svetila in ViD kartica videlektro: »ja potem naj ima
  artikel svetila|videlektro v spletišču pa ena vrstica«. Katera kartica odloča o spletišču: »svetila samo IQ,
  videlektro oba« — ViD kljukica svetila ne pošlje artikla na svetila.si (na razvojni bazi bi sicer 166 ViD
  artiklov šlo na svetila in 71, ki jih je IQ umaknil, bi se tja vrnilo). Stranke za zdaj ostanejo samo iz
  podjetja kataloga (»pustiva stranke za enkrat«).

  Do zdaj: katalog.csv = samo podjetje 2 (out.GetExportRows za eno podjetje). Artikel, ki ga ima samo Vidadria,
  na splet ni prišel, kljukica videlektro na ViD kartici ni pomenila ničesar.

  Pravilo (PIM.B2bWorker, CatalogMerge):
    - vsako podjetje iz registra da svoje vrstice po obstoječih pravilih (kljukica, veljavnost, odjavne vrstice
      251, cene, zaloga) — nič se ne izračuna na novo;
    - šifra artikla je ključ; ista šifra v več podjetjih je ENA vrstica;
    - »Spletne strani« = unija kljukic vseh podjetij (svetila na IQ + videlektro na ViD = svetila|videlektro),
      vsako podjetje samo za spletišča iz WebSiteLabels (NULL = vsa; ViD = videlektro);
    - vrstica podjetja brez dovoljenega spletišča ne gre v datoteko; odjavna vrstica, če je podjetje artikel
      objavilo v zadnjih WithdrawalRowDays dneh (pim.WebPublicationPolicy, kot pri 251);
    - vsebina (nazivi, opisi, cene, atributi, slike) iz podjetja z najvišjo prednostjo, ki artikel objavlja;
    - kategorija spletišča iz podjetja, ki to spletišče prispeva;
    - varovalka (277) in zapis objave (251) tečeta po podjetju, vsako za svoje vrstice. Artikel, ki ga zadrži
      podjetje vsebine, ne gre v datoteko; zadržanje drugega podjetja odvzame samo njegov prispevek.

  Objekti: nova tabela out.CatalogSource (register virov kataloga); iz out.WebPublication odstranjeno začetno
  stanje 251 za podjetja, ki niso bila nikoli v katalogu (kopija v out.WebPublication_pred285). Brez vrstic za podjetje kataloga izvoz
  dela kot doslej (samo to podjetje). Migracija vpiše 2 (prednost 10, vsa spletišča) in 3 (prednost 20,
  samo videlektro), oba vklopljena.
  Ročni korak: ne. Spletišča ViD: UPDATE out.CatalogSource SET WebSiteLabels = N'svetila|videlektro' … Izklop ViD: UPDATE out.CatalogSource SET IsActive = 0 WHERE SourceOrganizationId = 3.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52980, N'285: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;

IF OBJECT_ID(N'out.CatalogSource', N'U') IS NULL
BEGIN
  CREATE TABLE out.CatalogSource
  (
    CatalogOrganizationId int NOT NULL,
    SourceOrganizationId int NOT NULL,
    Priority int NOT NULL,
    WebSiteLabels nvarchar(400) NULL,   /* oznake kot v »Spletnih straneh«, ločene z |; NULL = vsa spletišča */
    IsActive bit NOT NULL CONSTRAINT DF_CatalogSource_IsActive DEFAULT (1),
    Note nvarchar(400) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CatalogSource_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_CatalogSource_UpdatedBy DEFAULT (SUSER_SNAME()),
    CONSTRAINT PK_CatalogSource PRIMARY KEY (CatalogOrganizationId, SourceOrganizationId),
    CONSTRAINT UQ_CatalogSource_Priority UNIQUE (CatalogOrganizationId, Priority),
    CONSTRAINT FK_CatalogSource_Catalog FOREIGN KEY (CatalogOrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId),
    CONSTRAINT FK_CatalogSource_Source FOREIGN KEY (SourceOrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );
END;

IF COL_LENGTH(N'out.CatalogSource', N'WebSiteLabels') IS NULL
  EXEC(N'ALTER TABLE out.CatalogSource ADD WebSiteLabels nvarchar(400) NULL;');

/* WebSiteLabels je v EXEC: stolpec, ki ga je dodal zgornji ALTER, se v istem paketu ne sme prevajati. */
MERGE out.CatalogSource AS target
USING (VALUES
  (2, 2, 10, N'IQ Lighting: vsebina artikla ima prednost; kljukici svetila in videlektro na IQ kartici.'),
  (2, 3, 20, N'Vidadria: samo videlektro (kljukica svetila na ViD kartici ne šteje); artikli, ki jih IQ ne objavlja.')
) AS source (CatalogOrganizationId, SourceOrganizationId, Priority, Note)
ON target.CatalogOrganizationId = source.CatalogOrganizationId AND target.SourceOrganizationId = source.SourceOrganizationId
WHEN NOT MATCHED BY TARGET AND EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = source.SourceOrganizationId)
  AND EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = source.CatalogOrganizationId) THEN
  INSERT (CatalogOrganizationId, SourceOrganizationId, Priority, Note, UpdatedBy)
  VALUES (source.CatalogOrganizationId, source.SourceOrganizationId, source.Priority, source.Note, N'285_KatalogIzVecPodjetij');

/* ViD sme prispevati samo videlektro (»svetila samo IQ, videlektro oba«). Samo vrstica, ki jo je vpisala ta
   migracija in je nihče ni spremenil; ročno nastavljena spletišča ostanejo. */
EXEC(N'UPDATE out.CatalogSource SET WebSiteLabels = N''videlektro'',
        Note = N''Vidadria: samo videlektro (kljukica svetila na ViD kartici ne šteje); artikli, ki jih IQ ne objavlja.''
      WHERE CatalogOrganizationId = 2 AND SourceOrganizationId = 3 AND WebSiteLabels IS NULL AND UpdatedBy = N''285_KatalogIzVecPodjetij'';');

/* Začetno stanje objave (251) za podjetja, ki šele zdaj pridejo v katalog. 251 je 2026-09-23 vsem podjetjem
   vpisal »objavljeno« za vse s kljukico, čeprav je šel v katalog.csv samo katalog podjetja 2. Podjetje 3 tako
   ni objavilo ničesar: brez čiščenja bi izvoz zanj pošiljal odjavne vrstice (prazne »Spletne strani«) za
   artikle, ki jih Magento od njega ni nikoli dobil (na razvojni bazi 2.850). Odstranijo se samo vpisi, ki niso
   bili nikoli izvoženi (LastExportedUtc IS NULL), podjetja kataloga pa se ne dotika. Kopija ostane v
   out.WebPublication_pred285. */
IF OBJECT_ID(N'out.WebPublication_pred285', N'U') IS NULL
  SELECT publication.*, CONVERT(datetime2(3), SYSUTCDATETIME()) AS CopiedUtc
  INTO out.WebPublication_pred285
  FROM out.WebPublication AS publication
  WHERE 1 = 0;

EXEC(N'
BEGIN TRANSACTION;
INSERT out.WebPublication_pred285
SELECT publication.*, SYSUTCDATETIME()
FROM out.WebPublication AS publication
INNER JOIN out.CatalogSource AS source
  ON source.SourceOrganizationId = publication.OrganizationId AND source.SourceOrganizationId <> source.CatalogOrganizationId
WHERE publication.LastExportedUtc IS NULL;

DELETE publication
FROM out.WebPublication AS publication
INNER JOIN out.CatalogSource AS source
  ON source.SourceOrganizationId = publication.OrganizationId AND source.SourceOrganizationId <> source.CatalogOrganizationId
WHERE publication.LastExportedUtc IS NULL;
COMMIT;');

/* --- dokaz ------------------------------------------------------------------------------- */
IF OBJECT_ID(N'out.CatalogSource', N'U') IS NULL OR COL_LENGTH(N'out.CatalogSource', N'WebSiteLabels') IS NULL
  THROW 52981, N'285: out.CatalogSource ali stolpec WebSiteLabels ni nastal.', 1;
