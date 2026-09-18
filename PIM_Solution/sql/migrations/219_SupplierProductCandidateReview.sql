/*
  219 -- kandidati za nove artikle od dobaviteljev (NW/BT XML), ki jih PIM se ne pozna.

  Dobaviteljski XML viri (NW_XML = Nowodvorski, BT_XML = Braytron in splosno vsak konektor z
  map.SourceConnector.CanCreateProducts = 0) samo obogatijo obstojece canon.Product vrstice
  (ujemanje po ItemID, nato po EAN). Nove vrstice v canon.Product ustvarjajo izkljucno SAOP
  konektorji (CanCreateProducts = 1).

  Ko se dobaviteljev zapis ne ujame z nobenim obstojecim artiklom, map.ProcessRawInbox (zadnja
  sprememba v migraciji 211, brez spremembe od 197) zapis samo zavrne v zacasni tabeli #Record
  in ga presteje v raw.Inbox.FailureReason ("Delno obogateno: X uspeli, Y preskocenih. Novih
  artiklov: 0. ..."). Katera konkretna sifra/EAN je bila zavrnjena, se nikjer ne shrani -- samo
  stevilo. Analiza NW artiklov (2026-09-15) je pokazala, da je to realen problem: pri podjetju 4
  (Ediito) je vseh 2619 NW artiklov zavrnjenih, pri podjetju 1 (DEMO) 1474 od 2619 -- brez
  nacina, da bi uporabnik videl, kateri konkretni artikli manjkajo, in se odlocil, ali naj gredo
  v PIM.

  Hkrati so vse vrednosti, ki jih je dobavitelj za tak zapis poslal (atributi, slike, dokumenti),
  ze trajno v map.ExtractedValue (po InboxId+RecordOrdinal) -- samo obesene brez ProductId, na
  katerega bi se prilepile. map.ExtractedValue se ob obdelavi nikoli ne brise (samo
  raw.Inbox.PayloadXml se po migraciji 197/211 koraku 15 postavi na NULL), zato je kazalec
  (InboxId+RecordOrdinal) zanesljiv poljubno dolgo.

  Kaj ta migracija doda:

    1. map.SupplierProductCandidate -- nova tabela. Kazalec na InboxId+RecordOrdinal, NE kopija
       vrednosti -- obogatitvena logika ostane ena sama (v map.ProcessRawInbox), ta migracija je
       ne podvaja. Najvec en ODPRT (IsActive=1) kandidat na (podjetje, sifro) hkrati.
    2. map.ProcessRawInbox -- poln CREATE OR ALTER prepis (telo iz migracije 211/197, nespremenjeno
       razen dveh novih blokov):
       - 3b, takoj po ujemanju po ItemID/EAN: ce se je artikel medtem ujel (nastal po drugi poti,
         npr. vzporedni SAOP tek), se morebiten odprt kandidat za to sifro samodejno zapre kot
         odobren;
       - 5b, takoj po "Izdelek za konfigurirani identifikator ne obstaja.": za vire brez
         CanCreateProducts se doda/osvezi vrstica v map.SupplierProductCandidate. Ne odpira znova
         ze zavrnjenega kandidata, razen ce se EAN pri isti sifri spremeni.
    3. map.ApproveSupplierProductCandidate -- ustvari canon.Product (isti stolpci kot obstojeca
       SAOP pot: OrganizationId, ItemID, EAN, BusinessHash, plus ErpExistence='NOT_YET_IN_ERP' po
       migraciji 169). NE klice obogatitve -- ta pride sama z naslednjim tekom vira.
    4. map.RejectSupplierProductCandidate -- zapre kandidata z razlogom in avtorjem.
    5. intranet.GetSupplierProductCandidates -- bralna procedura za UI (podjetje/vir/stanje/iskanje,
       stran + skupno stevilo, po vzoru intranet.GetQualityProducts iz migracije 194).

  Kaj ta migracija NAMENOMA NE spremeni: intranet.GetProductWorkbook in njegov uvozni del
  (migraciji 171, 173) -- manjkajoca obvezna polja po odobritvi uporabnik dopolni prek ze
  obstojecega Excel kroga, brez sprememb. val.RunValidation/val.Promote se ne spreminjata. Noben
  out.* SAOP izvozni postopek se ne spreminja -- artikel z ErpExistence='NOT_YET_IN_ERP' preprosto
  ni izbran za izvoz, dokler ga naslednji koraki (validacija, promocija) ne naredijo upravicenega,
  enako kot vsak drug nov PIM-only artikel po migraciji 169.

  Migrator ne pozna locila GO, zato so vse stiri procedure v celoti zavite v EXEC(N'...').
*/

SET XACT_ABORT ON;

