using Microsoft.Data.SqlClient;
namespace PIM.StockMapping;

// Skupna pisalna pot zaloge: iz nje pisejo vsi viri, ne le datotecni. Doslej je zivela v
// PIM.StockFileWorker, ker je bil ta edini pisec; ko je zalogo dobil se SAOP, bi to pomenilo
// workerja, ki referencira drugega workerja. Vsebina je nespremenjena.

public sealed class StockLandingWriter(string connectionString)
{
  /// <summary>
  /// Zapise en posnetek zaloge. Cetrti clen pove, da je bil ta posnetek ze v bazi in da ta
  /// klic ni zapisal nicesar.
  /// </summary>
  public async Task<(Guid RunId, int Applied, int Quarantined, bool AlreadyApplied)> PersistAsync(
    int organizationId, string sourceCode, string connectorType, string endpoint, DateTime snapshotUtc,
    string payloadHash, IReadOnlyList<ExtractedStockRow> records, string dateFormat,
    StockFieldContract? fields = null, CancellationToken cancellationToken = default)
  {
    fields ??= new();

    // Cas posnetka porezemo na celo sekundo. Razlog ni natancnost, ampak dedup: kljuc posnetka je
    // (podjetje, konektor, cas), vpis pa gre skozi AddWithValue, ki za DateTime sklepa
    // SqlDbType.DateTime z locljivostjo 1/300 sekunde. Ta milisekundo popaci (.997 -> .996),
    // stolpec datetime2(3) shrani popaceno vrednost, iskanje z izvirnim casom je ne najde in
    // ponovno branje iste datoteke pade na UQ_StockSnapshot (SQL 2627). Izmerjeno 2026-08-27.
    //
    // Poravnava na sekundo je edina vrednost, ki prezivi obe predstavitvi nespremenjena, zato
    // odpravi cel razred napake namesto posameznega primera. Dva razlicna posnetka istega vira
    // znotraj iste sekunde niso realen primer: cas je cas spremembe dobaviteljeve datoteke.
    snapshotUtc = new DateTime(snapshotUtc.Ticks - snapshotUtc.Ticks % TimeSpan.TicksPerSecond, snapshotUtc.Kind);

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);
    var runId = Guid.NewGuid();
    try
    {
      var connectorId = await EnsureConnectorAsync(connection, transaction, organizationId, sourceCode, connectorType, cancellationToken);

      // Posnetek nosi cas datoteke, ne cas zagona (glej PIM.StockFileWorker), zato je ista
      // nespremenjena datoteka isti posnetek. stock.Snapshot to zahtevo pozna kot UQ_StockSnapshot
      // (podjetje, konektor, cas posnetka) — drugi zagon iste datoteke je torej po zasnovi
      // podvojen kljuc in ne okvara.
      //
      // Doslej je to koncalo kot neujeta SqlException 2627 in worker je padel s sledjo sklada.
      // V nocnem opravilu je to pravilo, ne izjema: dobavitelj datoteke ne posodobi vsak dan,
      // ob koncu tedna pa nikoli. Zato tak zagon zdaj pove, da je posnetek ze v bazi, in
      // konca brez napake.
      var existingRunId = await FindSnapshotRunAsync(connection, transaction, organizationId, connectorId, snapshotUtc, cancellationToken);
      if (existingRunId is { } alreadyRunId)
      {
        var counts = await ReadRunCountsAsync(connection, transaction, alreadyRunId, cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return (alreadyRunId, counts.Applied, counts.Quarantined, true);
      }

      var identityRule = await LoadIdentityRuleAsync(connection, transaction, connectorId, cancellationToken);
      await ExecuteAsync(connection, transaction, """
        INSERT stock.SyncRun(SyncRunId,OrganizationId,SourceConnectorId,Status,Endpoint,StartedUtc,FetchedUtc,RecordsRead)
        VALUES(@RunId,@OrganizationId,@ConnectorId,N'Running',@Endpoint,@SnapshotUtc,@SnapshotUtc,@Count);
        INSERT stock.Snapshot(SyncRunId,OrganizationId,SourceConnectorId,Endpoint,SnapshotUtc,IsActive)
        VALUES(@RunId,@OrganizationId,@ConnectorId,@Endpoint,@SnapshotUtc,0);
        """, cancellationToken, ("@RunId",runId),("@OrganizationId",organizationId),("@ConnectorId",connectorId),("@Endpoint",endpoint),("@SnapshotUtc",snapshotUtc),("@Count",records.Count));
      var normalizer = new StockNormalizer();
      var applied=0; var quarantined=0;
      foreach (var row in records)
      {
        var result=normalizer.Normalize(row,identityRule,dateFormat,fields);
        row.Values.TryGetValue(identityRule.SourceKeyField,out var sourceItemId);
        row.Values.TryGetValue(fields.EanField,out var ean); row.Values.TryGetValue(fields.QuantityField,out var quantity);
        row.Values.TryGetValue(fields.AvailabilityDateField,out var date); row.Values.TryGetValue(fields.IncomingQuantityField,out var incoming);
        // Registrirani pogled (145): stiri dodatne kolicine gredo v bazo kot besedilo, v stevilo
        // jih pretvori stock.ApplyLandingRecord s TRY_CONVERT. Vira brez njih dasta null.
        row.Values.TryGetValue(fields.OrderedQuantityField,out var ordered); row.Values.TryGetValue(fields.ForShipmentQuantityField,out var forShipment);
        row.Values.TryGetValue(fields.AvailableQuantityField,out var available); row.Values.TryGetValue(fields.SupplierOrderedQuantityField,out var supplierOrdered);
        var canonicalDate=result.Position?.AvailabilityDate?.ToString("yyyy-MM-dd",System.Globalization.CultureInfo.InvariantCulture)??date;
        var landingId=await InsertLandingAsync(connection,transaction,runId,organizationId,connectorId,row.RecordOrdinal.ToString(System.Globalization.CultureInfo.InvariantCulture),snapshotUtc,endpoint,payloadHash,ean,sourceItemId,result.Position?.NormalizedItemId,quantity,canonicalDate,incoming,new(ordered,forShipment,available,supplierOrdered),cancellationToken);
        await ExecuteAsync(connection,transaction,"EXEC stock.ApplyLandingRecord @LandingRecordId,@DateFormat;",cancellationToken,("@LandingRecordId",landingId),("@DateFormat","yyyy-MM-dd"));
        if(result.Position is null)quarantined++;else applied++;
      }
      await using (var counts = new SqlCommand("SELECT SUM(CASE WHEN Status=N'Applied' THEN 1 ELSE 0 END),SUM(CASE WHEN Status=N'Quarantined' THEN 1 ELSE 0 END) FROM stock.LandingRecord WHERE SyncRunId=@RunId;",connection,transaction))
      {
        counts.Parameters.AddWithValue("@RunId",runId);
        await using var reader=await counts.ExecuteReaderAsync(cancellationToken);await reader.ReadAsync(cancellationToken);
        applied=reader.IsDBNull(0)?0:reader.GetInt32(0);quarantined=reader.IsDBNull(1)?0:reader.GetInt32(1);
      }
      await ExecuteAsync(connection,transaction,"UPDATE stock.Snapshot SET IsActive=0 WHERE OrganizationId=@OrganizationId AND SourceConnectorId=@ConnectorId; UPDATE stock.Snapshot SET IsActive=1 WHERE SyncRunId=@RunId; UPDATE stock.SyncRun SET Status=N'Completed',CompletedUtc=SYSUTCDATETIME(),RecordsApplied=@Applied,RecordsQuarantined=@Quarantined WHERE SyncRunId=@RunId;",cancellationToken,("@OrganizationId",organizationId),("@ConnectorId",connectorId),("@RunId",runId),("@Applied",applied),("@Quarantined",quarantined));
      await transaction.CommitAsync(cancellationToken);
      return(runId,applied,quarantined,false);
    }
    catch { await transaction.RollbackAsync(cancellationToken); throw; }
  }

