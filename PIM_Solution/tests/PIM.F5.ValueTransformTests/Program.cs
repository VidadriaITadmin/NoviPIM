using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.XmlMapping;

// Dokaz za migracijo 048: pretvorbe (map.FieldTransform) in slovar vrednosti
// (map.ValueLookup) delujejo na pravi bazi, na poti od dobaviteljevega XML do
// canon.ProductAttribute. Test si naredi svoj konektor in ga na koncu pobriše,
// zato v registru ne pusti ničesar.
//
// Zakaj ravno ti primeri: vsak je oblika, ki jo je bilo treba v resnici rešiti.
//   "30 mm"      Braytron pošlje vrednost in enoto skupaj, predloga ima dva stolpca
//   "Dimmable"   Da/Ne kot besedilo, izvoz hoče 1/0
//   "203"        NW šifra, ki jo ločimo od naših s predpono
//   " CLASS II"  isti dobavitelj piše isto stvar na več načinov
//   "black"      prevod je odvisen od lastnosti (barva je ženskega spola)
//   "F5 galvanised probe"  prevod, ki velja povsod (domena *)
//   "sploh ni v slovarju"  manjkajoč prevod ni napaka, ampak delovni seznam

const int organizationId = 2;
const string sourceCode = "F5_TRANSFORM";
const string entityType = "TransformProbe";
const string itemId = "F5-TRANSFORM-PROBE";
const string ean = "9999900000048";
const string unknownValue = "F5 vrednost brez prevoda";

// Brez nastavljene povezave se preskoci, ne pade (glej isti popravek v F2/F3/F5/F8/F9):
// padec je pomenil, da je paket na racunalniku brez razvojne baze videti pokvarjen.
// Kjer je povezava nastavljena, dokaz tece kot prej.
var connectionString = ReadConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("F5 pretvorbe preskocene: manjka razvojna povezava Pim.");
  return 0;
}
var builder = new SqlConnectionStringBuilder(connectionString);
if (!string.Equals(builder.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase) || !builder.IntegratedSecurity)
  throw new InvalidOperationException("Test se sme zaganjati samo z Windows Integrated Auth v bazi PIM.");