IF OBJECT_ID(N'map.SupplierProductCandidate', N'U') IS NULL
BEGIN
  CREATE TABLE map.SupplierProductCandidate
  (
    SupplierProductCandidateId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_SupplierProductCandidate PRIMARY KEY,
    OrganizationId    int NOT NULL,
    SourceCode        nvarchar(100) NOT NULL,
    ItemID            nvarchar(100) NOT NULL,
    EAN               nvarchar(100) NULL,
    InboxId           bigint NOT NULL,
    RecordOrdinal     int NOT NULL,
    Status            nvarchar(20) NOT NULL CONSTRAINT DF_SupplierProductCandidate_Status DEFAULT(N'PENDING'),
    IsActive          bit NOT NULL CONSTRAINT DF_SupplierProductCandidate_IsActive DEFAULT(1),
    FirstSeenUtc      datetime2(3) NOT NULL CONSTRAINT DF_SupplierProductCandidate_FirstSeenUtc DEFAULT SYSUTCDATETIME(),
    LastSeenUtc       datetime2(3) NOT NULL CONSTRAINT DF_SupplierProductCandidate_LastSeenUtc DEFAULT SYSUTCDATETIME(),
    OccurrenceCount   int NOT NULL CONSTRAINT DF_SupplierProductCandidate_OccurrenceCount DEFAULT(1),
    DecidedUtc        datetime2(3) NULL,
    DecidedBy         nvarchar(200) NULL,
    DecisionReason    nvarchar(500) NULL,
    CreatedProductId  bigint NULL,
    CONSTRAINT FK_SupplierProductCandidate_Organization FOREIGN KEY(OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT FK_SupplierProductCandidate_Inbox FOREIGN KEY(InboxId) REFERENCES raw.Inbox(InboxId),
    CONSTRAINT FK_SupplierProductCandidate_Product FOREIGN KEY(CreatedProductId) REFERENCES canon.Product(ProductId),
    CONSTRAINT CK_SupplierProductCandidate_Status CHECK(Status IN (N'PENDING',N'APPROVED',N'REJECTED')),
    CONSTRAINT CK_SupplierProductCandidate_StatusConsistency CHECK(
      (Status=N'PENDING' AND IsActive=1 AND DecidedUtc IS NULL AND DecidedBy IS NULL)
      OR (Status IN (N'APPROVED',N'REJECTED') AND IsActive=0 AND DecidedUtc IS NOT NULL AND DecidedBy IS NOT NULL)
    ),
    CONSTRAINT CK_SupplierProductCandidate_CreatedProduct CHECK(
      (Status=N'APPROVED' AND CreatedProductId IS NOT NULL) OR (Status<>N'APPROVED' AND CreatedProductId IS NULL)
    )
  );

  -- Najvec en ODPRT kandidat na (podjetje, sifro) hkrati; zgodovinske (zavrnjene/odobrene)
  -- vrstice ostanejo, ker IsActive=0 pade iz tega indeksa -- enak vzorec kot
  -- UX_ProductHold_ActiveChannel (194).
  CREATE UNIQUE INDEX UX_SupplierProductCandidate_ActiveItem
    ON map.SupplierProductCandidate(OrganizationId,ItemID) WHERE IsActive=1;

  -- "Najnovejsa vrstica na sifro" (aktivna ali zgodovinska) -- uporablja jo tako
  -- map.ProcessRawInbox kot bralna procedura za UI.
  CREATE INDEX IX_SupplierProductCandidate_ItemHistory
    ON map.SupplierProductCandidate(OrganizationId,ItemID,SupplierProductCandidateId DESC) INCLUDE(IsActive,Status,EAN);

  -- Glavna pot pregleda: podjetje + stanje (+ vir).
  CREATE INDEX IX_SupplierProductCandidate_Review
    ON map.SupplierProductCandidate(OrganizationId,IsActive,SourceCode)
    INCLUDE(ItemID,EAN,Status,FirstSeenUtc,LastSeenUtc,OccurrenceCount,DecidedUtc,DecidedBy);
END;

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessRawInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  DECLARE @CanCreateProducts bit =
  (
    SELECT TOP(1) CanCreateProducts FROM map.SourceConnector
    WHERE SourceCode=@SourceCode AND OrganizationId=@OrganizationId AND IsActive=1
  );
  IF @CanCreateProducts IS NULL THROW 52310,''Aktivni izvorni konektor ne obstaja.'',1;
  /*
    En zapis iz XML = ena vrstica. Prej je bil to kurzor, zdaj je tabela, ki jo
    obdelamo v celoti naenkrat.
  */
  CREATE TABLE #Record
  (
    RecordOrdinal   int NOT NULL PRIMARY KEY,
    ItemID          nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    EAN             nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    ProductId       bigint NULL,
    RejectionReason nvarchar(500) COLLATE DATABASE_DEFAULT NULL
  );
  /* Artikli, ki jih je ta vhodna vrstica ustvarila (samo ERP viri). */
  CREATE TABLE #Created
  (
    ItemID    nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
    ProductId bigint NOT NULL
  );
  /*
    Zmagovalna vrednost na (izdelek, ciljno polje). Kurzor je zapise obdeloval po
    vrsti in vsak naslednji je s COALESCE prepisal prejsnjega; tu isto pravilo
    izrazimo z DENSE_RANK po RecordOrdinal DESC: zadnji nepraznji zapis zmaga.
  */
  CREATE TABLE #Value
  (
    ProductId       bigint NOT NULL,
    TargetFieldCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
    Value           nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
    PRIMARY KEY(ProductId, TargetFieldCode)   /* brez imena: imenovana omejitev na #tabeli trci med hkratnimi sejami */
  );
  /*
    219: kandidati brez pravice ustvarjanja (korak 5b). En zapis na sifro (ze filtrirano na
    zadnji/prvi pojav) - CTE tu ne pride v postev, ker jo rabita DVA locena stavka (UPDATE in
    INSERT), CTE pa velja samo za stavek takoj za njo.
  */
  CREATE TABLE #NovKandidat
  (
    ItemID        nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
    EAN           nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    RecordOrdinal int NOT NULL
  );
  CREATE TABLE #Zadnji
  (
    ItemID                     nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
    SupplierProductCandidateId bigint NOT NULL,
    EAN                        nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    IsActive                   bit NOT NULL,
    Status                     nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL
  );
  DECLARE @InboxId bigint;
  DECLARE inbox_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT inbox.InboxId
    FROM raw.Inbox inbox
    WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId
      AND inbox.SourceCode=@SourceCode AND inbox.Status=''Pending''
      AND EXISTS(SELECT 1 FROM map.ExtractedValue value WHERE value.InboxId=inbox.InboxId)
      /*
        Ta postopek zna samo izdelke: zapis brez sifre ali EAN mu je zavrnjen zapis. Sifranti
        (skladisca, valute, ceniki) so drug svet in imajo svoj postopek, zato se tu preskocijo.
        Kateri svet je kateri, pove register (map.EntityMapping.TargetDomain), ne ime entitete.
        Pogoj je NOT EXISTS in ne EXISTS namenoma: preskoci se samo tisto, kar je izrecno
        oznaceno kot drug svet. Odsotnost vrstice v registru pomeni izdelek - enako kot prej,
        ko tega stolpca ni bilo, in enako kot privzetek TargetDomain.
      */
      AND NOT EXISTS
      (
        SELECT 1
        FROM map.EntityMapping entityMapping
        INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
        WHERE connector.SourceCode=inbox.SourceCode AND connector.OrganizationId=inbox.OrganizationId
          AND entityMapping.EntityType=inbox.EntityType AND entityMapping.IsActive=1
          AND entityMapping.TargetDomain<>''Product''
      )
    ORDER BY inbox.InboxId;
  OPEN inbox_cursor;
  FETCH NEXT FROM inbox_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      /* Zunaj transakcije, da povrnitev ne ozivi vrstic prejsnje vhodne vrstice. */
      DELETE FROM #Record;
      DELETE FROM #Created;
      DELETE FROM #Value;
      DELETE FROM #NovKandidat;
      DELETE FROM #Zadnji;
      BEGIN TRANSACTION;
      DECLARE @SuccessCount int=0,@RejectedCount int=0,@CreatedCount int=0,@LastFailureReason nvarchar(500)=NULL;
      /* --- 1. en zapis = ena vrstica ------------------------------------ */
      INSERT #Record(RecordOrdinal,ItemID,EAN)
      SELECT value.RecordOrdinal,
        NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(100),MAX(CASE WHEN value.TargetFieldCode=''Product.ItemID'' THEN value.Value END)))),''''),
        NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(100),MAX(CASE WHEN value.TargetFieldCode=''Product.EAN'' THEN value.Value END)))),'''')
      FROM map.ExtractedValue value
      WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
      GROUP BY value.RecordOrdinal;
      /* --- 2. manjkajoca obvezna vrednost -------------------------------- */
      UPDATE record SET RejectionReason=''Obvezna preslikana vrednost manjka.''
      FROM #Record record
      WHERE EXISTS
      (
        SELECT 1
        FROM map.ExtractedValue value
        INNER JOIN map.FieldMapping mapping ON mapping.FieldMappingId=value.FieldMappingId
          AND mapping.MappingVersion=value.MappingVersion
        WHERE value.InboxId=@InboxId AND value.RecordOrdinal=record.RecordOrdinal
          AND mapping.IsActive=1 AND mapping.IsRequired=1
          AND NULLIF(LTRIM(RTRIM(value.Value)),'''') IS NULL
      );
      /* --- 3. poisci izdelek: najprej po ItemID, sele nato po EAN --------- */
      UPDATE record SET ProductId=najden.ProductId
      FROM #Record record
      CROSS APPLY
      (
        SELECT TOP(1) product.ProductId FROM canon.Product product
        WHERE product.OrganizationId=@OrganizationId AND product.ItemID=record.ItemID
        ORDER BY product.ProductId
      ) najden
      WHERE record.RejectionReason IS NULL AND record.ItemID IS NOT NULL;
      UPDATE record SET ProductId=najden.ProductId
      FROM #Record record
      CROSS APPLY
      (
        SELECT TOP(1) product.ProductId FROM canon.Product product
        WHERE product.OrganizationId=@OrganizationId AND product.EAN=record.EAN
        ORDER BY product.ProductId
      ) najden
      WHERE record.RejectionReason IS NULL AND record.ProductId IS NULL AND record.EAN IS NOT NULL;
      /* --- 3b. artikel je medtem nastal po drugi poti: zapri cakajocega kandidata -----------
         219: ta zapis se je zdaj ujel s ProductId (zgoraj), ceprav je za isto sifro morda se
         odprt kandidat za rocni pregled (map.SupplierProductCandidate). To pomeni, da je artikel
         medtem nastal po drugi poti (najveckrat SAOP, neodvisno od kandidata) - kandidat je
         prehiten in se zapre kot samodejno odobren, da ne ostane v cakalnem seznamu, kot da se
         ni zgodilo nic. Samodejno zaprtje NI enako uporabniski odobritvi: ProductId je ustvaril
         nekdo drug, ne ta postopek. */
      UPDATE candidate SET
        Status=''APPROVED'', IsActive=0, DecidedUtc=SYSUTCDATETIME(), DecidedBy=''sistem (map.ProcessRawInbox)'',
        DecisionReason=''Artikel je medtem nastal po drugi poti; kandidat zaprt samodejno.'',
        CreatedProductId=najdenProdukt.ProductId
      FROM map.SupplierProductCandidate candidate
      INNER JOIN
      (
        SELECT DISTINCT ItemID,ProductId FROM #Record WHERE RejectionReason IS NULL AND ProductId IS NOT NULL
      ) najdenProdukt ON najdenProdukt.ItemID=candidate.ItemID
      WHERE candidate.OrganizationId=@OrganizationId AND candidate.IsActive=1;
      /* --- 4. ERP vir sme artikel ustvariti ------------------------------- */
      IF @CanCreateProducts=1
      BEGIN
        /*
          Ista sifra se v isti strani lahko pojavi veckrat. Kurzor je artikel
          ustvaril ob prvem pojavu, ostali pojavi so ga nato nasli; tu ustvarimo
          eno vrstico na sifro, po prvem zapisu, in jo priklopimo na vse pojave.
        */
        ;WITH nov AS
        (
          SELECT ItemID,EAN,ROW_NUMBER() OVER(PARTITION BY ItemID ORDER BY RecordOrdinal) Zaporedje
          FROM #Record
          WHERE RejectionReason IS NULL AND ProductId IS NULL AND ItemID IS NOT NULL
        )
        INSERT canon.Product(OrganizationId,ItemID,EAN,BusinessHash)
        OUTPUT inserted.ItemID,inserted.ProductId INTO #Created(ItemID,ProductId)
        SELECT @OrganizationId,nov.ItemID,nov.EAN,
          CONVERT(char(64),HASHBYTES(''SHA2_256'',CONCAT(nov.ItemID,''|'',nov.EAN)),2)
        FROM nov WHERE nov.Zaporedje=1;
        SET @CreatedCount=@@ROWCOUNT;
        UPDATE record SET ProductId=created.ProductId
        FROM #Record record
        INNER JOIN #Created created ON created.ItemID=record.ItemID
        WHERE record.ProductId IS NULL;
      END;
      /* --- 5. izdelka ni ------------------------------------------------- */
      UPDATE #Record SET RejectionReason=''Izdelek za konfigurirani identifikator ne obstaja.''
      WHERE RejectionReason IS NULL AND ProductId IS NULL;
      /* --- 5b. dobaviteljev vir brez pravice ustvarjanja: kandidat za rocni pregled ---------
         219: prej se je neujemajoc zapis samo prestel v raw.Inbox.FailureReason; identiteta
         (sifra, EAN) ni bila nikjer poizvedljiva. Zdaj se ohrani v map.SupplierProductCandidate,
         da jo clovek odobri (nastane canon.Product, naslednji tek to stran obogati - brez
         podvojene obogatitvene logike) ali zavrne (ne sprasuj vec, razen ce se pri isti sifri
         EAN spremeni). */
      IF @CanCreateProducts=0
      BEGIN
        INSERT #NovKandidat(ItemID,EAN,RecordOrdinal)
        SELECT nov.ItemID,nov.EAN,nov.RecordOrdinal
        FROM
        (
          SELECT ItemID,EAN,RecordOrdinal,
            ROW_NUMBER() OVER(PARTITION BY ItemID ORDER BY RecordOrdinal) Zaporedje
          FROM #Record
          WHERE RejectionReason=''Izdelek za konfigurirani identifikator ne obstaja.'' AND ItemID IS NOT NULL
        ) nov
        WHERE nov.Zaporedje=1;

        INSERT #Zadnji(ItemID,SupplierProductCandidateId,EAN,IsActive,Status)
        SELECT zadnji.ItemID,zadnji.SupplierProductCandidateId,zadnji.EAN,zadnji.IsActive,zadnji.Status
        FROM
        (
          SELECT candidate.ItemID,candidate.SupplierProductCandidateId,candidate.EAN,candidate.IsActive,candidate.Status,
            ROW_NUMBER() OVER(PARTITION BY candidate.ItemID ORDER BY candidate.SupplierProductCandidateId DESC) Mesto
          FROM map.SupplierProductCandidate candidate
          WHERE candidate.OrganizationId=@OrganizationId
            AND candidate.ItemID IN (SELECT ItemID FROM #NovKandidat)
        ) zadnji
        WHERE zadnji.Mesto=1;

        UPDATE existing SET
          EAN=nov.EAN, SourceCode=@SourceCode, InboxId=@InboxId, RecordOrdinal=nov.RecordOrdinal,
          LastSeenUtc=SYSUTCDATETIME(), OccurrenceCount=existing.OccurrenceCount+1
        FROM map.SupplierProductCandidate existing
        INNER JOIN #Zadnji zadnji ON zadnji.SupplierProductCandidateId=existing.SupplierProductCandidateId
        INNER JOIN #NovKandidat nov ON nov.ItemID=existing.ItemID
        WHERE zadnji.IsActive=1                                                    -- se PENDING: samo osvezi
           OR (zadnji.IsActive=0 AND zadnji.Status=''REJECTED''                      -- zavrnjen in NESPREMENJEN: sledi, ne odpira
               AND ISNULL(zadnji.EAN,'''')=ISNULL(nov.EAN,''''));

        INSERT map.SupplierProductCandidate(OrganizationId,SourceCode,ItemID,EAN,InboxId,RecordOrdinal,Status,IsActive)
        SELECT @OrganizationId,@SourceCode,nov.ItemID,nov.EAN,@InboxId,nov.RecordOrdinal,''PENDING'',1
        FROM #NovKandidat nov
        WHERE NOT EXISTS
        (
          SELECT 1 FROM #Zadnji zadnji
          WHERE zadnji.ItemID=nov.ItemID
            AND (zadnji.IsActive=1 OR (zadnji.IsActive=0 AND zadnji.Status=''REJECTED'' AND ISNULL(zadnji.EAN,'''')=ISNULL(nov.EAN,'''')))
        );
      END;
      /* --- 6. neveljavna cena -------------------------------------------- */
      UPDATE record SET RejectionReason=''Neveljavna cena, DDV ali datum veljavnosti.''
      FROM #Record record
      WHERE record.RejectionReason IS NULL AND EXISTS
      (
        SELECT 1 FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId AND value.RecordOrdinal=record.RecordOrdinal AND value.Value IS NOT NULL
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
          AND
          (
            (value.TargetFieldCode=''ProductPrice.Net''
              AND (TRY_CONVERT(decimal(19,4),value.Value) IS NULL OR TRY_CONVERT(decimal(19,4),value.Value)<0))
            OR (value.TargetFieldCode=''ProductPrice.VatRate''
              AND (TRY_CONVERT(decimal(5,2),value.Value) IS NULL
                OR TRY_CONVERT(decimal(5,2),value.Value)<0 OR TRY_CONVERT(decimal(5,2),value.Value)>100))
            OR (value.TargetFieldCode=''ProductPrice.ValidFrom''
              AND TRY_CONVERT(datetime2(3),value.Value) IS NULL)
          )
      );
      /* --- 7. stevci ------------------------------------------------------ */
      SELECT
        @SuccessCount=COALESCE(SUM(CASE WHEN RejectionReason IS NULL THEN 1 ELSE 0 END),0),
        @RejectedCount=COALESCE(SUM(CASE WHEN RejectionReason IS NULL THEN 0 ELSE 1 END),0)
      FROM #Record;
      SET @LastFailureReason=
      (
        SELECT TOP(1) RejectionReason FROM #Record
        WHERE RejectionReason IS NOT NULL ORDER BY RecordOrdinal DESC
      );
      /*
        --- 8. zmagovalne vrednosti sprejetih zapisov ----------------------
        154: prazen-po-obrezavi niz odslej NE velja za vrednost. Prej samo ''value.Value IS
        NOT NULL'' - prazen niz iz XQuery (element brez vsebine) je sel skozi in prek korakov
        10/11 spodaj izpraznil obstojeco dobro vrednost iz drugega vira/teka.
      */
      INSERT #Value(ProductId,TargetFieldCode,Value)
      SELECT zmagovalec.ProductId,zmagovalec.TargetFieldCode,MAX(zmagovalec.Value)
      FROM
      (
        SELECT record.ProductId,value.TargetFieldCode,value.Value,
          DENSE_RANK() OVER(PARTITION BY record.ProductId,value.TargetFieldCode
                            ORDER BY value.RecordOrdinal DESC) Mesto
        FROM map.ExtractedValue value
        INNER JOIN #Record record ON record.RecordOrdinal=value.RecordOrdinal
        WHERE value.InboxId=@InboxId AND record.RejectionReason IS NULL AND NULLIF(LTRIM(RTRIM(value.Value)), N'''') IS NOT NULL
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
      ) zmagovalec
      WHERE zmagovalec.Mesto=1
      GROUP BY zmagovalec.ProductId,zmagovalec.TargetFieldCode;
      /* --- 9. canon.Product ----------------------------------------------- */
      UPDATE product SET
        EAN=COALESCE(source.EAN,product.EAN),
        UoM=COALESCE(source.UoM,product.UoM),
        AccountingGroup=COALESCE(source.AccountingGroup,product.AccountingGroup),
        Supplier=COALESCE(source.Supplier,product.Supplier),
        DiscountGroup=COALESCE(source.DiscountGroup,product.DiscountGroup),
        Manufacturer=COALESCE(source.Manufacturer,product.Manufacturer),
        ItemGroup=COALESCE(source.ItemGroup,product.ItemGroup),
        VatRateId=COALESCE(source.VatRateId,product.VatRateId),
        HasSeries=COALESCE(source.HasSeries,product.HasSeries),
        PriceListCode=COALESCE(source.PriceListCode,product.PriceListCode),
        Department=COALESCE(source.Department,product.Department),
        WebPublish=COALESCE(source.WebPublish,product.WebPublish),
        IsActive=COALESCE(source.IsActive,product.IsActive),
        ValidationStatus=''PENDING''
      FROM canon.Product product
      INNER JOIN (SELECT DISTINCT ProductId FROM #Record WHERE RejectionReason IS NULL) sprejet
        ON sprejet.ProductId=product.ProductId
      LEFT JOIN
      (
        SELECT ProductId,
          NULLIF(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.EAN'' THEN Value END))),'''') EAN,
          MAX(CASE WHEN TargetFieldCode=''Product.UoM'' THEN Value END) UoM,
          MAX(CASE WHEN TargetFieldCode=''Product.AccountingGroup'' THEN Value END) AccountingGroup,
          MAX(CASE WHEN TargetFieldCode=''Product.Supplier'' THEN Value END) Supplier,
          MAX(CASE WHEN TargetFieldCode=''Product.DiscountGroup'' THEN Value END) DiscountGroup,
          MAX(CASE WHEN TargetFieldCode=''Product.Manufacturer'' THEN Value END) Manufacturer,
          NULLIF(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.ItemGroup'' THEN Value END))),'''') ItemGroup,
          NULLIF(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.VatRateId'' THEN Value END))),'''') VatRateId,
          NULLIF(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.PriceListCode'' THEN Value END))),'''') PriceListCode,
          CASE UPPER(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.HasSeries'' THEN Value END))))
            WHEN ''D'' THEN CONVERT(bit,1) WHEN ''Y'' THEN CONVERT(bit,1)
            WHEN ''TRUE'' THEN CONVERT(bit,1) WHEN ''1'' THEN CONVERT(bit,1)
            WHEN ''N'' THEN CONVERT(bit,0) WHEN ''FALSE'' THEN CONVERT(bit,0) WHEN ''0'' THEN CONVERT(bit,0)
            ELSE NULL END HasSeries,
          NULLIF(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.Department'' THEN Value END))),'''') Department,
          CASE UPPER(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.WebPublish'' THEN Value END))))
            WHEN ''D'' THEN CONVERT(bit,1) WHEN ''Y'' THEN CONVERT(bit,1)
            WHEN ''TRUE'' THEN CONVERT(bit,1) WHEN ''1'' THEN CONVERT(bit,1)
            WHEN ''N'' THEN CONVERT(bit,0) WHEN ''FALSE'' THEN CONVERT(bit,0) WHEN ''0'' THEN CONVERT(bit,0)
            ELSE NULL END WebPublish,
          CASE UPPER(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=''Product.IsActive'' THEN Value END))))
            WHEN ''D'' THEN CONVERT(bit,1) WHEN ''Y'' THEN CONVERT(bit,1)
            WHEN ''TRUE'' THEN CONVERT(bit,1) WHEN ''1'' THEN CONVERT(bit,1)
            WHEN ''N'' THEN CONVERT(bit,0) WHEN ''FALSE'' THEN CONVERT(bit,0) WHEN ''0'' THEN CONVERT(bit,0)
            ELSE NULL END IsActive
        FROM #Value GROUP BY ProductId
      ) source ON source.ProductId=product.ProductId;
      /* --- 10. canon.ProductText ------------------------------------------ */
      MERGE canon.ProductText AS target
      USING
      (
        SELECT ProductId,
          CONVERT(nvarchar(50),SUBSTRING(TargetFieldCode,13,LEN(TargetFieldCode)-13-CHARINDEX(''.'',REVERSE(TargetFieldCode))+1)) TextType,
          CONVERT(nvarchar(20),RIGHT(TargetFieldCode,CHARINDEX(''.'',REVERSE(TargetFieldCode))-1)) Lang,
          MAX(Value) Value
        FROM #Value
        WHERE TargetFieldCode LIKE ''ProductText.%''
        GROUP BY ProductId,
          SUBSTRING(TargetFieldCode,13,LEN(TargetFieldCode)-13-CHARINDEX(''.'',REVERSE(TargetFieldCode))+1),
          RIGHT(TargetFieldCode,CHARINDEX(''.'',REVERSE(TargetFieldCode))-1)
      ) source
        ON target.ProductId=source.ProductId AND target.TextType=source.TextType AND target.Lang=source.Lang
      WHEN MATCHED THEN UPDATE SET Value=source.Value
      WHEN NOT MATCHED THEN INSERT(ProductId,Lang,TextType,Value)
        VALUES(source.ProductId,source.Lang,source.TextType,source.Value);
      /* --- 11. canon.ProductAttribute -------------------------------------- */
      MERGE canon.ProductAttribute AS target
      USING
      (
        SELECT ProductId,CONVERT(nvarchar(200),SUBSTRING(TargetFieldCode,18,200)) AttributeCode,MAX(Value) Value
        FROM #Value
        WHERE TargetFieldCode LIKE ''ProductAttribute.%''
        GROUP BY ProductId,SUBSTRING(TargetFieldCode,18,200)
      ) source
        ON target.ProductId=source.ProductId AND target.AttributeCode=source.AttributeCode
      WHEN MATCHED THEN UPDATE SET Value=source.Value
      WHEN NOT MATCHED THEN INSERT(ProductId,AttributeCode,Value)
        VALUES(source.ProductId,source.AttributeCode,source.Value);
      /*
        --- 12. canon.ProductCategory ---------------------------------------
        En zapis lahko pripada vec kategorijam (vec preslikav z isto ciljno kodo),
        zato se tu ne bere iz #Value, ki hrani eno vrednost na ciljno kodo.
      */
      MERGE canon.ProductCategory AS target
      USING
      (
        SELECT DISTINCT record.ProductId,CONVERT(nvarchar(1000),value.Value) CategoryPath
        FROM map.ExtractedValue value
        INNER JOIN #Record record ON record.RecordOrdinal=value.RecordOrdinal
        WHERE value.InboxId=@InboxId AND record.RejectionReason IS NULL
          AND value.TargetFieldCode=''ProductCategory.CategoryPath'' AND value.Value IS NOT NULL
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
      ) source
        ON target.ProductId=source.ProductId AND target.WebSite=''B2C'' AND target.CategoryPath=source.CategoryPath
      WHEN NOT MATCHED THEN INSERT(ProductId,WebSite,CategoryPath)
        VALUES(source.ProductId,''B2C'',source.CategoryPath);
      /*
        --- 13. canon.ProductMedia -------------------------------------------
        Izdelek ima vec slik, ne ene. Do migracije 135 je ta blok bral iz #Value, ki hrani
        eno vrednost na ciljno kodo, in z MAX(Value) obdrzal natanko eno - merjeno: 7.648
        slik pri 7.648 izdelkih, torej ena na izdelek, medtem ko ima Braytronov XML za isti
        izdelek osem <photo> in Nowodvorski poleg glavne se sliko z merami.
        Zato se tu bere neposredno iz map.ExtractedValue, enako kot pri kategorijah zgoraj:
        ena vrstica na sliko. Vrstni red slike doloci vrstni red preslikave (SourceElement),
        ker prav ta nosi zaporedje iz dobaviteljeve datoteke; prva slika je PRIMARY, ostale
        so GALLERY, da glavna slika ostane prepoznavna.

        162: do zdaj je ena preslikava dala natanko eno sliko (photo[2], photo[3] ... do
        photo[10]; image_ii ... image_v), zato je bila stevilo slik trdo omejeno z stevilom
        nastetih preslikav. Odslej sme ena preslikava (map.FieldMapping.IsMultiValue = 1)
        vrniti vse zadetke; zaporedje med njimi je map.ExtractedValue.ValueOrdinal.
      */
      /*
        165: ambientalna slika na drugo mesto. Uporabnik 2026-09-04: "dej tako da bo ambientalna
        slika na drugem mestu". Nowodvorski vrsto slike poslje v image_<r>_type ("zdjecie
        inspiracji" = ambientalna; "Glowne zdjecie produktowe" = glavna; ostalo = galerija),
        Braytron vrste nima. Vrsta se zajame kot ProductMedia.Kind z istim ValueOrdinal kot pot;
        upostevana je SAMO, kadar ima zapis enako stevilo vrst in poti - sicer bi zamik enega
        praznega elementa napacno oznacil vse naslednje slike.
        Vrstni red: PRIMARY (prva v datoteki)  AMBIENT  GALLERY, znotraj skupine po datoteki.
      */
      MERGE canon.ProductMedia AS target
      USING
      (
        SELECT ProductId, Url,
          Role = CASE WHEN FileOrder = 1 THEN ''PRIMARY''
                      WHEN Kind LIKE ''%inspirac%'' THEN ''AMBIENT''
                      ELSE ''GALLERY'' END,
          SortOrder = ROW_NUMBER() OVER (PARTITION BY ProductId
            ORDER BY CASE WHEN FileOrder = 1 THEN 0 WHEN Kind LIKE ''%inspirac%'' THEN 1 ELSE 2 END, FileOrder)
        FROM
        (
          SELECT ProductId, Url, Kind,
            FileOrder = ROW_NUMBER() OVER (PARTITION BY ProductId ORDER BY MappingPosition, Poz, SourceElement)
          FROM
          (
            SELECT record.ProductId, Url = CONVERT(nvarchar(2000), value.Value),
              MappingPosition = MIN(COALESCE(TRY_CONVERT(int, SUBSTRING(mapping.SourceElement,
                CHARINDEX(''['', mapping.SourceElement) + 1,
                NULLIF(CHARINDEX('']'', mapping.SourceElement), 0) - CHARINDEX(''['', mapping.SourceElement) - 1)), 1)),
              Poz = MIN(value.ValueOrdinal),
              SourceElement = MIN(mapping.SourceElement),
              Kind = MAX(CASE WHEN kindCount.Kinds = kindCount.Paths THEN kind.Value END)
            FROM map.ExtractedValue value
            INNER JOIN #Record record ON record.RecordOrdinal=value.RecordOrdinal
            INNER JOIN map.FieldMapping mapping ON mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1
            LEFT JOIN map.ExtractedValue kind
              ON kind.InboxId=value.InboxId AND kind.RecordOrdinal=value.RecordOrdinal
             AND kind.ValueOrdinal=value.ValueOrdinal AND kind.TargetFieldCode=''ProductMedia.Kind''
             AND EXISTS (SELECT 1 FROM map.FieldMapping km WHERE km.FieldMappingId=kind.FieldMappingId AND km.IsActive=1)
            OUTER APPLY
            (
              /*
                166: stejejo samo vrstice AKTIVNIH preslikav. Po 163 so v map.ExtractedValue se
                vrstice deaktiviranih image_i..v (nic se ne brise), zato je bilo poti vedno vec
                kot vrst in varovalka je vrsto vedno zavrgla - ambientalne ni bilo nikoli.
              */
              SELECT
                Paths = (SELECT COUNT(*) FROM map.ExtractedValue p
                         INNER JOIN map.FieldMapping pm ON pm.FieldMappingId=p.FieldMappingId AND pm.IsActive=1
                         WHERE p.InboxId=value.InboxId AND p.RecordOrdinal=value.RecordOrdinal
                           AND p.TargetFieldCode=''ProductMedia.Url'' AND p.Value IS NOT NULL),
                Kinds = (SELECT COUNT(*) FROM map.ExtractedValue k
                         INNER JOIN map.FieldMapping km2 ON km2.FieldMappingId=k.FieldMappingId AND km2.IsActive=1
                         WHERE k.InboxId=value.InboxId AND k.RecordOrdinal=value.RecordOrdinal
                           AND k.TargetFieldCode=''ProductMedia.Kind'' AND k.Value IS NOT NULL)
            ) kindCount
            WHERE value.InboxId=@InboxId AND record.RejectionReason IS NULL
              AND value.TargetFieldCode=''ProductMedia.Url'' AND value.Value IS NOT NULL
            GROUP BY record.ProductId, CONVERT(nvarchar(2000), value.Value)
          ) zdruzeno
        ) razvrsceno
      ) source
        ON target.ProductId=source.ProductId AND target.Url=source.Url
      WHEN MATCHED THEN UPDATE SET Role=source.Role, SortOrder=source.SortOrder
      WHEN NOT MATCHED THEN INSERT(ProductId,Url,Role,SortOrder)
        VALUES(source.ProductId,source.Url,source.Role,source.SortOrder);
      /*
        --- 14. canon.ProductPrice -------------------------------------------
        Cena je celota (cenik + neto + DDV + veljavnost) in nastane iz enega zapisa,
        zato se sestavi po zapisu, sele nato obvelja zadnji zapis na kljuc.
      */
      /*
        Novost 057: trgovinski podatki. SAOP jih posilja v ItemGeneralData pod PropertiesData
        (teze, volumen, mere, kolicine pakiranja) in v GeneralData/CustomsTariffNo, mi pa smo
        jih doslej zavrgli - canon.ProductCommercial je imela 0 vrstic, zato sta bila profila
        ERP_L1_EU in COMMERCIAL_L2 pri 0 % veljavnih.
        Stevilke pridejo kot besedilo; TRY_CONVERT pomeni, da neveljavna vrednost postane NULL
        namesto da bi podrla cel zapis. COALESCE ohrani obstojece, kadar vir vrednosti nima -
        enako pravilo kot pri canon.Product.
      */
      MERGE canon.ProductCommercial AS target
      USING
      (
        SELECT ProductId,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.NetWeight'' THEN Value END)) NetWeight,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.GrossWeight'' THEN Value END)) GrossWeight,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.Volume'' THEN Value END)) Volume,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.PackageLength'' THEN Value END)) PackageLength,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.PackageWidth'' THEN Value END)) PackageWidth,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.PackageHeight'' THEN Value END)) PackageHeight,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.Pak1'' THEN Value END)) Pak1,
          TRY_CONVERT(decimal(19,4), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.Pak2'' THEN Value END)) Pak2,
          NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(200), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.CustomsTariff'' THEN Value END)))),'''') CustomsTariff,
          NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(200), MAX(CASE WHEN TargetFieldCode=''ProductCommercial.CountryOfOrigin'' THEN Value END)))),'''') CountryOfOrigin,
          NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(40),  MAX(CASE WHEN TargetFieldCode=''ProductCommercial.DimensionUnit'' THEN Value END)))),'''') DimensionUnit
        FROM #Value
        WHERE TargetFieldCode LIKE ''ProductCommercial.%''
        GROUP BY ProductId
      ) source ON target.ProductId=source.ProductId
      WHEN MATCHED THEN UPDATE SET
        NetWeight=COALESCE(source.NetWeight,target.NetWeight),
        GrossWeight=COALESCE(source.GrossWeight,target.GrossWeight),
        Volume=COALESCE(source.Volume,target.Volume),
        PackageLength=COALESCE(source.PackageLength,target.PackageLength),
        PackageWidth=COALESCE(source.PackageWidth,target.PackageWidth),
        PackageHeight=COALESCE(source.PackageHeight,target.PackageHeight),
        Pak1=COALESCE(source.Pak1,target.Pak1),
        Pak2=COALESCE(source.Pak2,target.Pak2),
        CustomsTariff=COALESCE(source.CustomsTariff,target.CustomsTariff),
        CountryOfOrigin=COALESCE(source.CountryOfOrigin,target.CountryOfOrigin),
        DimensionUnit=COALESCE(source.DimensionUnit,target.DimensionUnit)
      WHEN NOT MATCHED THEN
        INSERT(ProductId,NetWeight,GrossWeight,Volume,PackageLength,PackageWidth,PackageHeight,Pak1,Pak2,CustomsTariff,CountryOfOrigin,DimensionUnit)
        VALUES(source.ProductId,source.NetWeight,source.GrossWeight,source.Volume,source.PackageLength,source.PackageWidth,source.PackageHeight,source.Pak1,source.Pak2,source.CustomsTariff,source.CountryOfOrigin,source.DimensionUnit);
      ;WITH cena AS
      (
        SELECT record.ProductId,value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''ProductPrice.PriceList'' THEN CONVERT(nvarchar(100),value.Value) END) PriceList,
          TRY_CONVERT(decimal(19,4),MAX(CASE WHEN value.TargetFieldCode=''ProductPrice.Net'' THEN value.Value END)) Net,
          TRY_CONVERT(decimal(5,2),MAX(CASE WHEN value.TargetFieldCode=''ProductPrice.VatRate'' THEN value.Value END)) VatRate,
          COALESCE(TRY_CONVERT(datetime2(3),MAX(CASE WHEN value.TargetFieldCode=''ProductPrice.ValidFrom'' THEN value.Value END)),
                   CONVERT(datetime2(3),''19000101'')) ValidFrom
        FROM map.ExtractedValue value
        INNER JOIN #Record record ON record.RecordOrdinal=value.RecordOrdinal
        WHERE value.InboxId=@InboxId AND record.RejectionReason IS NULL
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY record.ProductId,value.RecordOrdinal
      ),
      zadnja AS
      (
        SELECT ProductId,PriceList,Net,VatRate,ValidFrom,
          ROW_NUMBER() OVER(PARTITION BY ProductId,PriceList,ValidFrom ORDER BY RecordOrdinal DESC) Mesto
        FROM cena
        WHERE PriceList IS NOT NULL AND Net IS NOT NULL AND VatRate IS NOT NULL
      )
      MERGE canon.ProductPrice AS target
      USING (SELECT ProductId,PriceList,Net,VatRate,ValidFrom FROM zadnja WHERE Mesto=1) source
        ON target.ProductId=source.ProductId AND target.PriceList=source.PriceList AND target.ValidFrom=source.ValidFrom
      WHEN MATCHED THEN UPDATE SET Net=source.Net,VatRate=source.VatRate,IsActive=1
      WHEN NOT MATCHED THEN INSERT(ProductId,PriceList,Net,VatRate,ValidFrom,IsActive)
        VALUES(source.ProductId,source.PriceList,source.Net,source.VatRate,source.ValidFrom,1);
      /* --- 15. zakljucek vhodne vrstice ------------------------------------ */
      UPDATE raw.Inbox
      SET Status=''Processed'',PayloadXml=NULL,ProcessedUtc=SYSUTCDATETIME(),
        FailureReason=
          CASE
            WHEN @SuccessCount=0 THEN CONVERT(nvarchar(2000),CONCAT(''Vsi zapisi preskoceni ('',@RejectedCount,''): '',COALESCE(@LastFailureReason,''ni podrobnosti.'')))
            WHEN @RejectedCount>0 THEN CONVERT(nvarchar(2000),CONCAT(''Delno obogateno: '',@SuccessCount,'' uspeli, '',@RejectedCount,'' preskocenih. Novih artiklov: '',@CreatedCount,''. Zadnji razlog: '',@LastFailureReason))
            WHEN @CreatedCount>0 THEN CONVERT(nvarchar(2000),CONCAT(''Obdelano; novih artiklov: '',@CreatedCount,''.''))
            ELSE NULL
          END
      WHERE InboxId=@InboxId;
      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      DECLARE @FailureReason nvarchar(2000)=LEFT(ERROR_MESSAGE(),2000);
      BEGIN TRANSACTION;
      INSERT map.UnmappedValue(ExtractedValueId,TargetFieldCode,Value,Reason)
      SELECT value.ExtractedValueId,value.TargetFieldCode,value.Value,@FailureReason
      FROM map.ExtractedValue value
      WHERE value.InboxId=@InboxId
        AND NOT EXISTS
        (
          SELECT 1 FROM map.UnmappedValue rejected
          WHERE rejected.ExtractedValueId=value.ExtractedValueId
        );
      UPDATE raw.Inbox
      SET Status=''Quarantined'',ProcessedUtc=SYSUTCDATETIME(),FailureReason=@FailureReason
      WHERE InboxId=@InboxId;
      COMMIT TRANSACTION;
    END CATCH;
    FETCH NEXT FROM inbox_cursor INTO @InboxId;
  END;
  CLOSE inbox_cursor;
  DEALLOCATE inbox_cursor;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE map.ApproveSupplierProductCandidate
  @SupplierProductCandidateId bigint, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  BEGIN TRANSACTION;
  DECLARE @OrganizationId int,@ItemID nvarchar(100),@EAN nvarchar(100),@ProductId bigint;
  SELECT @OrganizationId=OrganizationId,@ItemID=ItemID,@EAN=EAN
  FROM map.SupplierProductCandidate WITH (UPDLOCK,ROWLOCK)
  WHERE SupplierProductCandidateId=@SupplierProductCandidateId AND Status=''PENDING'' AND IsActive=1;

  IF @OrganizationId IS NULL
  BEGIN
    ROLLBACK TRANSACTION;
    THROW 52422,''Kandidat ne obstaja ali ni vec v cakanju na odlocitev.'',1;
  END;

  /* Ce je artikel medtem nastal po drugi poti (SAOP, vzporeden tek), ga ponovno uporabimo
     namesto da bi podrli UQ_CanonProduct_OrganizationItem. */
  SELECT @ProductId=ProductId FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID;
  IF @ProductId IS NULL
  BEGIN
    INSERT canon.Product(OrganizationId,ItemID,EAN,BusinessHash,ErpExistence)
    VALUES(@OrganizationId,@ItemID,@EAN,
      CONVERT(char(64),HASHBYTES(''SHA2_256'',CONCAT(@ItemID,''|'',@EAN)),2), ''NOT_YET_IN_ERP'');
    SET @ProductId=SCOPE_IDENTITY();
  END;

  UPDATE map.SupplierProductCandidate
  SET Status=''APPROVED'', IsActive=0, DecidedUtc=SYSUTCDATETIME(), DecidedBy=@Actor,
    DecisionReason=CONCAT(''Odobreno; ustvarjen ProductId '',@ProductId,''.''), CreatedProductId=@ProductId
  WHERE SupplierProductCandidateId=@SupplierProductCandidateId;
  COMMIT TRANSACTION;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE map.RejectSupplierProductCandidate
  @SupplierProductCandidateId bigint, @Reason nvarchar(500)=NULL, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @Reason=NULLIF(LTRIM(RTRIM(@Reason)),'''');
  UPDATE map.SupplierProductCandidate
  SET Status=''REJECTED'', IsActive=0, DecidedUtc=SYSUTCDATETIME(), DecidedBy=@Actor,
    DecisionReason=COALESCE(@Reason,''Zavrnjeno brez navedenega razloga.'')
  WHERE SupplierProductCandidateId=@SupplierProductCandidateId AND Status=''PENDING'' AND IsActive=1;
  IF @@ROWCOUNT<>1 THROW 52423,''Kandidata ni bilo mogoce zavrniti.'',1;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetSupplierProductCandidates
  @OrganizationId int=NULL, @SourceCode nvarchar(100)=NULL, @Status nvarchar(20)=NULL,
  @Search nvarchar(200)=NULL, @Skip int=0, @Take int=50
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take=CASE WHEN @Take<1 THEN 50 WHEN @Take>200 THEN 200 ELSE @Take END;
  SET @Skip=CASE WHEN @Skip<0 THEN 0 ELSE @Skip END;
  SET @Search=NULLIF(LTRIM(RTRIM(@Search)),'''');
  DECLARE @Like nvarchar(204)=CASE WHEN @Search IS NULL THEN NULL ELSE ''%''+@Search+''%'' END;

  SELECT candidate.SupplierProductCandidateId, candidate.OrganizationId, organization.Name AS OrganizationName,
    candidate.SourceCode, candidate.ItemID, candidate.EAN, candidate.Status, candidate.IsActive,
    candidate.FirstSeenUtc, candidate.LastSeenUtc, candidate.OccurrenceCount,
    candidate.DecidedUtc, candidate.DecidedBy, candidate.DecisionReason, candidate.CreatedProductId
  INTO #Rows
  FROM map.SupplierProductCandidate candidate
  INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId=candidate.OrganizationId
  WHERE (@OrganizationId IS NULL OR candidate.OrganizationId=@OrganizationId)
    AND (@SourceCode IS NULL OR candidate.SourceCode=@SourceCode)
    AND (@Status IS NULL OR candidate.Status=@Status)
    AND (@Like IS NULL OR candidate.ItemID LIKE @Like OR candidate.EAN LIKE @Like);

  SELECT * FROM #Rows
  ORDER BY CASE Status WHEN ''PENDING'' THEN 0 ELSE 1 END, LastSeenUtc DESC
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT COUNT_BIG(*) TotalCount,
    ISNULL(SUM(CASE WHEN Status=''PENDING'' THEN 1 ELSE 0 END),0) PendingCount,
    ISNULL(SUM(CASE WHEN Status=''APPROVED'' THEN 1 ELSE 0 END),0) ApprovedCount,
    ISNULL(SUM(CASE WHEN Status=''REJECTED'' THEN 1 ELSE 0 END),0) RejectedCount
  FROM #Rows;
END;
');

IF OBJECT_ID(N'map.SupplierProductCandidate', N'U') IS NULL
  THROW 52190, N'219: map.SupplierProductCandidate ni nastala.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'map.SupplierProductCandidate') AND name=N'UX_SupplierProductCandidate_ActiveItem')
  THROW 52191, N'219: manjka enolicni indeks aktivnih kandidatov.', 1;
IF OBJECT_ID(N'map.ApproveSupplierProductCandidate', N'P') IS NULL
  THROW 52192, N'219: map.ApproveSupplierProductCandidate ni nastala.', 1;
IF OBJECT_ID(N'map.RejectSupplierProductCandidate', N'P') IS NULL
  THROW 52193, N'219: map.RejectSupplierProductCandidate ni nastala.', 1;
IF OBJECT_ID(N'intranet.GetSupplierProductCandidates', N'P') IS NULL
  THROW 52194, N'219: intranet.GetSupplierProductCandidates ni nastala.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox')) NOT LIKE N'%SupplierProductCandidate%'
  THROW 52195, N'219: map.ProcessRawInbox ne ohranja vec kandidatov za nove artikle.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox')) NOT LIKE N'%sistem (map.ProcessRawInbox)%'
  THROW 52196, N'219: map.ProcessRawInbox ne zapira vec kandidatov, ki so medtem nastali po drugi poti.', 1;