  /// <summary>Ali ta posnetek (podjetje, konektor, cas) v bazi ze obstaja; ce da, vrne njegov zagon.</summary>
  static async Task<Guid?> FindSnapshotRunAsync(SqlConnection c,SqlTransaction t,int organizationId,int connectorId,DateTime snapshotUtc,CancellationToken ct)
  {
    await using var cmd=new SqlCommand("SELECT TOP(1) SyncRunId FROM stock.Snapshot WHERE OrganizationId=@Org AND SourceConnectorId=@Connector AND SnapshotUtc=@Snapshot ORDER BY SnapshotId DESC;",c,t);
    cmd.Parameters.AddWithValue("@Org",organizationId);cmd.Parameters.AddWithValue("@Connector",connectorId);
    DodajCasPosnetka(cmd,"@Snapshot",snapshotUtc);
    var value=await cmd.ExecuteScalarAsync(ct);
    return value is null or DBNull?null:(Guid)value;
  }

  static async Task<(int Applied,int Quarantined)> ReadRunCountsAsync(SqlConnection c,SqlTransaction t,Guid runId,CancellationToken ct)
  {
    await using var cmd=new SqlCommand("SELECT SUM(CASE WHEN Status=N'Applied' THEN 1 ELSE 0 END),SUM(CASE WHEN Status=N'Quarantined' THEN 1 ELSE 0 END) FROM stock.LandingRecord WHERE SyncRunId=@RunId;",c,t);
    cmd.Parameters.AddWithValue("@RunId",runId);
    await using var reader=await cmd.ExecuteReaderAsync(ct);await reader.ReadAsync(ct);
    return(reader.IsDBNull(0)?0:reader.GetInt32(0),reader.IsDBNull(1)?0:reader.GetInt32(1));
  }

