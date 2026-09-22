/*
  262 — zaloga dobavitelja se na strani Zaloga pokaže samo pri artiklu, ki ga podjetje ima.

  Dobaviteljeva datoteka (BT_STOCK, NW_STOCK) se zapiše vsakemu podjetju, ker ne vemo vnaprej, katero ima
  katero šifro. Pozicija brez artikla v podjetju pa na strani ne sme postati svoja vrstica »brez artikla«:
  2026-09-22 je Ediito kazal NW.10017 in BA.BA09.00510, čeprav teh artiklov nima.

  Poleg tega je bil ključ neujete vrstice U:<vir>:<šifra> BREZ podjetja, zato so se neujete pozicije vseh
  podjetij sešteli v eno vrstico in dobili ime podjetja z najvišjim Id: NW.10017 = 73 + 73 = 146,
  BA.BA09.00510 = 3 × 7.000 = 21.000 (DEMO, IQLighting, Ediito). Dobavitelj ima eno zalogo — pri vsakem
  podjetju je v bazi pravilno 73 oz. 7.000; napačen je bil samo seštevek na strani.

  Popravek v intranet.GetStockByItem (stran in izvoz zaloge v Excel):
    1. pozicija dobavitelja (ConnectorType <> SAOP) šteje samo, če je ujeta na artikel podjetja;
    2. ključ neujete vrstice (ostanejo samo SAOP pozicije brez artikla) vsebuje podjetje.
  Pozicije ostanejo v stock.Position (ujemanje se ob novem artiklu zgodi ob naslednjem branju datoteke).
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @definicija nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetStockByItem'));

DECLARE @kljucStaro nvarchar(400) = N'CONCAT(N''U:'', connector.SourceCode, N'':'', position.NormalizedItemId)';
DECLARE @kljucNovo nvarchar(400) = N'CONCAT(N''U:'', snapshot.OrganizationId, N'':'', connector.SourceCode, N'':'', position.NormalizedItemId) /* 262 */';
DECLARE @pogojStaro nvarchar(400) = N'WHERE (@OrganizationId IS NULL OR snapshot.OrganizationId = @OrganizationId)
      AND (@SourceCode IS NULL OR connector.SourceCode = @SourceCode)';
DECLARE @pogojNovo nvarchar(600) = N'WHERE (@OrganizationId IS NULL OR snapshot.OrganizationId = @OrganizationId)
      AND (connector.ConnectorType = N''SAOP'' OR position.MatchedProductId IS NOT NULL) /* 262: dobavitelj samo pri obstojecem artiklu */
      AND (@SourceCode IS NULL OR connector.SourceCode = @SourceCode)';

IF CHARINDEX(N'/* 262 */', @definicija) = 0
BEGIN
  -- Definicija v bazi ima lahko CRLF ali LF; pogoj iz dveh vrstic primerjamo v obliki, ki jo ima baza.
  IF CHARINDEX(NCHAR(13) + NCHAR(10), @definicija) > 0
    SELECT @pogojStaro = REPLACE(REPLACE(@pogojStaro, NCHAR(13) + NCHAR(10), NCHAR(10)), NCHAR(10), NCHAR(13) + NCHAR(10)),
        @pogojNovo = REPLACE(REPLACE(@pogojNovo, NCHAR(13) + NCHAR(10), NCHAR(10)), NCHAR(10), NCHAR(13) + NCHAR(10));
  ELSE
    SELECT @pogojStaro = REPLACE(@pogojStaro, NCHAR(13), N''),
        @pogojNovo = REPLACE(@pogojNovo, NCHAR(13), N'');

  IF CHARINDEX(@kljucStaro, @definicija) = 0
    THROW 52620, N'262: v intranet.GetStockByItem ni kljuca neujete vrstice iz 191/218.', 1;
  IF CHARINDEX(@pogojStaro, @definicija) = 0
    THROW 52621, N'262: v intranet.GetStockByItem ni pogoja po podjetju in viru iz 191/218.', 1;

  SET @definicija = REPLACE(@definicija, @kljucStaro, @kljucNovo);
  SET @definicija = REPLACE(@definicija, @pogojStaro, @pogojNovo);
  SET @definicija = STUFF(@definicija, CHARINDEX(N'CREATE', @definicija), LEN(N'CREATE'), N'CREATE OR ALTER');
  EXEC(@definicija);
END;

IF CHARINDEX(N'/* 262: dobavitelj samo pri obstojecem artiklu */', OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetStockByItem'))) = 0
  THROW 52622, N'262: intranet.GetStockByItem ni posodobljen.', 1;
