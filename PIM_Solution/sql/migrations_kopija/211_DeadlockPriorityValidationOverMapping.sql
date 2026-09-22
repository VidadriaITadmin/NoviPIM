/*
  211 — validacija/promocija ne sme vec biti vzrok, da preslikava izgubi podatke v zastoju.

  Vzrok napake iz 2026-09-15 (glej komentar v SqlMappingPipeline.cs, DeadlockRetries): urni
  "PIM katalog" (Katalog-cikel.ps1: EXEC val.RunValidation + EXEC val.Promote za eno podjetje) in
  petminutni "PIM zaloga" (SaopStockWorker -> SqlMappingPipeline.ExtractAndApplyAsync ->
  map.ProcessRawInbox) sta locena Windows opravila, ki smeta teci istocasno, in oba pisejo/berejo
  ista canon.* polja istega podjetja v razlicnem vrstnem redu (map.ProcessRawInbox stran po
  stran po vrstnem redu preslikanih zapisov, val.RunValidation/val.Promote v enem samem velikem
  stavku cez ves katalog). To je ucbeniski vzorec za SQL Server zastoj (deadlock): 2026-09-15 je
  tako 8 strani obticalo v karanteni in Vidadrii je manjkal VatRateId.

  Prvi poskus te migracije (glej git zgodovino te datoteke pred popravkom) je oba udelezenca pred
  pisanjem ustavil na skupni izkljucni kljucavnici (sys.sp_getapplock) - resitev je bila pravilna
  po nacelu, napacna po casu: izmerjeno na lokalni razvojni bazi (2026-09-15) val.RunValidation za
  eno samo podjetje (98.277 aktivnih izdelkov) traja VEC KOT 10 MINUT, kar se ujema s tem, da
  Sql.ps1 (PimUkaz, klice ga Zaloga-cikel.ps1 in Katalog-cikel.ps1) validaciji/promociji ze namenoma
  dovoljuje do 1800 sekund ("validacija+promote lahko traja"). Kljucavnica s katerokoli razumno
  mejo bi zato petminutni cikel zaloge/cen - ki mora po uporabnikovi zahtevi ostati zelo reden -
  obcasno ustavila tudi za pol ure; s prekratko mejo (180 s, prvi poskus) pa je namesto zastoja
  povzrocila enako karanteno, ki jo resuje (dokazano na lokalni bazi: tri strani Vidadrie so bile
  s to mejo lazno karantenirane, ne s pravim zastojem).

  Ta migracija namesto cakanja uporabi SET DEADLOCK_PRIORITY LOW v val.RunValidation in
  val.Promote. To zastoja ne prepreci (SQL Server ga se vedno odkrije), odloci pa vnaprej, kdo je
  vedno zrtev: ce pride do zastoja z map.ProcessRawInbox (privzeta, visja prioriteta), izgubi
  vedno validacija/promocija - ne preslikava. Posledica izgube je za obe strani ze znana in
  sprejemljiva: map.ProcessRawInbox tak neuspeh ne bo vec videl (ni vec njegov zastoj),
  val.RunValidation/val.Promote pa ob THROW iz CATCH bloka padeta enako kot ob katerikoli drugi
  napaki danes - Katalog-cikel.ps1 (oz. pim.SaveProductWebShops za posamezen izdelek) korak steje
  kot padel in poskusi znova (cez uro oziroma ob naslednjem shranjevanju). Brez cakanja, brez
  vpliva na petminutni ritem zaloge/cen.

  map.ProcessRawInbox NI spremenjen (privzeta prioriteta je ze tisto, kar potrebuje - da zmaga).
  Definicija spodaj ga kljub temu v celoti obnovi, ker je prvi (napacni) poskus te migracije med
  razvojem ze pognan na lokalni razvojni bazi in ji je sp_getapplock blok dodal - to ga povrne na
  isto besedilo, kot ga ima migracija 197, brez sledi napacnega poskusa.

  Migrator ne pozna locila GO (glej migracijo 061), zato so vse tri procedure v celoti zavite v
  EXEC(N'...').
*/

SET XACT_ABORT ON;

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
        165: ambientalna slika na drugo mesto. Uporabnik 2026-09-04: �dej tako da bo ambientalna
        slika na drugem mestu�. Nowodvorski vrsto slike poslje v image_<r>_type (�zdj�cie
        inspiracji� = ambientalna; �G��wne zdj�cie produktowe� = glavna; ostalo = galerija),
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