  static async Task<StockIdentityRule> LoadIdentityRuleAsync(SqlConnection c,SqlTransaction t,int connectorId,CancellationToken ct)
  {
    await using var cmd=new SqlCommand("SELECT TOP(1) SourceKeyField,Prefix,ReplaceOld,ReplaceNew,MatchPriority FROM map.StockIdentityRule WHERE SourceConnectorId=@ConnectorId AND IsActive=1 ORDER BY StockIdentityRuleId;",c,t);
    cmd.Parameters.AddWithValue("@ConnectorId",connectorId);
    await using var reader=await cmd.ExecuteReaderAsync(ct);
    if(!await reader.ReadAsync(ct)) throw new InvalidOperationException("Aktivno identitetno pravilo za stock konektor ni konfigurirano.");
    return new(reader.GetString(0),reader.GetString(1),reader.IsDBNull(2)?null:reader.GetString(2),reader.IsDBNull(3)?null:reader.GetString(3),reader.GetString(4));
  }

  static async Task<int> EnsureConnectorAsync(SqlConnection c,SqlTransaction t,int org,string code,string type,CancellationToken ct)
  {
    await ExecuteAsync(c,t,"IF NOT EXISTS(SELECT 1 FROM map.SourceConnector WHERE OrganizationId=@Org AND SourceCode=@Code) INSERT map.SourceConnector(SourceCode,OrganizationId,ConnectorType) VALUES(@Code,@Org,@Type);",ct,("@Org",org),("@Code",code),("@Type",type));
    await using var cmd=new SqlCommand("SELECT SourceConnectorId FROM map.SourceConnector WHERE OrganizationId=@Org AND SourceCode=@Code;",c,t);cmd.Parameters.AddWithValue("@Org",org);cmd.Parameters.AddWithValue("@Code",code);return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
  }
  /// <summary>Dodatne kolicine registriranega pogleda SAOP (migracija 145); pri drugih virih so vse null.</summary>
  public sealed record ExtraQuantities(string? Ordered,string? ForShipment,string? Available,string? SupplierOrdered);

  static async Task<long> InsertLandingAsync(SqlConnection c,SqlTransaction t,Guid run,int org,int connector,string key,DateTime snapshot,string endpoint,string hash,string? ean,string? source,string? normalized,string? quantity,string? date,string? incoming,ExtraQuantities extra,CancellationToken ct)
  {
    await using var cmd=new SqlCommand("""INSERT stock.LandingRecord(SyncRunId,OrganizationId,SourceConnectorId,SourceRecordKey,SnapshotUtc,Endpoint,RawPayload,PayloadHash,Ean,SourceItemId,NormalizedItemId,QuantityText,AvailabilityDateText,IncomingQuantityText,OrderedQuantityText,ForShipmentQuantityText,AvailableQuantityText,SupplierOrderedQuantityText) OUTPUT INSERTED.LandingRecordId VALUES(@Run,@Org,@Connector,@Key,@Snapshot,@Endpoint,@Raw,@Hash,@Ean,@Source,@Normalized,@Quantity,@Date,@Incoming,@Ordered,@ForShipment,@Available,@SupplierOrdered);""",c,t);
    foreach(var p in new(string,object?)[ ]{("@Run",run),("@Org",org),("@Connector",connector),("@Key",key),("@Snapshot",snapshot),("@Endpoint",endpoint),("@Raw",key),("@Hash",hash),("@Ean",ean),("@Source",source),("@Normalized",normalized),("@Quantity",quantity),("@Date",date),("@Incoming",incoming),("@Ordered",extra.Ordered),("@ForShipment",extra.ForShipment),("@Available",extra.Available),("@SupplierOrdered",extra.SupplierOrdered)})cmd.Parameters.AddWithValue(p.Item1,p.Item2??DBNull.Value);
    return Convert.ToInt64(await cmd.ExecuteScalarAsync(ct));
  }
  /// <summary>
  /// Cas posnetka kot datetime2(3), tako kot stolpec. AddWithValue bi za DateTime sklepal
  /// SqlDbType.DateTime, ki ima ločljivost 1/300 sekunde in vrednost .993 zaokrozi na .99333;
  /// primerjava s shranjenim .993 zato ne ujame nicesar in dedup posnetka odpove. Izmerjeno
  /// 2026-08-27: drugo branje iste datoteke je padlo na UQ_StockSnapshot (SQL 2627), ceprav je
  /// bil posnetek ze v bazi.
  /// </summary>
  static void DodajCasPosnetka(SqlCommand cmd,string ime,DateTime vrednost)
  {
    var p=cmd.Parameters.Add(ime,System.Data.SqlDbType.DateTime2);
    p.Scale=3;
    p.Value=vrednost;
  }

  // Vpis namenoma ostane na AddWithValue: stolpci so datetime2(3) in vrednost se ob vpisu poreze
  // na milisekundo. Popravka potrebuje samo iskanje, kjer se primerjata dve razlicno zaokrozeni
  // vrednosti. Sirsa sprememba je bila poskusena in je podrla vstavljanje pozicij.
  static async Task ExecuteAsync(SqlConnection c,SqlTransaction t,string sql,CancellationToken ct,params (string,object?)[] values){await using var cmd=new SqlCommand(sql,c,t);foreach(var p in values)cmd.Parameters.AddWithValue(p.Item1,p.Item2??DBNull.Value);await cmd.ExecuteNonQueryAsync(ct);}
}