var payload = $"""
  <feed><product>
    <item>{itemId}</item>
    <ean>{ean}</ean>
    <size>30 mm</size>
    <dim>Not-Dimmable</dim>
    <sym>203</sym>
    <cls> CLASS II</cls>
    <col>black</col>
    <mat>F5 galvanised probe</mat>
    <unk>{unknownValue}</unk>
  </product></feed>
  """;

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
// Test pise v iste tabele kot ostali F5 testi z bazo (org, NW_XML, canon.*, map.*). Ko vrata tecejo
// vzporedno, ga je SQL ubil kot zrtev deadlocka 1205 (naloga #104). Enako ime vira kot v
// PIM.F5.Integration ga postavi v vrsto; zaklep seje se sprosti ob zaprtju povezave.
await using (var applock = Command(connection, """
  DECLARE @Result int;
  EXEC @Result = sp_getapplock @Resource=N'PIM.F5.Integration', @LockMode=N'Exclusive', @LockOwner=N'Session', @LockTimeout=900000;
  SELECT @Result;
  """))
{
  applock.CommandTimeout = 960;
  var lockResult = Convert.ToInt32(await applock.ExecuteScalarAsync());
  if (lockResult < 0)
    throw new InvalidOperationException($"F5 vrednosti: drug zagon F5 drzi bazo ze 15 min (sp_getapplock={lockResult}). Pocakaj, da konca, in ponovi.");
}
await CleanupAsync(connection);
try
{
  await SeedProductAsync(connection);
  await SeedRegistryAsync(connection);

  var firstRun = Guid.NewGuid();
  await InsertInboxAsync(connection, firstRun, payload);
  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(firstRun, organizationId, sourceCode);

  Equal("Processed", await ScalarAsync<string>(connection,
    "SELECT Status FROM raw.Inbox WHERE RunId=@RunId;", ("@RunId", firstRun)),
    "Paket se ni dokončal.");

  Equal("30", await AttributeAsync(connection, "F5 Visina"), "NUMBER ni izluščil števila iz \"30 mm\".");
  Equal("mm", await AttributeAsync(connection, "F5 Enota visine"), "UNIT ni izluščil enote iz \"30 mm\".");
  Equal("0", await AttributeAsync(connection, "F5 Zatemnljivo"), "BOOL ni pretvoril \"Not-Dimmable\" v 0.");
  Equal("NW.203", await AttributeAsync(connection, "F5 Simbol"), "PREFIX ni pripel predpone.");
  Equal("II", await AttributeAsync(connection, "F5 Razred"), "TRIM + STRIPPREFIX nista poenotila \" CLASS II\".");
  // Od 314 (#49) zajem vrednost še lepo zapiše: prevod »črna« dobi veliko začetnico (čisto besedilo).
  Equal("Črna", await AttributeAsync(connection, "F5 Barva SLO"), "LOOKUP ni uporabil prevoda za lastnost (ali zajem ni lepo zapisal vrednosti).");
  // Splošni prevod (domena *) ima svojo testno vrednost: živi slovar ima od uvoza »Prevajalna tabela.xlsx«
  // za »galvanised steel« že »Cinkano jeklo«, zato se test ne sme opirati na resnične vrstice slovarja (#15).
  Equal("f5 cinkano jeklo", await AttributeAsync(connection, "F5 Material SLO"), "LOOKUP ni uporabil splošnega prevoda.");
  Equal(unknownValue, await AttributeAsync(connection, "F5 Neznano SLO"), "Manjkajoč prevod ni pustil vrednosti pri miru.");

  // Izvorna vrednost se ne izgubi: Value nosi pretvorjeno, RawValue izvorno.
  Equal("30 mm", await ScalarAsync<string>(connection, """
    SELECT TOP(1) value.RawValue FROM map.ExtractedValue value
    INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
    WHERE inbox.RunId=@RunId AND value.TargetFieldCode=N'ProductAttribute.F5 Visina';
    """, ("@RunId", firstRun)), "RawValue ne hrani izvorne vrednosti.");

  Equal(1, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM map.MissingTranslation
    WHERE Domain=N'F5 Neznano SLO' AND Language=N'SL' AND SourceValue=@Value;
    """, ("@Value", unknownValue)), "Manjkajoč prevod ni pristal na delovnem seznamu.");

  Equal(0, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM map.MissingTranslation
    WHERE Domain LIKE N'F5 %' AND SourceValue IN (N'black', N'F5 galvanised probe');
    """), "Prevedena vrednost je pristala med manjkajočimi.");

  // Trditvi sta omejeni na domene tega testa. Odkar so vpisane resnicne preslikave
  // (054, 055), je map.MissingTranslation zivo delovno kazalo: 'Black' se v njem
  // pojavi kot resnicno manjkajoc prevod pri 'Prevladujoca barva SLO' in globalna
  // trditev bi padla zaradi tujega, pravilnega zapisa.
  // Regresija za 056: seznam manjkajočih se je pisal po tem, ko je bil prevod že uveljavljen,
  // zato je vanj pristal prevod sam ('črna' namesto 'black') in seznam je kazal delo, ki je
  // bilo opravljeno. Beleži se lahko samo izvirnik, in še ta le, kadar prevoda res ni.
  Equal(0, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM map.MissingTranslation
    WHERE Domain LIKE N'F5 %' AND SourceValue IN (N'črna', N'f5 cinkano jeklo');
    """), "Med manjkajočimi je pristal prevod, ne izvirnik.");

  // Ponovljen klic postopka nad istimi vrsticami ne sme pretvarjati drugic (NW.NW.203).
  await ExecuteAsync(connection, "EXEC map.ApplyValueTransforms @RunId,@OrganizationId,@SourceCode;",
    ("@RunId", firstRun), ("@OrganizationId", organizationId), ("@SourceCode", sourceCode));
  Equal("NW.203", await ScalarAsync<string>(connection, """
    SELECT TOP(1) value.Value FROM map.ExtractedValue value
    INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
    WHERE inbox.RunId=@RunId AND value.TargetFieldCode=N'ProductAttribute.F5 Simbol';
    """, ("@RunId", firstRun)), "Ponoven klic postopka je predpono pripel dvakrat.");

  // Ista vsebina na naslednji strani: zajem tece znova od zacetka in mora dati isto.
  var secondRun = Guid.NewGuid();
  await InsertInboxAsync(connection, secondRun, payload, 2);
  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(secondRun, organizationId, sourceCode);
  Equal("NW.203", await AttributeAsync(connection, "F5 Simbol"), "Drugi zajem je predpono pripel dvakrat.");
  Equal(2, await ScalarAsync<int>(connection, """
    SELECT SeenCount FROM map.MissingTranslation
    WHERE Domain=N'F5 Neznano SLO' AND Language=N'SL' AND SourceValue=@Value;
    """, ("@Value", unknownValue)), "Števec manjkajočega prevoda se ni povečal.");

  Console.WriteLine("F5 value transform: NUMBER, UNIT, BOOL, PREFIX, TRIM+STRIPPREFIX, LOOKUP (lastnost in splošno), manjkajoč prevod in ponoven zagon PASS.");
}
finally
{
  await CleanupAsync(connection);
}

// #15 (307) + #49 (314, 316): lep zapis vrednosti je vklopljen v zajem in katalog.csv.
if (await ScalarAsync<int>(connection, "SELECT CASE WHEN OBJECT_ID(N'pim.PolishAttributeValue', N'FN') IS NULL THEN 0 ELSE 1 END;") == 1)
{
  foreach (var (attribute, input, expected) in new[]
  {
    ("Dolžina kabla", "do 30m", "do 30 m"),
    ("Dolžina kabla", "do 30 m", "do 30 m"),
    ("Dolžina kabla", "50m", "50 m"),
    ("Dolžina kabla", "30 - 50m", "30-50 m"),
    ("IP stopnja zaščite", "IP44", "IP44"),
    ("Enota", "mm", "mm"),
    ("Vrsta svetlobnega vira", "LED", "LED"),
    ("Barva svetlobe", "toplo bela", "Toplo bela"),
    ("SEKUNDARNAMERSKAENOTA", "kom", "kom"),
    ("Napetost", "~220-30", "~220-230"),
    ("CRI", "≥ 80", "≥80"),
    ("Max moč sijalke", "2x5W", "2x5 W"),
    ("Max moč sijalke", "10W", "10 W"),
    ("Ikone", "3CCT,IP65", "3CCT, IP65"),
    ("Širina", "1,5", "1.5"),
    // 314: vejica pred enoto — prej je drugi klic spet spremenil »…,6600mAh«.
    ("Baterija", "Li-Ion,Battery 18650 3.7V,6600mAh", "Li-Ion, Battery 18650 3.7 V, 6600 mAh"),
    ("Ikone", "TOUCH,DIMMABLE,5000K", "TOUCH, DIMMABLE, 5000 K"),
    // 314: polje, ki gre v SAOP (out.SaopXmlField), ostane, kot ga vrne 291 — lastnik: nič SAOP.
    ("Garancija", "OSRAM GU10,DIMM, 8.3W,3.000K,C", "OSRAM GU10,DIMM, 8.3W,3.000K,C"),
    // 316: spremljevalni atributi enot niso besedilo.
    ("Enota bruto teže (2)", "kgs", "kgs"),
  })
  {
    var once = await ScalarAsync<string>(connection, "SELECT pim.PolishAttributeValue(@Attribute, @Input);", ("@Attribute", attribute), ("@Input", input));
    Equal(expected, once, $"Lep zapis za »{input}« ({attribute}).");
    // Stabilnost: drugi klic ne sme spremeniti ničesar, sicer bi vsak zajem/izvoz spet spreminjal isto vrednost.
    Equal(once, await ScalarAsync<string>(connection, "SELECT pim.PolishAttributeValue(@Attribute, @Input);", ("@Attribute", attribute), ("@Input", once)),
      $"Lep zapis ni stabilen za »{once}« ({attribute}).");
  }

  // Zajem in izvoz kličeta lep zapis (314), starega klica 291 ni več; validacija ga ne kliče.
  Equal(3, await ScalarAsync<int>(connection, """
    SELECT CONVERT(int, (DATALENGTH(d.Transforms) - DATALENGTH(REPLACE(d.Transforms, N'pim.PolishAttributeValue(', N''))) / DATALENGTH(N'pim.PolishAttributeValue(')
         + (DATALENGTH(d.Export) - DATALENGTH(REPLACE(d.Export, N'pim.PolishAttributeValue(', N''))) / DATALENGTH(N'pim.PolishAttributeValue('))
    FROM (SELECT OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms')) AS Transforms, OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) AS Export) AS d;
    """), "Zajem (2 klica) in izvoz katalog.csv (1 klic) morata klicati pim.PolishAttributeValue (314).");
  Equal(0, await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM sys.sql_modules
    WHERE object_id IN (OBJECT_ID(N'map.ApplyValueTransforms'), OBJECT_ID(N'out.GetExportRows'))
      AND definition LIKE N'%NormalizeAttributeValue%';
    """), "Zajem in izvoz ne smeta več klicati samo pravila 291 (dva zapisa iste vrednosti na spletu).");

  // Izjema iz slovarja ENOTNO in povratek: vse v transakciji, ki se prekliče (slovar in podatki ostanejo).
  await using (var transaction = (SqlTransaction)await connection.BeginTransactionAsync())
  {
    async Task<string> InTransactionAsync(string sql, params (string Name, object Value)[] parameters)
    {
      await using var command = new SqlCommand(sql, connection, transaction);
      foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
      return Convert.ToString(await command.ExecuteScalarAsync()) ?? "";
    }

    // »5000k« -> slovar »5000K« ne sme postati »5000 K«.
    await InTransactionAsync("""
      INSERT map.ValueLookup (Domain, SourceValue, Language, TargetValue, Note, IsActive)
      VALUES (N'F5 Ikone lepi', N'5000k', N'ENOTNO', N'5000K', N'F5 #49: izjema', 1);
      SELECT 1;
      """);
    Equal("5000K", await InTransactionAsync("SELECT pim.PolishAttributeValue(N'F5 Ikone lepi', N'5000k');"),
      "Izjema iz slovarja ENOTNO mora obveljati tudi po lepem zapisu.");
    Equal("5000 K", await InTransactionAsync("SELECT pim.PolishAttributeValue(N'F5 Ikone drugi', N'5000K');"),
      "Brez izjeme dobi enota presledek.");

    // Povratek vrne prvotno vrednost samo, kjer je vrednost še enaka zapisani »potem«.
    var rowId = long.Parse(await InTransactionAsync(
      "SELECT TOP (1) CONVERT(nvarchar(30), PimProductAttributeId) FROM pim.ProductAttribute WHERE Value IS NOT NULL ORDER BY PimProductAttributeId;"));
    const string valueSql = "SELECT Value FROM pim.ProductAttribute WHERE PimProductAttributeId = @Id;";
    var current = await InTransactionAsync(valueSql, ("@Id", rowId));
    var tag = "F5 povratek " + Guid.NewGuid().ToString("N")[..8];
    await InTransactionAsync("""
      INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedBy)
      SELECT N'pim.ProductAttribute', a.PimProductAttributeId, p.OrganizationId, p.ItemID, a.AttributeCode, a.LanguageCode, N'F5 prej', a.Value, @Tag
      FROM pim.ProductAttribute a JOIN pim.Product p ON p.PimProductId = a.PimProductId WHERE a.PimProductAttributeId = @Id;
      SELECT 1;
      """, ("@Id", rowId), ("@Tag", tag));
    const string revertSql = """
      DECLARE @r TABLE (Candidates int, CanonReverted int, PimReverted int, Skipped int, DryRun bit);
      INSERT @r EXEC pim.RevertAttributeValueNormalization @Tag, N'F5', @DryRun;
      SELECT PimReverted FROM @r;
      """;
    Equal("1", await InTransactionAsync(revertSql, ("@Tag", tag), ("@DryRun", true)), "Suhi tek povratka mora najti eno vrstico.");
    Equal(current, await InTransactionAsync(valueSql, ("@Id", rowId)), "Suhi tek povratka ne sme ničesar spremeniti.");
    Equal("1", await InTransactionAsync(revertSql, ("@Tag", tag), ("@DryRun", false)), "Povratek mora vrniti eno vrstico.");
    Equal("F5 prej", await InTransactionAsync(valueSql, ("@Id", rowId)), "Povratek ni vrnil prvotne vrednosti.");
    Equal("1", await InTransactionAsync("SELECT COUNT(*) FROM pim.AttributeValueNormalizationLog WHERE ChangedBy = N'povratek ' + @Tag + N' (F5)';", ("@Tag", tag)),
      "Povratek mora zapisati dnevnik.");
    Equal("0", await InTransactionAsync(revertSql, ("@Tag", tag), ("@DryRun", false)),
      "Drugi povratek ne sme spremeniti vrednosti, ki ni več enaka »potem«.");
    await transaction.RollbackAsync();
  }
  Console.WriteLine("F5 lep zapis (307/314/316): primeri, stabilnost, SAOP polja, enote, izjeme ENOTNO, zajem+izvoz in povratek PASS.");
}
return 0;