CREATE OR ALTER PROCEDURE val.RunValidation
  @OrganizationId int = NULL,
  @ProductId bigint = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 211: ob zastoju z map.ProcessRawInbox naj vedno izgubi validacija, ne preslikava - glej
     glavo migracije 211 za razlago, zakaj namesto cakanja na kljucavnico. */
  SET DEADLOCK_PRIORITY LOW;
  BEGIN TRY
    /* 147: obseg zahteve. Za vsak izdelek in vsak atribut, ki ga kaksna kategorija po verigi
       prednikov omenja, obvelja najblizja vrstica nabora (EXCLUDED pri otroku prekrije REQUIRED
       pri starsu). Zahteva z obsegom velja za izdelek, kadar je njena kategorija tista, kjer
       obveljala vrstica stoji, in raven ni EXCLUDED. */
    CREATE TABLE #Effective
      (ProductId bigint NOT NULL, CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       DefinedAtCategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       Level nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       PRIMARY KEY (ProductId, CategoryTreeCode, AttributeCode));

    ;WITH assigned AS
    (
      SELECT DISTINCT product.ProductId, node.CategoryTreeCode, node.CategoryCode, node.ParentCategoryCode
      FROM canon.Product AS product
      INNER JOIN canon.ProductCategory AS productCategory ON productCategory.ProductId = product.ProductId
      INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
      INNER JOIN canon.Category AS node
        ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath
      WHERE product.IsActive = 1
        AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
        AND (@ProductId IS NULL OR product.ProductId = @ProductId)
    ),
    chain AS
    (
      SELECT ProductId, CategoryTreeCode, CategoryCode, ParentCategoryCode, 0 AS Depth FROM assigned
      UNION ALL
      SELECT chain.ProductId, parent.CategoryTreeCode, parent.CategoryCode, parent.ParentCategoryCode, chain.Depth + 1
      FROM chain
      INNER JOIN canon.Category AS parent
        ON parent.CategoryTreeCode = chain.CategoryTreeCode AND parent.CategoryCode = chain.ParentCategoryCode
      WHERE chain.Depth < 12
    ),
    ranked AS
    (
      SELECT chain.ProductId, chain.CategoryTreeCode, setRow.AttributeCode, chain.CategoryCode AS DefinedAtCategoryCode, setRow.Level,
        ROW_NUMBER() OVER (PARTITION BY chain.ProductId, chain.CategoryTreeCode, setRow.AttributeCode ORDER BY chain.Depth) AS PickRank
      FROM chain
      INNER JOIN canon.CategoryAttributeSet AS setRow
        ON setRow.CategoryTreeCode = chain.CategoryTreeCode AND setRow.CategoryCode = chain.CategoryCode AND setRow.IsActive = 1
    )
    INSERT #Effective (ProductId, CategoryTreeCode, AttributeCode, DefinedAtCategoryCode, Level)
    SELECT ProductId, CategoryTreeCode, AttributeCode, DefinedAtCategoryCode, Level FROM ranked WHERE PickRank = 1;

    /* Zahteva z obsegom -> koda atributa v registru (zahteva nosi slovensko ime). */
    CREATE TABLE #ScopedRequirement
      (FieldRequirementId int NOT NULL PRIMARY KEY, CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #ScopedRequirement (FieldRequirementId, CategoryTreeCode, CategoryCode, AttributeCode)
    SELECT requirement.FieldRequirementId, requirement.CategoryTreeCode, requirement.CategoryCode, definition.AttributeCode
    FROM val.FieldRequirement AS requirement
    INNER JOIN canon.AttributeDefinition AS definition
      ON CONCAT(N''ProductAttribute.'', COALESCE(
           (SELECT TOP (1) Name FROM canon.AttributeTranslation WHERE AttributeCode = definition.AttributeCode AND LanguageCode = N''sl''),
           definition.AttributeCode)) = requirement.FieldCode
    WHERE requirement.CategoryCode IS NOT NULL;

    BEGIN TRANSACTION;
    ;WITH RequiredField AS
    (
      SELECT product.ProductId, profile.ValidationProfileId, requirement.FieldRequirementId, requirement.FieldCode
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId
      WHERE product.IsActive = 1 AND profile.IsActive = 1 AND requirement.IsActive = 1 AND requirement.IsRequired = 1
        AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
        AND (@ProductId IS NULL OR product.ProductId = @ProductId)
        /* 182: spletni profil velja samo za izdelek, ki je za to spletisce oznacen v PIM.
           Prej je CROSS JOIN vsak profil pripel na vsak izdelek, zato sta spletna profila
           odpirala napake tudi na 162.000 izdelkih, ki na splet sploh ne gredo. */
        AND (profile.Scope <> N''WEB'' OR EXISTS
          (SELECT 1 FROM pim.ProductWebShop shop
           WHERE shop.ProductId = product.ProductId
             AND shop.WebShopCode = profile.CategoryTreeCode
             AND shop.IsPublished = 1))
        AND (requirement.CategoryCode IS NULL OR EXISTS
          (SELECT 1 FROM #ScopedRequirement scoped
           INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
             AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
             AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
           WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
    ), MissingField AS
    (
      SELECT requiredField.*
      FROM RequiredField requiredField
      WHERE NOT EXISTS
      (
        SELECT 1 FROM canon.FieldValue fieldValue
        WHERE fieldValue.ProductId = requiredField.ProductId
          AND fieldValue.FieldCode = requiredField.FieldCode
          AND NULLIF(fieldValue.Value, N'''') IS NOT NULL
      )
    )
    MERGE val.ProductIssue AS target
    USING MissingField AS source
    ON target.ProductId = source.ProductId AND target.FieldRequirementId = source.FieldRequirementId
    WHEN MATCHED THEN UPDATE SET ValidationProfileId = source.ValidationProfileId, IssueCode = N''MISSING_REQUIRED_FIELD'', Message = CONCAT(N''Manjka obvezno polje: '', source.FieldCode), IsActive = 1, LastDetectedUtc = SYSUTCDATETIME(), ResolvedUtc = NULL
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, FieldRequirementId, IssueCode, Message) VALUES (source.ProductId, source.ValidationProfileId, source.FieldRequirementId, N''MISSING_REQUIRED_FIELD'', CONCAT(N''Manjka obvezno polje: '', source.FieldCode));

    UPDATE issue SET IsActive = 0, ResolvedUtc = SYSUTCDATETIME()
    FROM val.ProductIssue issue
    INNER JOIN canon.Product product ON product.ProductId = issue.ProductId
    INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = issue.ValidationProfileId
    WHERE issue.IsActive = 1
      AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND (@ProductId IS NULL OR product.ProductId = @ProductId)
      /* 182: napaka se zapre tudi takrat, ko profil za ta izdelek ne velja vec — brez tega bi
         obstojece spletne napake ostale odprte, ceprav izdelek na to spletisce ne gre. */
      AND (NOT (profile.Scope <> N''WEB'' OR EXISTS
            (SELECT 1 FROM pim.ProductWebShop shop
             WHERE shop.ProductId = product.ProductId
               AND shop.WebShopCode = profile.CategoryTreeCode
               AND shop.IsPublished = 1))
      OR NOT EXISTS
      (
        SELECT 1 FROM val.FieldRequirement requirement
        WHERE requirement.FieldRequirementId = issue.FieldRequirementId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
          AND (requirement.CategoryCode IS NULL OR EXISTS
            (SELECT 1 FROM #ScopedRequirement scoped
             INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
               AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
               AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
             WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
          AND NOT EXISTS (SELECT 1 FROM canon.FieldValue fieldValue WHERE fieldValue.ProductId = product.ProductId AND fieldValue.FieldCode = requirement.FieldCode AND NULLIF(fieldValue.Value, N'''') IS NOT NULL)
      ));

    ;WITH ProfileScore AS
    (
      SELECT product.ProductId, profile.ValidationProfileId,
        CAST(100.0 * (COUNT(requirement.FieldRequirementId) - SUM(CASE WHEN issue.ProductIssueId IS NULL THEN 0 ELSE 1 END)) / NULLIF(COUNT(requirement.FieldRequirementId), 0) AS decimal(5,2)) AS Completeness,
        CASE WHEN SUM(CASE WHEN issue.ProductIssueId IS NOT NULL AND requirement.Severity = N''ERROR'' THEN 1 ELSE 0 END) = 0
          THEN N''VALID'' ELSE N''INVALID'' END AS Status
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
        AND (requirement.CategoryCode IS NULL OR EXISTS
          (SELECT 1 FROM #ScopedRequirement scoped
           INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
             AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
             AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
           WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
      LEFT JOIN val.ProductIssue issue ON issue.ProductId = product.ProductId AND issue.FieldRequirementId = requirement.FieldRequirementId AND issue.IsActive = 1
      WHERE product.IsActive = 1 AND profile.IsActive = 1
        AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
        AND (@ProductId IS NULL OR product.ProductId = @ProductId)
        AND (profile.Scope <> N''WEB'' OR EXISTS
          (SELECT 1 FROM pim.ProductWebShop shop
           WHERE shop.ProductId = product.ProductId
             AND shop.WebShopCode = profile.CategoryTreeCode
             AND shop.IsPublished = 1))
        GROUP BY product.ProductId, profile.ValidationProfileId
    )
    MERGE val.ProductValidationState AS target
    USING ProfileScore AS source ON target.ProductId = source.ProductId AND target.ValidationProfileId = source.ValidationProfileId
    WHEN MATCHED THEN UPDATE SET Status = source.Status, Completeness = source.Completeness, ValidatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, Status, Completeness, ValidatedUtc) VALUES (source.ProductId, source.ValidationProfileId, source.Status, source.Completeness, SYSUTCDATETIME());

    UPDATE product
    SET ValidationStatus =
        CASE WHEN EXISTS
        (
          SELECT 1 FROM val.ProductIssue issue
          INNER JOIN val.FieldRequirement requirement ON requirement.FieldRequirementId = issue.FieldRequirementId
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = issue.ValidationProfileId
          WHERE issue.ProductId = product.ProductId AND issue.IsActive = 1
            AND requirement.Severity = N''ERROR''
            AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
            /* 182: profil, ki za ta izdelek ne velja, ne sme dolocati njegovega stanja. */
            AND (profile.Scope <> N''WEB'' OR EXISTS
              (SELECT 1 FROM pim.ProductWebShop shop
               WHERE shop.ProductId = product.ProductId
                 AND shop.WebShopCode = profile.CategoryTreeCode
                 AND shop.IsPublished = 1))
        ) THEN N''INVALID'' ELSE N''VALID'' END,
        Completeness = ISNULL
        ((
          SELECT MIN(state.Completeness) FROM val.ProductValidationState state
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = state.ValidationProfileId
          WHERE state.ProductId = product.ProductId AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
            AND (profile.Scope <> N''WEB'' OR EXISTS
              (SELECT 1 FROM pim.ProductWebShop shop
               WHERE shop.ProductId = product.ProductId
                 AND shop.WebShopCode = profile.CategoryTreeCode
                 AND shop.IsPublished = 1))
        ), 0),
        LastValidatedUtc = SYSUTCDATETIME()
    FROM canon.Product product
    WHERE product.IsActive = 1
      AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND (@ProductId IS NULL OR product.ProductId = @ProductId);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    EXEC ops.LogError @Layer = N''val'', @Severity = N''Error'', @ErrorCode = N''RUN_VALIDATION_FAILED'', @Message = @ErrorMessage;
    THROW;
  END CATCH;
END;
');

EXEC(N'

CREATE OR ALTER PROCEDURE val.Promote
  @OrganizationId int = NULL,
  @ValidationProfileCode nvarchar(100) = N''ERP_L1''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 211: enako kot val.RunValidation - ob zastoju z map.ProcessRawInbox naj izgubi promocija,
     ne preslikava. val.Promote spodaj samo BERE canon.* (za MERGE vir v pim.*), a prav dolg
     SELECT prek vec canon.* tabel v enem stavku je bil del istega zastoja - glej glavo
     migracije 211. */
  SET DEADLOCK_PRIORITY LOW;
  BEGIN TRY
    BEGIN TRANSACTION;

    /* Kateri artikli so upraviceni do objave po izbranem profilu. */
    DECLARE @Eligible TABLE(ProductId bigint PRIMARY KEY, OrganizationId int, ItemID nvarchar(200));
    INSERT @Eligible(ProductId, OrganizationId, ItemID)
    SELECT product.ProductId, product.OrganizationId, product.ItemID
    FROM canon.Product product
    INNER JOIN val.ProductValidationState validationState ON validationState.ProductId = product.ProductId
    INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = validationState.ValidationProfileId
    WHERE profile.ProfileCode = @ValidationProfileCode AND validationState.Status = N''VALID''
      AND product.IsActive = 1 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId);

    MERGE pim.Product AS target
    USING
    (
      SELECT e.ProductId, e.OrganizationId, e.ItemID, product.EAN, product.Manufacturer,
             product.Supplier, product.UoM,
             /*
               Naziv: spletni, ce obstaja, sicer ERP naziv v istem jeziku. Do 074 je bil pogoj
               samo WEB_TITLE in ker spletnih nazivov (se) ni, je pim.Product.Name ostal NULL pri
               vseh izdelkih — stolpec ''Naziv artikla'' v izvozu je bil zato prazen, ceprav naziv
               obstaja. Prazno ime ni resnica; ERP naziv je.
             */
             COALESCE(
               (SELECT TOP (1) textValue.Value FROM canon.ProductText textValue
                WHERE textValue.ProductId = e.ProductId AND textValue.TextType = N''WEB_TITLE'' AND textValue.Lang = N''sl''),
               (SELECT TOP (1) textValue.Value FROM canon.ProductText textValue
                WHERE textValue.ProductId = e.ProductId AND textValue.TextType = N''TITLE_ERP'' AND textValue.Lang = N''sl'')
             ) AS Name
      FROM @Eligible e
      INNER JOIN canon.Product product ON product.ProductId = e.ProductId
    ) AS source ON target.OrganizationId = source.OrganizationId AND target.ItemID = source.ItemID
    WHEN MATCHED THEN UPDATE SET EAN = source.EAN, Name = source.Name, Manufacturer = source.Manufacturer,
      Supplier = source.Supplier, UoM = source.UoM, PromotedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (OrganizationId, ItemID, EAN, Name, Manufacturer, Supplier, UoM)
      VALUES (source.OrganizationId, source.ItemID, source.EAN, source.Name, source.Manufacturer,
              source.Supplier, source.UoM);

    /*
      Novost 058: objava ni bila koncana. val.Promote je do zdaj zapisala samo glavo izdelka,
      pim.ProductText, pim.ProductPrice, pim.ProductMedia, pim.ProductCategory,
      pim.ProductAttribute in pim.ProductCommercial pa so ostale prazne — vseh sest je imelo
      0 vrstic. Magento izvoz bere prav te tabele, zato bi izvozil skoraj prazne vrstice.

      Spodaj je za vsako otrosko tabelo isti vzorec: preberi iz canon za objavljene izdelke in
      uskladi z MERGE po naravnem kljucu.

      Kar to NAMENOMA se ne naredi: ne brise vrstic, ki so v pim, v canon pa jih ni vec.
      Brisanje je na zaprtem seznamu pravil in zahteva odlocitev cloveka; do takrat lahko v
      objavljenem sloju ostane zapis, ki je bil v katalogu odstranjen. Pri cenah to ni
      problem, ker ima pim.ProductPrice IsActive.
    */
    DECLARE @Objavljeni TABLE(PimProductId bigint PRIMARY KEY, ProductId bigint);
    INSERT @Objavljeni(PimProductId, ProductId)
    SELECT pimProduct.PimProductId, e.ProductId
    FROM @Eligible e
    INNER JOIN pim.Product pimProduct ON pimProduct.OrganizationId = e.OrganizationId AND pimProduct.ItemID = e.ItemID;

    MERGE pim.ProductText AS target
    USING
    (
      SELECT o.PimProductId, t.Lang, t.TextType, t.Value
      FROM @Objavljeni o INNER JOIN canon.ProductText t ON t.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.Lang = source.Lang AND target.TextType = source.TextType
    WHEN MATCHED THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (PimProductId, Lang, TextType, Value)
      VALUES (source.PimProductId, source.Lang, source.TextType, source.Value);

    MERGE pim.ProductPrice AS target
    USING
    (
      SELECT o.PimProductId, p.PriceList, p.Net, p.VatRate, p.ValidFrom, p.IsActive
      FROM @Objavljeni o INNER JOIN canon.ProductPrice p ON p.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.PriceList = source.PriceList AND target.ValidFrom = source.ValidFrom
    WHEN MATCHED THEN UPDATE SET Net = source.Net, VatRate = source.VatRate, IsActive = source.IsActive
    WHEN NOT MATCHED THEN INSERT (PimProductId, PriceList, Net, VatRate, ValidFrom, IsActive)
      VALUES (source.PimProductId, source.PriceList, source.Net, source.VatRate, source.ValidFrom, source.IsActive);

    MERGE pim.ProductMedia AS target
    USING
    (
      SELECT o.PimProductId, m.Url, m.Role, m.SortOrder
      FROM @Objavljeni o INNER JOIN canon.ProductMedia m ON m.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.Role = source.Role AND target.SortOrder = source.SortOrder
    WHEN MATCHED THEN UPDATE SET Url = source.Url
    WHEN NOT MATCHED THEN INSERT (PimProductId, Url, Role, SortOrder)
      VALUES (source.PimProductId, source.Url, source.Role, source.SortOrder);

    MERGE pim.ProductCategory AS target
    USING
    (
      SELECT o.PimProductId, c.WebSite, c.CategoryPath
      FROM @Objavljeni o INNER JOIN canon.ProductCategory c ON c.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.WebSite = source.WebSite AND target.CategoryPath = source.CategoryPath
    WHEN NOT MATCHED THEN INSERT (PimProductId, WebSite, CategoryPath)
      VALUES (source.PimProductId, source.WebSite, source.CategoryPath);

    MERGE pim.ProductAttribute AS target
    USING
    (
      /*
        124: jezik je odslej stolpec, ne del imena. Brez njega bi ista lastnost v dveh jezikih
        dala dve izvorni vrstici za isti cilj in MERGE bi padel z napako 8672.
      */
      SELECT o.PimProductId, a.AttributeCode, a.LanguageCode, a.Value
      FROM @Objavljeni o INNER JOIN canon.ProductAttribute a ON a.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.AttributeCode = source.AttributeCode
      AND ISNULL(target.LanguageCode, N''~'') = ISNULL(source.LanguageCode, N''~'')
    WHEN MATCHED THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (PimProductId, AttributeCode, LanguageCode, Value)
      VALUES (source.PimProductId, source.AttributeCode, source.LanguageCode, source.Value);

    MERGE pim.ProductCommercial AS target
    USING
    (
      /*
        Volumen, mere pakiranja in enota so v katalogu od migracije 057, v objavi pa jih do 075
        ni bilo — objava je nesla samo tisto, kar je tabela poznala prej. Izvoz bere objavo, zato
        so stolpci predloge ostali prazni, ceprav podatek obstaja pri 196.513 izdelkih.
      */
      SELECT o.PimProductId, k.NetWeight, k.GrossWeight, k.CustomsTariff, k.CountryOfOrigin, k.Pak1, k.Pak2, k.Dimensions,
             k.Volume, k.PackageLength, k.PackageWidth, k.PackageHeight, k.DimensionUnit
      FROM @Objavljeni o INNER JOIN canon.ProductCommercial k ON k.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId
    WHEN MATCHED THEN UPDATE SET NetWeight = source.NetWeight, GrossWeight = source.GrossWeight,
      CustomsTariff = source.CustomsTariff, CountryOfOrigin = source.CountryOfOrigin,
      Pak1 = source.Pak1, Pak2 = source.Pak2, Dimensions = source.Dimensions,
      Volume = source.Volume, PackageLength = source.PackageLength, PackageWidth = source.PackageWidth,
      PackageHeight = source.PackageHeight, DimensionUnit = source.DimensionUnit
    WHEN NOT MATCHED THEN INSERT (PimProductId, NetWeight, GrossWeight, CustomsTariff, CountryOfOrigin, Pak1, Pak2, Dimensions,
                                  Volume, PackageLength, PackageWidth, PackageHeight, DimensionUnit)
      VALUES (source.PimProductId, source.NetWeight, source.GrossWeight, source.CustomsTariff, source.CountryOfOrigin,
              source.Pak1, source.Pak2, source.Dimensions,
              source.Volume, source.PackageLength, source.PackageWidth, source.PackageHeight, source.DimensionUnit);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
  END CATCH;
END;
');

IF OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox')) LIKE N'%catalog-write%'
  THROW 53012, N'211: map.ProcessRawInbox se vsebuje sled prvega (opuscenega) poskusa te migracije.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidation')) NOT LIKE N'%DEADLOCK_PRIORITY LOW%'
  THROW 53013, N'211: val.RunValidation ne nastavi DEADLOCK_PRIORITY LOW.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'val.Promote')) NOT LIKE N'%DEADLOCK_PRIORITY LOW%'
  THROW 53014, N'211: val.Promote ne nastavi DEADLOCK_PRIORITY LOW.', 1;
