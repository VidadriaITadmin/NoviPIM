/* 240: kandidati za nove artikle iz dobaviteljevih XML - po EAN, s pregledom in uvozom.

   Uporabnik 2026-09-21 (»novi artikli«): »da bo nadzor nad novimi artikli iz xmlja ter pregled in
   uvoz«.

   Kaj je bilo narobe (preverjeno na razvojni bazi 2026-09-21):
     1. map.ProcessRawInbox v bazi NI vec vseboval blokov 3b/5b iz migracije 219 (dbo.SchemaMigration
        jo sicer belezi kot uveljavljeno, telo procedure pa je bilo starejse - brez #NovKandidat).
        Kandidati zato niso nastajali; tabela map.SupplierProductCandidate je bila prazna.
     2. Tudi z 219 bi NW_XML in BT_XML kandidatov ne naredila: oba vira preslikata samo Product.EAN
        (dobaviteljeve sifre ne posiljata v Product.ItemID), korak 5b pa je zahteval ItemID IS NOT NULL.
        Zajem BT_XML 2026-09-21 za podjetje 4: »Vsi zapisi preskoceni (3166): Izdelek za konfigurirani
        identifikator ne obstaja.« - in nobenega kandidata.
     3. Odobritev (219) je ustvarila samo golo vrstico canon.Product; podatki iz XML-ja (atributi,
        slike, dokumenti, kategorija) so prisli sele z naslednjim zajemom vira - ki za NW ni tekel od
        24. 8. Uporabnik ni imel kaj pregledati (samo sifra/EAN) in ni mogel uvoziti takoj.

   Kaj ta migracija spremeni:
     - map.SupplierProductCandidate.ItemIdFromEan bit: kandidat, ki nima dobaviteljeve sifre, je
       kljucan po EAN (ItemID = EAN). Ob odobritvi nastane canon.Product z ItemID = EAN in
       ErpExistence = NOT_YET_IN_ERP; pravo sifro dobi, ko gre artikel v SAOP.
     - map.ProcessRawInbox: celotno telo iz 219 (nespremenjeno razen 3b/5b), kljuc kandidata je
       COALESCE(ItemID, EAN); kandidat se ob ujemanju zapre po sifri ali po EAN.
     - intranet.GetSupplierProductCandidates: poleg obstojecega vrne se RunId, EntityType, ItemIdFromEan
       in SupplierTitle (dobaviteljev naziv iz izluscenih vrednosti istega zajema, ce ga vir preslika).
     - intranet.GetSupplierProductCandidateValues: vse izluscene vrednosti zapisov istega zajema z
       isto sifro/EAN (atributi, slike, dokumenti, kategorija) - pregled pred odlocitvijo.
     - map.ImportSupplierProductCandidates: odobri izbrane kandidate in TAKOJ obogati nastale artikle:
       strani zadevnih zajemov gredo nazaj na Pending, nato se za vsak zajem pozenejo map.ProcessRawInbox,
       map.ProcessAttributePairInbox, map.ProcessDocumentInbox in map.ResolveProductCategories - ista
       pot kot pri rednem zajemu (PIM.XmlMapping.SqlMappingPipeline), brez podvojene logike. Zajemi
       se izberejo po sifri/EAN prek vseh zajemov istega vira pri istem podjetju (dobaviteljev zajem
       je lahko razdeljen po entitetah). Ponovna obdelava ni nov pojav: stevec OccurrenceCount in
       LastSeenUtc preostalih cakajocih kandidatov se po obdelavi vrneta na stanje pred uvozom.

   Migrator ne pozna GO (061), zato so procedure v EXEC(N'...'). map.SupplierProductCandidate ima
   filtriran indeks (UX_SupplierProductCandidate_ActiveItem), zato morajo postopki, ki jo pisejo,
   nastati s QUOTED_IDENTIFIER ON (230) - nastavitev velja tudi znotraj EXEC(N'...'). */
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

IF COL_LENGTH(N'map.SupplierProductCandidate', N'ItemIdFromEan') IS NULL
  ALTER TABLE map.SupplierProductCandidate ADD ItemIdFromEan bit NOT NULL CONSTRAINT DF_SupplierProductCandidate_ItemIdFromEan DEFAULT(0);

