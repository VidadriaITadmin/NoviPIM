using System.Data;
using Microsoft.Data.SqlClient;

const int organizationId = 2;
const string itemId = "CHANGE-TRACKING-PROOF";
var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING")
  ?? throw new InvalidOperationException("Manjka PIM_CONNECTION_STRING.");

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

await VerifySuccessfulUndoAsync();
await VerifyRedoGuardAsync();
await VerifyConflictGuardAsync();
await VerifyBatchUndoAsync();
Console.WriteLine("Change tracking integration: field undo, batch undo, redo guard and conflict guard PASS.");
return 0;

async Task VerifySuccessfulUndoAsync()
{
  await ExecuteAsync("BEGIN TRANSACTION;");
  try
  {
    var changeId = await CreateTrackedChangeAsync();
    await ExecuteAsync("EXEC pim.UndoProductField @OrganizationId,@ChangeId,N'PIM.ChangeTracking.Integration';",
      ("@OrganizationId", organizationId), ("@ChangeId", changeId));
    Equal(false, await ScalarAsync<bool>("SELECT WebPublish FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemId;", ("@OrganizationId", organizationId), ("@ItemId", itemId)), "Undo ni vrnil stare PIM vrednosti.");
    Equal(1, await ScalarAsync<int>("SELECT COUNT(*) FROM pim.ProductFieldHistory WHERE UndoOfChangeId=@ChangeId;", ("@ChangeId", changeId)), "Undo ni ustvaril nove zgodovinske vrstice.");
  }
  finally { await RollbackIfNeededAsync(); }
}

async Task VerifyRedoGuardAsync()
{
  await ExecuteAsync("BEGIN TRANSACTION;");
  try
  {
    var changeId = await CreateTrackedChangeAsync();
    await ExecuteAsync("EXEC pim.UndoProductField @OrganizationId,@ChangeId,N'PIM.ChangeTracking.Integration';",
      ("@OrganizationId", organizationId), ("@ChangeId", changeId));
    await ExpectSqlErrorAsync("EXEC pim.UndoProductField @OrganizationId,@ChangeId,N'PIM.ChangeTracking.Integration';",
      ("@OrganizationId", organizationId), ("@ChangeId", changeId));
  }
  finally { await RollbackIfNeededAsync(); }
}

async Task VerifyConflictGuardAsync()
{
  await ExecuteAsync("BEGIN TRANSACTION;");
  try
  {
    var changeId = await CreateTrackedChangeAsync();
    await ExecuteAsync("""
      DECLARE @ProductId bigint=(SELECT ProductId FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemId);
      EXEC pim.SetChangeContext @ChangeSource=N'INTEGRATION_TEST',@ChangedBy=N'PIM.ChangeTracking.Integration';
      UPDATE canon.Product SET WebPublish=0 WHERE ProductId=@ProductId;
      EXEC pim.ClearChangeContext;
      """, ("@OrganizationId", organizationId), ("@ItemId", itemId));
    await ExpectSqlErrorAsync("EXEC pim.UndoProductField @OrganizationId,@ChangeId,N'PIM.ChangeTracking.Integration';",
      ("@OrganizationId", organizationId), ("@ChangeId", changeId));
  }
  finally { await RollbackIfNeededAsync(); }
}

