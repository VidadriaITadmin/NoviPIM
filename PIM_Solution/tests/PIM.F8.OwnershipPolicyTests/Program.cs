using System.Text.Json;
using Microsoft.Data.SqlClient;

// Dokaz za migracijo 068 (C8): lastništvo polj iz stolpcev "Smer" in "Master" preglednice.
//
// Zakaj je to pomembno: out.EnqueueMessage zavrne vsako spremembo, za katero ni vrstice z
// Owner = 'PIM' (napaka 51010). Dokler je bila out.OwnershipPolicy prazna, odhodna pot ni mogla
// poslati ničesar — in to ni bilo nikjer vidno, ker sporočila sploh niso nastala.
//
// Kaj mora pokazati:
//   1. pravilo O9 drži: polje s pravico do pisanja mora imeti vhodno preslikavo;
//   2. polje, ki je po preglednici samo za branje, je zabeleženo in ne dobi pravice;
//   3. sporočilo za polje s pravico res nastane, za polje brez nje pa pade s 51010.
// Tretja točka teče v transakciji, ki se povrne — v bazi ne ostane nobeno sporočilo.

const int organizationId = 2;

// Brez nastavljene povezave se preskoci, ne pade (isto pravilo kot v ostalih integracijah).
var connectionString = ReadConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("F8 lastnistvo preskoceno: manjka razvojna povezava Pim.");
  return 0;
}

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

// 1. O9 — pravica do pisanja brez vhodne preslikave ne sme obstajati.
Equal(0, await ScalarAsync<int>(connection, """
  SELECT COUNT(*) FROM out.OwnershipPolicy policy
  WHERE policy.Owner=N'PIM' AND policy.TargetKind=N'SAOP_PRODUCT' AND policy.IsEnabled=1
    AND NOT EXISTS
    (
      SELECT 1 FROM map.FieldMapping mapping
      INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=mapping.SourceConnectorId
      WHERE connector.OrganizationId=policy.OrganizationId AND connector.SourceCode LIKE N'SAOP[_]%'
        AND connector.SourceCode NOT LIKE N'%[_]STOCK' AND mapping.IsActive=1
        AND mapping.TargetFieldCode=policy.FieldName
    );
  """), "Polje ima pravico do pisanja, a ga ne beremo nazaj (O9).");

// 2. Preglednica: šifra artikla je obojesmerna, cena pa pride iz SAOP in se ne piše nazaj.
Equal("PIM", await ScalarAsync<string>(connection, """
  SELECT Owner FROM out.OwnershipPolicy
  WHERE OrganizationId=@Org AND TargetKind=N'SAOP_PRODUCT' AND FieldName=N'Product.ItemID';
  """, ("@Org", organizationId)), "Sifra artikla mora biti pisljiva.");
Equal("SAOP", await ScalarAsync<string>(connection, """
  SELECT Owner FROM out.OwnershipPolicy
  WHERE OrganizationId=@Org AND TargetKind=N'SAOP_PRODUCT' AND FieldName=N'ProductPrice.Net';
  """, ("@Org", organizationId)), "Cena po preglednici ni pisljiva.");

// 3. Ista pravila v resnici: eno polje gre skozi, drugo pade. Vse v transakciji, ki se povrne.
await using (var transaction = (SqlTransaction)await connection.BeginTransactionAsync())
{
  await ExecuteAsync(connection, transaction, """
    IF NOT EXISTS(SELECT 1 FROM dbo.IntegrationProfile WHERE OrganizationId=@Org AND TargetKind=N'SAOP_PRODUCT')
      INSERT dbo.IntegrationProfile(OrganizationId,TargetKind,EndpointTemplate,HttpOperation,ApprovalMode,IsEnabled,UpdatedBy)
      VALUES(@Org,N'SAOP_PRODUCT',N'http://127.0.0.1:1/ne-uporablja-se',N'PATCH',N'ManualApproval',1,N'F8_OWNERSHIP_TEST');
    ELSE UPDATE dbo.IntegrationProfile SET IsEnabled=1 WHERE OrganizationId=@Org AND TargetKind=N'SAOP_PRODUCT';
    """, ("@Org", organizationId));

  var dovoljeno = await ScalarTxAsync<long>(connection, transaction, """
    DECLARE @Id bigint;
    EXEC out.EnqueueMessage @OrganizationId=@Org,@TargetKind=N'SAOP_PRODUCT',@Operation=N'UPDATE',
      @EntityType=N'Product',@PayloadJson=@Payload,@Actor=N'F8_OWNERSHIP_TEST',@OutboxMessageId=@Id OUTPUT;
    SELECT @Id;
    """, ("@Org", organizationId),
    ("@Payload", "{\"entityKey\":\"F8-OWN-1\",\"field\":\"Product.UoM\",\"value\":\"KOS\"}"));
  if (dovoljeno <= 0) throw new InvalidOperationException("Polje s pravico ni bilo sprejeto.");

  var zavrnjeno = false;
  try
  {
    await ScalarTxAsync<long>(connection, transaction, """
      DECLARE @Id bigint;
      EXEC out.EnqueueMessage @OrganizationId=@Org,@TargetKind=N'SAOP_PRODUCT',@Operation=N'UPDATE',
        @EntityType=N'Product',@PayloadJson=@Payload,@Actor=N'F8_OWNERSHIP_TEST',@OutboxMessageId=@Id OUTPUT;
      SELECT @Id;
      """, ("@Org", organizationId),
      ("@Payload", "{\"entityKey\":\"F8-OWN-1\",\"field\":\"ProductPrice.Net\",\"value\":\"9.99\"}"));
  }
  catch (SqlException exception) when (exception.Number == 51010)
  {
    zavrnjeno = true;
  }
  if (!zavrnjeno) throw new InvalidOperationException("Polje brez pravice je bilo sprejeto.");

  await transaction.RollbackAsync();
}

Equal(0, await ScalarAsync<int>(connection, """
  SELECT COUNT(*) FROM out.OutboxMessage WHERE CreatedBy=N'F8_OWNERSHIP_TEST';
  """), "Test je pustil sporocilo v odhodni vrsti.");

Console.WriteLine("F8 lastnistvo: pravilo O9, samo za branje in resnicna zavrnitev PASS.");
return 0;

static async Task ExecuteAsync(SqlConnection connection, SqlTransaction transaction, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = new SqlCommand(sql, connection, transaction) { CommandTimeout = 60 };
  foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter.Name, parameter.Value);
  await command.ExecuteNonQueryAsync();
}

// Lokalne funkcije ne poznajo preobremenitev, zato ima razlicica s transakcijo svoje ime.
static Task<T> ScalarAsync<T>(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
  => ScalarTxAsync<T>(connection, null, sql, parameters);

static async Task<T> ScalarTxAsync<T>(SqlConnection connection, SqlTransaction? transaction, string sql,
  params (string Name, object Value)[] parameters)
{
  await using var command = transaction is null
    ? new SqlCommand(sql, connection) { CommandTimeout = 60 }
    : new SqlCommand(sql, connection, transaction) { CommandTimeout = 60 };
  foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter.Name, parameter.Value);
  return (T)(await command.ExecuteScalarAsync() ?? throw new InvalidOperationException("Poizvedba ni vrnila vrednosti."));
}

static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual))
    throw new InvalidOperationException($"{message} Pricakovano={expected}, dejansko={actual}.");
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