async Task SeedProductAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    INSERT canon.Product(OrganizationId,ItemID,EAN,Manufacturer,UoM)
    VALUES(@OrganizationId,@ItemID,@EAN,N'F5 maker',N'kos');
    """, ("@OrganizationId", organizationId), ("@ItemID", itemId), ("@EAN", ean));
}

async Task SeedRegistryAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    INSERT map.SourceConnector(SourceCode,OrganizationId,ConnectorType,IsActive)
    VALUES(@SourceCode,@OrganizationId,N'FILE_XML',1);
    DECLARE @ConnectorId int=SCOPE_IDENTITY();
    INSERT map.EntityMapping(SourceConnectorId,EntityType,RecordXPath,IsActive)
    VALUES(@ConnectorId,@EntityType,N'/feed/product',1);

    DECLARE @Mapping TABLE(Code nvarchar(200) PRIMARY KEY, FieldMappingId int NOT NULL);
    MERGE map.FieldMapping AS target
    USING (VALUES
      (N'item/text()', N'Product.ItemID'),
      (N'ean/text()',  N'Product.EAN'),
      (N'size/text()', N'ProductAttribute.F5 Visina'),
      (N'size/text()', N'ProductAttribute.F5 Enota visine'),
      (N'dim/text()',  N'ProductAttribute.F5 Zatemnljivo'),
      (N'sym/text()',  N'ProductAttribute.F5 Simbol'),
      (N'cls/text()',  N'ProductAttribute.F5 Razred'),
      (N'col/text()',  N'ProductAttribute.F5 Barva SLO'),
      (N'mat/text()',  N'ProductAttribute.F5 Material SLO'),
      (N'unk/text()',  N'ProductAttribute.F5 Neznano SLO')
    ) AS source(SourceElement, TargetFieldCode)
      ON 1=0
    WHEN NOT MATCHED THEN
      INSERT(SourceConnectorId,EntityType,SourceElement,TargetFieldCode,IsRequired,IsActive,MappingVersion)
      VALUES(@ConnectorId,@EntityType,source.SourceElement,source.TargetFieldCode,0,1,1)
    OUTPUT inserted.TargetFieldCode, inserted.FieldMappingId INTO @Mapping(Code, FieldMappingId);

    INSERT map.FieldTransform(FieldMappingId,StepOrder,TransformCode,Argument)
    SELECT mapping.FieldMappingId, step.StepOrder, step.TransformCode, step.Argument
    FROM (VALUES
      (N'ProductAttribute.F5 Visina',       1, N'NUMBER',      NULL),
      (N'ProductAttribute.F5 Enota visine', 1, N'UNIT',        NULL),
      (N'ProductAttribute.F5 Zatemnljivo',  1, N'BOOL',        N'Dimmable;Yes;Da'),
      (N'ProductAttribute.F5 Simbol',       1, N'PREFIX',      N'NW.'),
      (N'ProductAttribute.F5 Razred',       1, N'TRIM',        NULL),
      (N'ProductAttribute.F5 Razred',       2, N'STRIPPREFIX', N'CLASS '),
      (N'ProductAttribute.F5 Barva SLO',    1, N'LOOKUP',      N'SL'),
      (N'ProductAttribute.F5 Material SLO', 1, N'LOOKUP',      N'SL'),
      (N'ProductAttribute.F5 Neznano SLO',  1, N'LOOKUP',      N'SL')
    ) AS step(Code, StepOrder, TransformCode, Argument)
    INNER JOIN @Mapping mapping ON mapping.Code=step.Code;

    INSERT map.ValueLookup(Domain,SourceValue,Language,TargetValue,Note)
    VALUES(N'F5 Barva SLO',N'black',N'SL',N'črna',N'test 048'),
          (N'*',N'F5 galvanised probe',N'SL',N'f5 cinkano jeklo',N'test 048');
    """, ("@SourceCode", sourceCode), ("@OrganizationId", organizationId), ("@EntityType", entityType));
}