async Task VerifyBatchUndoAsync()
{
  await ExecuteAsync("BEGIN TRANSACTION;");
  try
  {
    await ExecuteAsync("""
      INSERT canon.Product(OrganizationId,ItemID,WebPublish,IsActive) VALUES(@OrganizationId,@ItemId,0,0);
      DECLARE @ProductId bigint=SCOPE_IDENTITY(),@BatchId uniqueidentifier=NEWID();
      EXEC pim.SetChangeContext @ChangeSource=N'INTEGRATION_TEST',@ChangedBy=N'PIM.ChangeTracking.Integration',@BatchId=@BatchId;
      UPDATE canon.Product SET WebPublish=1,IsActive=1 WHERE ProductId=@ProductId;
      EXEC pim.ClearChangeContext;
      """, ("@OrganizationId", organizationId), ("@ItemId", itemId));
    var originalBatchId = await ScalarAsync<long>("""
      SELECT TOP(1) history.ChangeBatchId FROM pim.ProductFieldHistory history
      INNER JOIN canon.Product product ON product.ProductId=history.ProductId
      WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemId
      ORDER BY history.ChangeId DESC;
      """, ("@OrganizationId", organizationId), ("@ItemId", itemId));
    await ExecuteAsync("EXEC pim.UndoProductBatch @OrganizationId,@ChangeBatchId,N'PIM.ChangeTracking.Integration';",
      ("@OrganizationId", organizationId), ("@ChangeBatchId", originalBatchId));
    Equal(false, await ScalarAsync<bool>("SELECT WebPublish FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemId;", ("@OrganizationId", organizationId), ("@ItemId", itemId)), "Batch undo ni vrnil WebPublish.");
    Equal(false, await ScalarAsync<bool>("SELECT IsActive FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemId;", ("@OrganizationId", organizationId), ("@ItemId", itemId)), "Batch undo ni vrnil IsActive.");
    Equal(1, await ScalarAsync<int>("""
      SELECT COUNT(DISTINCT undoHistory.ChangeBatchId) FROM pim.ProductFieldHistory undoHistory
      WHERE undoHistory.UndoOfChangeId IN (SELECT ChangeId FROM pim.ProductFieldHistory WHERE ChangeBatchId=@ChangeBatchId);
      """, ("@ChangeBatchId", originalBatchId)), "Batch undo ni ustvaril enega skupnega undo batcha.");
  }
  finally { await RollbackIfNeededAsync(); }
}

async Task<long> CreateTrackedChangeAsync()
{
  await ExecuteAsync("""
    INSERT canon.Product(OrganizationId,ItemID,WebPublish) VALUES(@OrganizationId,@ItemId,0);
    DECLARE @ProductId bigint=SCOPE_IDENTITY();
    EXEC pim.SetChangeContext @ChangeSource=N'INTEGRATION_TEST',@ChangedBy=N'PIM.ChangeTracking.Integration',@Note=N'proof';
    UPDATE canon.Product SET WebPublish=1 WHERE ProductId=@ProductId;
    EXEC pim.ClearChangeContext;
    """, ("@OrganizationId", organizationId), ("@ItemId", itemId));
  return await ScalarAsync<long>("""
    SELECT TOP(1) history.ChangeId FROM pim.ProductFieldHistory history
    INNER JOIN canon.Product product ON product.ProductId=history.ProductId
    WHERE product.OrganizationId=@OrganizationId AND product.ItemID=@ItemId AND history.FieldKey=N'Product.WebPublish'
    ORDER BY history.ChangeId DESC;
    """, ("@OrganizationId", organizationId), ("@ItemId", itemId));
}

async Task RollbackIfNeededAsync()
{
  if (Convert.ToInt32(await ScalarAsync<short>("SELECT XACT_STATE();")) != 0) await ExecuteAsync("ROLLBACK TRANSACTION;");
}
async Task ExecuteAsync(string sql, params (string Name, object Value)[] parameters)
{
  await using var command = Create(sql, parameters);
  await command.ExecuteNonQueryAsync();
}
async Task<T> ScalarAsync<T>(string sql, params (string Name, object Value)[] parameters)
{
  await using var command = Create(sql, parameters);
  return (T)(await command.ExecuteScalarAsync() ?? throw new InvalidOperationException("Poizvedba ni vrnila vrednosti."));
}
async Task ExpectSqlErrorAsync(string sql, params (string Name, object Value)[] parameters)
{
  try { await ExecuteAsync(sql, parameters); }
  catch (SqlException) { return; }
  throw new InvalidOperationException("Pričakovana konfliktna oziroma redo blokada se ni zgodila.");
}
SqlCommand Create(string sql, params (string Name, object Value)[] parameters)
{
  var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
  foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter.Name, parameter.Value);
  return command;
}
void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"{message} Pričakovano={expected}, dejansko={actual}.");
}
