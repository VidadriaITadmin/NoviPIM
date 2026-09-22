/*
  243 — out.VerifyEchoBatch: veriga potrditve iz SAOP nazaj v odhodno vrsto je bila nikoli povezana.

  David 2026-09-22: »ta cakanje mora it povsod stran ... ne bomo nic cakal SAOP«. Pri preiskavi
  (NW.6530, Bruto teza) se je izkazalo, da je vzrok globlji od Excelovega uvoza (243 popravlja
  drugo polovico; sam Excel bug je popravljen v WorkbookTable.cs, commit 1c094f4): out.VerifyEcho
  (046), ExpectedEchoHash in EchoVerifier.Decide (PIM.Outbound) obstajajo, a jih noben delujoc
  del kode nikoli ne poklice. Vsako sporocilo, ki doseze "Sent", zato ostane "caka SAOP" za
  vedno — preverjeno na SONJA: sest sporocil je po odobritvi obticalo, ceprav je vhodna
  sinhronizacija (SAOP_PRODUCTS) med tem uspesno tekla vsaj enkrat.

  Ta migracija ne spreminja obstojece verige branja iz SAOP (map.ProcessRawInbox je bila
  predelana 19-krat; rocno poseganje vanjo pod casovnim pritiskom je prevec tvegano). Namesto
  tega doda LOCENO, dodatno pot: out.VerifyEchoBatch vzame seznam (entityKey, field, value,
  qualifier) — trenutne kanonicne vrednosti, ki jih ze zna prebrati obstojeca, preverjena pot
  (intranet.GetProductWorkbook, isti klic kot za primerjavo »kaj se je spremenilo« pri uvozu
  delovnega lista) — izracuna ISTI kanonicni hash kot out.EnqueueMessage (ista FOR JSON PATH
  oblika, isti vrstni red stolpcev) in za vsako polje poklice out.VerifyEcho. Klicatelj je nova
  metoda ProductWorkbookService.VerifyPendingEchoesAsync (PIM.Intranet), sprozena rocno prek
  novega posla na /sistem/workerji (»Preveri potrditve SAOP«, Internal).

  Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/
SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE out.VerifyEchoBatch
  @OrganizationId int, @EntityType nvarchar(100), @FieldsJson nvarchar(max), @ObservedUtc datetime2(3)
AS
BEGIN
  SET NOCOUNT ON;
  IF ISJSON(@FieldsJson) <> 1 THROW 52900, N''FieldsJson ni veljaven JSON.'', 1;

  DECLARE @EntityKey nvarchar(450), @Field nvarchar(200), @Value nvarchar(4000), @Qualifier nvarchar(450), @Hash char(64);
  DECLARE polja CURSOR LOCAL FAST_FORWARD FOR
    SELECT entityKey, field, value, qualifier
    FROM OPENJSON(@FieldsJson)
      WITH (entityKey nvarchar(450) N''$.entityKey'', field nvarchar(200) N''$.field'',
            value nvarchar(4000) N''$.value'', qualifier nvarchar(450) N''$.qualifier'');
  OPEN polja;
  FETCH NEXT FROM polja INTO @EntityKey, @Field, @Value, @Qualifier;
  WHILE @@FETCH_STATUS = 0
  BEGIN
    /* Ista oblika kot v out.EnqueueMessage (046): entityKey/field/value/qualifier, isti vrstni
       red stolpcev in isti FOR JSON PATH — drugacen niz bi dal drugacen hash in nic se ne bi
       nikoli ujelo. */
    SET @Hash = CONVERT(char(64), HASHBYTES(N''SHA2_256'', CONVERT(varbinary(max),
      (SELECT @EntityKey AS [entityKey], @Field AS [field], @Value AS [value], @Qualifier AS [qualifier]
       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))), 2);

    EXEC out.VerifyEcho @OrganizationId = @OrganizationId, @EntityType = @EntityType,
      @EntityKey = @EntityKey, @InboundHash = @Hash, @ObservedUtc = @ObservedUtc;

    FETCH NEXT FROM polja INTO @EntityKey, @Field, @Value, @Qualifier;
  END;
  CLOSE polja; DEALLOCATE polja;
END;');

IF OBJECT_ID(N'out.VerifyEchoBatch', N'P') IS NULL
  THROW 52901, N'243: out.VerifyEchoBatch ni nastala.', 1;
