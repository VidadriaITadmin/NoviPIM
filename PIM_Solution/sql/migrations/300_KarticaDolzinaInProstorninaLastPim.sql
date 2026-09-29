/*
  300 — dolžina in prostornina paketa: PIM ju sme pisati v SAOP (pravilo lastništva), kot širino in višino.

  Nadaljevanje 298. Register out.SaopXmlField zdaj pozna ItemLength in ItemVolumePerUnit, kartica pa polje
  ponudi v urejanje samo, če ga intranet.GetWritableSaopFields vrne — ta zahteva še vrstico v
  out.OwnershipPolicy z Owner = 'PIM'. Migracija 068 je obe polji (po takratni preglednici) označila
  »SAOP« = beremo, ne pišemo; širina in višina sta bili »PIM«. Zato je bila dolžina na kartici zaklenjena,
  širina pa ne (sodelavec 2026-09-28: »lahko širino in višino, dolžino pa ne morem«).

  Pomen lastništva (068): 'PIM' = polje je pisljivo IN ga zajem iz SAOP še vedno bere nazaj. Nič se ne
  pošlje samo od sebe; sprememba s kartice ali iz Excela čaka odobritev na strani Izhod v SAOP.

  Kaj naredi: za vsa podjetja, ki imajo pravila za SAOP_PRODUCT, nastavi Owner = 'PIM' za
  ProductCommercial.PackageLength in ProductCommercial.Volume (vrstico doda, če je ni).

  Ročni korak: ne.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

;WITH podjetje AS
(
  SELECT DISTINCT OrganizationId FROM out.OwnershipPolicy WHERE TargetKind = N'SAOP_PRODUCT'
),
polje AS
(
  SELECT FieldName FROM (VALUES (N'ProductCommercial.PackageLength'), (N'ProductCommercial.Volume')) AS v(FieldName)
)
MERGE out.OwnershipPolicy AS target
USING (SELECT podjetje.OrganizationId, polje.FieldName FROM podjetje CROSS JOIN polje) AS source
  ON target.OrganizationId = source.OrganizationId AND target.TargetKind = N'SAOP_PRODUCT'
 AND target.FieldName = source.FieldName AND target.ConstraintKind IS NULL AND target.ConstraintValue IS NULL
WHEN MATCHED AND (target.Owner <> N'PIM' OR target.IsEnabled = 0) THEN
  UPDATE SET Owner = N'PIM', IsEnabled = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 300'
WHEN NOT MATCHED THEN
  INSERT (OrganizationId, TargetKind, EntityType, FieldName, Owner, IsEnabled, UpdatedBy)
  VALUES (source.OrganizationId, N'SAOP_PRODUCT', N'Product', source.FieldName, N'PIM', 1, N'migracija 300');

IF EXISTS
(
  SELECT 1
  FROM (SELECT DISTINCT OrganizationId FROM out.OwnershipPolicy WHERE TargetKind = N'SAOP_PRODUCT') AS podjetje
  CROSS JOIN (VALUES (N'ProductCommercial.PackageLength'), (N'ProductCommercial.Volume')) AS polje(FieldName)
  WHERE NOT EXISTS (SELECT 1 FROM out.OwnershipPolicy AS policy
                    WHERE policy.OrganizationId = podjetje.OrganizationId AND policy.TargetKind = N'SAOP_PRODUCT'
                      AND policy.FieldName = polje.FieldName AND policy.Owner = N'PIM' AND policy.IsEnabled = 1)
)
  THROW 52985, N'300: dolžina ali prostornina ni last PIM v vseh podjetjih.', 1;