async Task InsertInboxAsync(SqlConnection sqlConnection, Guid runId, string body, int pageNumber = 1)
{
  await ExecuteAsync(sqlConnection, """
    INSERT ops.PipelineRun(RunId,Pipeline,OrganizationId,SourceCode,Status)
    VALUES(@RunId,N'F5_TRANSFORM',@OrganizationId,@SourceCode,N'Running');
    INSERT raw.Inbox(RunId,OrganizationId,SourceCode,EntityType,PageNumber,PayloadXml,PayloadHash,Status)
    VALUES(@RunId,@OrganizationId,@SourceCode,@EntityType,@PageNumber,@Payload,@Hash,N'Pending');
    """, ("@RunId", runId), ("@OrganizationId", organizationId), ("@SourceCode", sourceCode),
    ("@EntityType", entityType), ("@PageNumber", pageNumber), ("@Payload", body),
    ("@Hash", Convert.ToHexString(SHA256.HashData(Encoding.Unicode.GetBytes(body)))));
}

async Task<string> AttributeAsync(SqlConnection sqlConnection, string attributeCode)
{
  return await ScalarAsync<string>(sqlConnection, """
    SELECT attribute.Value FROM canon.ProductAttribute attribute
    INNER JOIN canon.Product product ON product.ProductId=attribute.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID
      AND attribute.AttributeCode=@AttributeCode;
    """, ("@OrganizationId", organizationId), ("@ItemID", itemId), ("@AttributeCode", attributeCode));
}

