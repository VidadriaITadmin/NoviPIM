/*
  298 — kartica artikla: dolžina in prostornina gresta v SAOP kot ostala logistična polja.

  Uporabnik 2026-09-28: »dej vse v oblačke in pa da se da vse urejat, nič zaklepat. Program mora
  sam zaznati, če gre za spremembo SAOP polja ali ne, in mora potem artikel v čakalno vrsto.«

  Kaj je bilo narobe: zajem iz SAOP bere PropertiesData/ItemLength (ProductCommercial.PackageLength)
  in PropertiesData/ItemVolumePerUnit (ProductCommercial.Volume) že od 057, register pisljivih polj
  out.SaopXmlField pa ju ni imel — širina in višina sta bili urejivi, dolžina in prostornina pa na
  kartici zaklenjeni (docs/PRIMERJAVA_PIM_IN_PIM_TEST.md, »Y in Z sta, X ni«). Specifikacija SAOP
  (docs/Povezave_virov_in_sistemov/SAOP_API_swagger_v2.json, PropertiesData) obe polji sprejme.

  Kaj naredi:
    - doda dve vrstici v register (SAOP_PRODUCT, PropertiesData, decimal8, ni obvezno ob dodajanju).
      Od tu naprej ju kartica, uvoz delovnega lista in /saop/zgodovina obravnavajo kot vsako drugo
      SAOP polje: PIM takoj (pim.SaveProductErpFieldsBulk ju že pozna), v SAOP po odobritvi.

  Česa NE naredi: nič ne pošlje v SAOP. Sporočilo nastane šele, ko kdo polje spremeni, in čaka
  odobritev na strani Izhod v SAOP.

  Ročni korak: ne.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM out.SaopXmlField WHERE TargetKind = N'SAOP_PRODUCT' AND Section = N'PropertiesData' AND ElementName = N'ItemLength')
  INSERT out.SaopXmlField(TargetKind, Section, ElementName, FieldKey, SortOrder, IsAddMandatory, ValueFormat, TrueValue, FalseValue, IsEnabled, UpdatedBy)
  VALUES (N'SAOP_PRODUCT', N'PropertiesData', N'ItemLength', N'ProductCommercial.PackageLength', 425, 0, N'decimal8', NULL, NULL, 1, N'migracija 298');

IF NOT EXISTS (SELECT 1 FROM out.SaopXmlField WHERE TargetKind = N'SAOP_PRODUCT' AND Section = N'PropertiesData' AND ElementName = N'ItemVolumePerUnit')
  INSERT out.SaopXmlField(TargetKind, Section, ElementName, FieldKey, SortOrder, IsAddMandatory, ValueFormat, TrueValue, FalseValue, IsEnabled, UpdatedBy)
  VALUES (N'SAOP_PRODUCT', N'PropertiesData', N'ItemVolumePerUnit', N'ProductCommercial.Volume', 415, 0, N'decimal8', NULL, NULL, 1, N'migracija 298');

IF (SELECT COUNT(*) FROM out.SaopXmlField
    WHERE TargetKind = N'SAOP_PRODUCT' AND IsEnabled = 1
      AND FieldKey IN (N'ProductCommercial.PackageLength', N'ProductCommercial.Volume')) <> 2
  THROW 52980, N'298: dolžina in prostornina nista v registru pisljivih polj SAOP.', 1;
