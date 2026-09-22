-- P2-11 iz docs/PREGLED_SISTEMA_IN_UX_2026-09-08.md (§5): nadzorna plosca 11,7 s, /zajem 21,7 s.
--
-- Izmerjeno 2026-09-09 nad razvojno bazo: `intranet.GetValidationIssues` je za **eno** podjetje
-- tekel **9.788 ms**, `intranet.GetDashboard` pa 42 ms, `intranet.GetPipelineRuns` 2 ms in
-- `intranet.GetSystemIntegrations` 1 ms. Plosca postopek klice enkrat na podjetje, torej stirikrat.
--
-- Vzrok ni bil nacrt poizvedbe, ampak obseg: prvi nabor je vracal **vse** aktivne tezave podjetja
-- brez TOP in brez strani — za podjetje 2 je to nekaj cez dva milijona vrstic. Edini odjemalec
-- (`Dashboard.razor`) iz odgovora bere **samo drugi nabor** (povzetek po profilih); dva milijona
-- vrstic se prenese cez povezavo, sestavi v seznam predmetov in zavrze.
--
-- Popravek je zato v obsegu in ne v indeksu: prvi nabor dobi mejo `@Take` (privzeto 200, kar je
-- vec, kot je katerakoli stran kdaj pokazala), `@Take = 0` pa pomeni »samo povzetka, brez vrstic«.
-- Razvrstitev dobi se `ProductIssueId`, sicer meja pri enakih casih ni ponovljiva.
--
-- Podrobnega seznama tezav ta postopek ni nikoli napajal: za to je `intranet.GetQualityIssues`
-- s stranmi in filtri, ki ga uporablja `/kakovost/napake`.

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetValidationIssues
  @OrganizationId int,
  @Take int = 200
AS
BEGIN
  SET NOCOUNT ON;
  IF @Take IS NULL OR @Take < 0 SET @Take = 200;

  SELECT TOP (@Take)
         issueValue.ProductIssueId AS ProductIssueId, productValue.ProductId AS ProductId,
         productValue.ItemID AS ItemId, profileValue.ProfileCode AS ProfileCode,
         issueValue.IssueCode AS IssueCode, issueValue.Message AS Message,
         issueValue.LastDetectedUtc AS LastDetectedUtc
  FROM val.ProductIssue issueValue
  INNER JOIN canon.Product productValue ON productValue.ProductId = issueValue.ProductId
  INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  WHERE productValue.OrganizationId = @OrganizationId AND issueValue.IsActive = 1
  ORDER BY issueValue.LastDetectedUtc DESC, issueValue.ProductIssueId DESC;

  SELECT profileValue.ProfileCode AS ProfileCode, COUNT_BIG(*) AS ProductCount,
         SUM(CASE WHEN stateValue.Status = N''VALID'' THEN CONVERT(bigint, 1) ELSE CONVERT(bigint, 0) END) AS ValidCount,
         SUM(CASE WHEN stateValue.Status = N''INVALID'' THEN CONVERT(bigint, 1) ELSE CONVERT(bigint, 0) END) AS InvalidCount,
         AVG(CONVERT(decimal(9,2), stateValue.Completeness)) AS AverageCompleteness
  FROM val.ProductValidationState stateValue
  INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = stateValue.ValidationProfileId
  INNER JOIN canon.Product productValue ON productValue.ProductId = stateValue.ProductId
  WHERE productValue.OrganizationId = @OrganizationId
  GROUP BY profileValue.ProfileCode ORDER BY profileValue.ProfileCode;

  SELECT TOP (10) issueValue.IssueCode AS IssueCode, issueValue.Message AS Message, COUNT_BIG(*) AS OccurrenceCount
  FROM val.ProductIssue issueValue
  INNER JOIN canon.Product productValue ON productValue.ProductId = issueValue.ProductId
  WHERE productValue.OrganizationId = @OrganizationId AND issueValue.IsActive = 1
  GROUP BY issueValue.IssueCode, issueValue.Message
  ORDER BY COUNT_BIG(*) DESC, issueValue.IssueCode;
END;
');