async Task CleanupAsync(SqlConnection sqlConnection)
{
  await ExecuteAsync(sqlConnection, """
    DELETE unmapped FROM map.UnmappedValue unmapped
    INNER JOIN map.ExtractedValue value ON value.ExtractedValueId=unmapped.ExtractedValueId
    INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
    WHERE inbox.SourceCode=@SourceCode;

    DELETE value FROM map.ExtractedValue value
    INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
    WHERE inbox.SourceCode=@SourceCode;

    DELETE FROM raw.Inbox WHERE SourceCode=@SourceCode;
    DELETE FROM ops.PipelineRun WHERE SourceCode=@SourceCode;

    DELETE step FROM map.FieldTransform step
    INNER JOIN map.FieldMapping mapping ON mapping.FieldMappingId=step.FieldMappingId
    INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=mapping.SourceConnectorId
    WHERE connector.SourceCode=@SourceCode;

    DELETE mapping FROM map.FieldMapping mapping
    INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=mapping.SourceConnectorId
    WHERE connector.SourceCode=@SourceCode;

    DELETE entityMapping FROM map.EntityMapping entityMapping
    INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
    WHERE connector.SourceCode=@SourceCode;

    DELETE FROM map.SourceConnector WHERE SourceCode=@SourceCode;

    DELETE FROM map.ValueLookup WHERE Note=N'test 048';
    DELETE FROM map.MissingTranslation WHERE Domain LIKE N'F5 %';

    /* Najprej lastnosti, sele nato zgodovina: brisanje lastnosti spet sprozi sledilnik
       sprememb (migracija 034) in bi po ociscenju zgodovine dodal nove vrstice. */
    DELETE attribute FROM canon.ProductAttribute attribute
    INNER JOIN canon.Product product ON product.ProductId=attribute.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;

    /* Svezenj brisemo samo tistega, ki ga je naredil ta test. Vprasanje "kateri svezenj nima vec
       zgodovine" nad celo tabelo je z rastjo kataloga postalo predrago in je test padel na
       casovni meji, ceprav ni bilo nic narobe (isti popravek kot v PIM.F6.SaopStockIntegration). */
    DECLARE @Svezenj TABLE(ChangeBatchId bigint PRIMARY KEY);
    INSERT @Svezenj(ChangeBatchId)
    SELECT DISTINCT history.ChangeBatchId
    FROM pim.ProductFieldHistory history
    INNER JOIN canon.Product product ON product.ProductId=history.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;

    DELETE history FROM pim.ProductFieldHistory history
    INNER JOIN canon.Product product ON product.ProductId=history.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;

    DELETE batch FROM pim.ProductChangeBatch batch
    INNER JOIN @Svezenj mojSvezenj ON mojSvezenj.ChangeBatchId=batch.ChangeBatchId
    WHERE NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory history WHERE history.ChangeBatchId=batch.ChangeBatchId);

    /* Validacija lahko medtem tece kadarkoli in testnemu izdelku pripise stanje;
       brez tega DELETE pade na FK_ProductValidationState_Product. */
    DELETE state FROM val.ProductValidationState state
    INNER JOIN canon.Product product ON product.ProductId=state.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;
    DELETE issue FROM val.ProductIssue issue
    INNER JOIN canon.Product product ON product.ProductId=issue.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemID;

    DELETE FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemID;
    """, ("@SourceCode", sourceCode), ("@OrganizationId", organizationId), ("@ItemID", itemId));
}