/* --- 1) map.ProcessRawInbox: telo iz 219 + kljuc po EAN (3b, 5b) ---------------------------- */
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
  /* 240: kljuc kandidata je dobaviteljeva sifra, kadar je vir sploh nima (NW_XML, BT_XML preslikata
     samo Product.EAN), pa EAN - ItemIdFromEan=1. Brez tega dobaviteljski viri niso naredili niti
     enega kandidata (korak 5b je zahteval ItemID). */
  CREATE TABLE #NovKandidat
  (
    ItemID        nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
    EAN           nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    RecordOrdinal int NOT NULL,
    ItemIdFromEan bit NOT NULL
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
        /* 240: kandidat brez sifre je kljucan po EAN, zato se ujame po obeh. */
        SELECT DISTINCT Kljuc,ProductId FROM
        (
          SELECT ItemID Kljuc,ProductId FROM #Record WHERE RejectionReason IS NULL AND ProductId IS NOT NULL AND ItemID IS NOT NULL
          UNION ALL
          SELECT EAN,ProductId FROM #Record WHERE RejectionReason IS NULL AND ProductId IS NOT NULL AND EAN IS NOT NULL
        ) kljuci
      ) najdenProdukt ON najdenProdukt.Kljuc=candidate.ItemID
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
        INSERT #NovKandidat(ItemID,EAN,RecordOrdinal,ItemIdFromEan)
        SELECT nov.Kljuc,nov.EAN,nov.RecordOrdinal,nov.ItemIdFromEan
        FROM
        (
          SELECT COALESCE(ItemID,EAN) Kljuc,EAN,RecordOrdinal,
            CONVERT(bit,CASE WHEN ItemID IS NULL THEN 1 ELSE 0 END) ItemIdFromEan,
            ROW_NUMBER() OVER(PARTITION BY COALESCE(ItemID,EAN) ORDER BY RecordOrdinal) Zaporedje
          FROM #Record
          WHERE RejectionReason=''Izdelek za konfigurirani identifikator ne obstaja.'' AND COALESCE(ItemID,EAN) IS NOT NULL
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

        INSERT map.SupplierProductCandidate(OrganizationId,SourceCode,ItemID,EAN,InboxId,RecordOrdinal,Status,IsActive,ItemIdFromEan)
        SELECT @OrganizationId,@SourceCode,nov.ItemID,nov.EAN,@InboxId,nov.RecordOrdinal,''PENDING'',1,nov.ItemIdFromEan
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

/* --- 2) seznam kandidatov: RunId, EntityType, ItemIdFromEan, dobaviteljev naziv ------------- */
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
    candidate.DecidedUtc, candidate.DecidedBy, candidate.DecisionReason, candidate.CreatedProductId,
    candidate.ItemIdFromEan, inbox.RunId, inbox.EntityType
  INTO #Rows
  FROM map.SupplierProductCandidate candidate
  INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId=candidate.OrganizationId
  INNER JOIN raw.Inbox inbox ON inbox.InboxId=candidate.InboxId
  WHERE (@OrganizationId IS NULL OR candidate.OrganizationId=@OrganizationId)
    AND (@SourceCode IS NULL OR candidate.SourceCode=@SourceCode)
    AND (@Status IS NULL OR candidate.Status=@Status)
    AND (@Like IS NULL OR candidate.ItemID LIKE @Like OR candidate.EAN LIKE @Like);

  SELECT * INTO #Page FROM #Rows
  ORDER BY CASE Status WHEN ''PENDING'' THEN 0 ELSE 1 END, LastSeenUtc DESC, SupplierProductCandidateId DESC
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  /* Dobaviteljev naziv: kljuci (sifra/EAN) zapisov v zajemih te strani se preberejo enkrat, naziv
     pa prek indeksa po ciljni kodi (IX_ExtractedValue_Identity). Vir brez preslikanega naziva
     (danes NW_XML/BT_XML pri vecini podjetij) dobi NULL - nic se ne izmislja. */
  SELECT inbox.RunId, value.InboxId, value.RecordOrdinal, CONVERT(nvarchar(100), value.Value) AS Kljuc
  INTO #Kljuc
  FROM raw.Inbox inbox
  INNER JOIN map.ExtractedValue value
    ON value.InboxId=inbox.InboxId AND value.TargetFieldCode IN (N''Product.ItemID'', N''Product.EAN'')
  WHERE inbox.RunId IN (SELECT DISTINCT RunId FROM #Page)
    AND NULLIF(LTRIM(RTRIM(value.Value)), N'''') IS NOT NULL;

  SELECT page.*,
    SupplierTitle =
    (
      SELECT TOP (1) CONVERT(nvarchar(400), naziv.Value)
      FROM #Kljuc kljuc
      INNER JOIN map.ExtractedValue naziv
        ON naziv.TargetFieldCode LIKE N''ProductText.%TITLE%'' AND naziv.InboxId=kljuc.InboxId AND naziv.RecordOrdinal=kljuc.RecordOrdinal
      WHERE kljuc.RunId=page.RunId AND kljuc.Kljuc IN (page.ItemID, page.EAN)
        AND NULLIF(LTRIM(RTRIM(naziv.Value)), N'''') IS NOT NULL
      ORDER BY CASE WHEN naziv.TargetFieldCode LIKE N''%.sl'' THEN 0 WHEN naziv.TargetFieldCode LIKE N''%.en'' THEN 1 ELSE 2 END,
               CASE WHEN naziv.TargetFieldCode LIKE N''ProductText.WEB_TITLE.%'' THEN 0 ELSE 1 END
    )
  FROM #Page page
  ORDER BY CASE page.Status WHEN ''PENDING'' THEN 0 ELSE 1 END, page.LastSeenUtc DESC, page.SupplierProductCandidateId DESC;

  SELECT COUNT_BIG(*) TotalCount,
    ISNULL(SUM(CASE WHEN Status=''PENDING'' THEN 1 ELSE 0 END),0) PendingCount,
    ISNULL(SUM(CASE WHEN Status=''APPROVED'' THEN 1 ELSE 0 END),0) ApprovedCount,
    ISNULL(SUM(CASE WHEN Status=''REJECTED'' THEN 1 ELSE 0 END),0) RejectedCount
  FROM #Rows;

  DROP TABLE #Kljuc; DROP TABLE #Page; DROP TABLE #Rows;
END;
');

/* --- 3) pregled: vse, kar je dobavitelj poslal za ta artikel v tem zajemu ------------------ */
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetSupplierProductCandidateValues
  @SupplierProductCandidateId bigint
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @OrganizationId int, @SourceCode nvarchar(100), @ItemID nvarchar(100), @EAN nvarchar(100);
  SELECT @OrganizationId=candidate.OrganizationId, @SourceCode=candidate.SourceCode, @ItemID=candidate.ItemID, @EAN=candidate.EAN
  FROM map.SupplierProductCandidate candidate
  WHERE candidate.SupplierProductCandidateId=@SupplierProductCandidateId;
  IF @OrganizationId IS NULL THROW 52430, N''Kandidat ne obstaja.'', 1;

  /* Zapisi vseh entitet (Attribute, Classification, Document, Media) z isto sifro ali EAN - iz VSEH
     zajemov tega vira pri tem podjetju, na entiteto najnovejsi: dobaviteljev zajem je lahko razdeljen
     (NW: en tek samo Document+Media, prejsnji Attribute+Classification), kandidat pa kaze na en tek. */
  SELECT InboxId, EntityType, RecordOrdinal
  INTO #Zapis
  FROM
  (
    SELECT inbox.InboxId, inbox.EntityType, kljuc.RecordOrdinal,
      ROW_NUMBER() OVER (PARTITION BY inbox.EntityType ORDER BY inbox.InboxId DESC, kljuc.RecordOrdinal DESC) AS Mesto
    FROM raw.Inbox inbox
    INNER JOIN map.ExtractedValue kljuc
      ON kljuc.InboxId=inbox.InboxId AND kljuc.TargetFieldCode IN (N''Product.ItemID'', N''Product.EAN'')
     AND CONVERT(nvarchar(100), kljuc.Value) IN (@ItemID, @EAN)
    WHERE inbox.OrganizationId=@OrganizationId AND inbox.SourceCode=@SourceCode
  ) zadnji
  WHERE zadnji.Mesto=1;

  SELECT DISTINCT zapis.EntityType, value.TargetFieldCode, value.ValueOrdinal,
    Value = CONVERT(nvarchar(max), value.Value)
  FROM #Zapis zapis
  INNER JOIN map.ExtractedValue value ON value.InboxId=zapis.InboxId AND value.RecordOrdinal=zapis.RecordOrdinal
  WHERE NULLIF(LTRIM(RTRIM(value.Value)), N'''') IS NOT NULL
    AND EXISTS (SELECT 1 FROM map.FieldMapping mapping WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
  ORDER BY zapis.EntityType, value.TargetFieldCode, value.ValueOrdinal;

  DROP TABLE #Zapis;
END;
');

/* --- 4) odobri in takoj uvozi ------------------------------------------------------------- */
EXEC(N'
CREATE OR ALTER PROCEDURE map.ImportSupplierProductCandidates
  @CandidatesJson nvarchar(max),   /* [1, 2, 3] - SupplierProductCandidateId */
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET @Actor=NULLIF(LTRIM(RTRIM(@Actor)),'''');
  IF @Actor IS NULL THROW 52440, N''Kdo uvaza artikle, mora biti znano (Actor).'', 1;
  IF @CandidatesJson IS NULL OR ISJSON(@CandidatesJson)=0 THROW 52441, N''Seznam kandidatov ni veljaven JSON.'', 1;

  DECLARE @Izbrani TABLE (SupplierProductCandidateId bigint NOT NULL PRIMARY KEY);
  INSERT @Izbrani (SupplierProductCandidateId)
  SELECT DISTINCT TRY_CONVERT(bigint, value) FROM OPENJSON(@CandidatesJson) WHERE TRY_CONVERT(bigint, value) IS NOT NULL;
  IF NOT EXISTS (SELECT 1 FROM @Izbrani) THROW 52442, N''Izberi vsaj enega kandidata.'', 1;

  DECLARE @Odobreni TABLE (SupplierProductCandidateId bigint NOT NULL PRIMARY KEY);
  DECLARE @Napake TABLE (SupplierProductCandidateId bigint NOT NULL, Sporocilo nvarchar(500) NOT NULL);
  DECLARE @Id bigint;
  DECLARE kandidat_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT SupplierProductCandidateId FROM @Izbrani ORDER BY SupplierProductCandidateId;
  OPEN kandidat_cursor;
  FETCH NEXT FROM kandidat_cursor INTO @Id;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      EXEC map.ApproveSupplierProductCandidate @Id, @Actor;
      INSERT @Odobreni (SupplierProductCandidateId) VALUES (@Id);
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      INSERT @Napake (SupplierProductCandidateId, Sporocilo) VALUES (@Id, LEFT(ERROR_MESSAGE(), 500));
    END CATCH;
    FETCH NEXT FROM kandidat_cursor INTO @Id;
  END;
  CLOSE kandidat_cursor; DEALLOCATE kandidat_cursor;

  /* Zajemi, ki nosijo odobrene artikle (po sifri ali EAN, vsi zajemi istega vira pri istem podjetju,
     ne samo tisti, na katerega kaze kandidat - dobaviteljev zajem je lahko razdeljen po entitetah):
     strani nazaj na Pending in skozi isto pot kot redni zajem. Kljuci se preberejo enkrat (#Kljuc). */
  SELECT DISTINCT candidate.OrganizationId, candidate.SourceCode
  INTO #Vir
  FROM map.SupplierProductCandidate candidate
  INNER JOIN @Odobreni odobren ON odobren.SupplierProductCandidateId=candidate.SupplierProductCandidateId;

  SELECT inbox.RunId, inbox.OrganizationId, inbox.SourceCode, inbox.InboxId, CONVERT(nvarchar(100), value.Value) AS Kljuc
  INTO #Kljuc
  FROM raw.Inbox inbox
  INNER JOIN #Vir vir ON vir.OrganizationId=inbox.OrganizationId AND vir.SourceCode=inbox.SourceCode
  INNER JOIN map.ExtractedValue value
    ON value.InboxId=inbox.InboxId AND value.TargetFieldCode IN (N''Product.ItemID'', N''Product.EAN'')
  WHERE NULLIF(LTRIM(RTRIM(value.Value)), N'''') IS NOT NULL;

  SELECT DISTINCT kljuc.RunId, kljuc.OrganizationId, kljuc.SourceCode
  INTO #Tek
  FROM #Kljuc kljuc
  INNER JOIN map.SupplierProductCandidate candidate
    ON candidate.OrganizationId=kljuc.OrganizationId AND candidate.SourceCode=kljuc.SourceCode
   AND kljuc.Kljuc IN (candidate.ItemID, candidate.EAN)
  INNER JOIN @Odobreni odobren ON odobren.SupplierProductCandidateId=candidate.SupplierProductCandidateId;

  /* Ponovna obdelava istih strani NI nov pojav artikla: stevec in cas zadnjega pojava cakajocih
     kandidatov teh virov se po obdelavi vrneta na stanje pred uvozom. */
  SELECT candidate.SupplierProductCandidateId, candidate.OccurrenceCount, candidate.LastSeenUtc
  INTO #Prej
  FROM map.SupplierProductCandidate candidate
  INNER JOIN #Vir vir ON vir.OrganizationId=candidate.OrganizationId AND vir.SourceCode=candidate.SourceCode
  WHERE candidate.IsActive=1;

  DECLARE @Strani int=0;
  UPDATE inbox SET Status=''Pending'', ProcessedUtc=NULL
  FROM raw.Inbox inbox
  WHERE inbox.RunId IN (SELECT RunId FROM #Tek) AND inbox.Status=''Processed''
    AND EXISTS (SELECT 1 FROM map.ExtractedValue value WHERE value.InboxId=inbox.InboxId);
  SET @Strani=@@ROWCOUNT;

  DECLARE @RunId uniqueidentifier, @OrganizationId int, @SourceCode nvarchar(100), @Opomba nvarchar(400);
  DECLARE tek_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT RunId, OrganizationId, SourceCode FROM #Tek;
  OPEN tek_cursor;
  FETCH NEXT FROM tek_cursor INTO @RunId, @OrganizationId, @SourceCode;
  WHILE @@FETCH_STATUS=0
  BEGIN
    SET @Opomba=CONCAT(N''Uvoz kandidatov iz zajema '', CONVERT(nvarchar(36), @RunId));
    EXEC pim.SetChangeContext N''XML_IMPORT'', @Actor, @RunId, @Opomba;
    BEGIN TRY
      EXEC map.ProcessRawInbox @RunId, @OrganizationId, @SourceCode;
      EXEC map.ProcessAttributePairInbox @RunId, @OrganizationId, @SourceCode;
      EXEC map.ProcessDocumentInbox @RunId, @OrganizationId, @SourceCode;
      EXEC map.ResolveProductCategories @RunId, @OrganizationId, @SourceCode;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      INSERT @Napake (SupplierProductCandidateId, Sporocilo) VALUES (0, LEFT(CONCAT(N''Zajem '', CONVERT(nvarchar(36), @RunId), N'': '', ERROR_MESSAGE()), 500));
    END CATCH;
    EXEC pim.ClearChangeContext;
    FETCH NEXT FROM tek_cursor INTO @RunId, @OrganizationId, @SourceCode;
  END;
  CLOSE tek_cursor; DEALLOCATE tek_cursor;

  UPDATE candidate SET OccurrenceCount=prej.OccurrenceCount, LastSeenUtc=prej.LastSeenUtc
  FROM map.SupplierProductCandidate candidate
  INNER JOIN #Prej prej ON prej.SupplierProductCandidateId=candidate.SupplierProductCandidateId
  WHERE candidate.IsActive=1;

  SELECT
    Approved=(SELECT COUNT(*) FROM @Odobreni),
    Skipped=(SELECT COUNT(*) FROM @Napake WHERE SupplierProductCandidateId<>0),
    Runs=(SELECT COUNT(*) FROM #Tek),
    Pages=@Strani,
    Errors=(SELECT STRING_AGG(CONCAT(CASE WHEN SupplierProductCandidateId=0 THEN N'''' ELSE CONCAT(N''#'', SupplierProductCandidateId, N'': '') END, Sporocilo), N''; '') FROM @Napake);
  DROP TABLE #Tek; DROP TABLE #Kljuc; DROP TABLE #Vir; DROP TABLE #Prej;
END;
');

/* --- Dokaz ------------------------------------------------------------------------------- */
IF COL_LENGTH(N'map.SupplierProductCandidate', N'ItemIdFromEan') IS NULL
  THROW 52450, N'240: stolpec ItemIdFromEan ni nastal.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox')) NOT LIKE N'%COALESCE(ItemID,EAN) Kljuc%'
  THROW 52451, N'240: map.ProcessRawInbox ne kljuca kandidatov po EAN.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox')) NOT LIKE N'%sistem (map.ProcessRawInbox)%'
  THROW 52452, N'240: map.ProcessRawInbox ne zapira vec kandidatov, ki so medtem nastali po drugi poti (219).', 1;
IF OBJECT_ID(N'intranet.GetSupplierProductCandidateValues', N'P') IS NULL
  THROW 52453, N'240: intranet.GetSupplierProductCandidateValues ni nastala.', 1;
IF OBJECT_ID(N'map.ImportSupplierProductCandidates', N'P') IS NULL
  THROW 52454, N'240: map.ImportSupplierProductCandidates ni nastala.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetSupplierProductCandidates')) NOT LIKE N'%SupplierTitle%'
  THROW 52455, N'240: intranet.GetSupplierProductCandidates ne vraca dobaviteljevega naziva.', 1;