static SqlCommand Command(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  // 600 s: vrata tečejo po več hkrati na isti bazi; pri 180 s je čiščenje padlo na časovni meji (#15).
  var command = new SqlCommand(sql, connection) { CommandTimeout = 600 };
  foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter.Name, parameter.Value);
  return command;
}

static async Task ExecuteAsync(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = Command(connection, sql, parameters);
  await command.ExecuteNonQueryAsync();
}

static async Task<T> ScalarAsync<T>(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = Command(connection, sql, parameters);
  return (T)(await command.ExecuteScalarAsync() ?? throw new InvalidOperationException("Poizvedba ni vrnila vrednosti."));
}

static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual))
    throw new InvalidOperationException($"{message} Pričakovano={expected}, dejansko={actual}.");
}

static string? ReadConnectionString()
{
  var value = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
  if (!string.IsNullOrWhiteSpace(value)) return value;
  var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (directory is not null)
  {
    var path = Path.Combine(directory.FullName, "appsettings.Local.json");
    if (File.Exists(path))
    {
      using var document = JsonDocument.Parse(File.ReadAllText(path));
      if (document.RootElement.TryGetProperty("ConnectionStrings", out var connectionStrings)
        && connectionStrings.TryGetProperty("Pim", out var pim))
        return pim.GetString();
    }
    directory = directory.Parent;
  }
  return null;
}
