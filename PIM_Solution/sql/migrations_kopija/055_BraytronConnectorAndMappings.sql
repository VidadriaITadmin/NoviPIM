/*
  055 — Braytron kot drugi vir istih lastnosti.

  Zakaj je to samo register in nic kode: PIM.XmlFileWorker je splosen. Kaj naj bere, mu
  povedo tri spremenljivke okolja (PIM_XML_SOURCE_CODE, PIM_XML_ROOT,
  PIM_XML_ORGANIZATION_ID), obliko pa prebere iz teh tabel. Poti se ovrednotijo z
  XPathNavigator, torej polni XPath 1.0 — zato zna Braytronovo obliko

    <attribute><slug>ip</slug><title>IP</title><value>IP65</value></attribute>

  nasloviti s pogojem .//attribute[slug="ip"]/value/text(). Nowodvorski ima za vsako
  lastnost svoj element, Braytron eno samo obliko z razlocevalnim slug — obe konca v isti
  kanonicni kodi. Kanonicna koda je sticisce: NW attribute_light_source in Braytron
  slug=socket oba pisejo v ProductAttribute.Grlo.

  Vir: fixtures\bt\BRaytron_xml_2026_07_29.xml — 3.082 izdelkov, 66 razlicnih lastnosti.
  75 preslikav in 25 pretvorb.

  Ujemanje z nasim katalogom je po EAN (code_ean). Braytronov <code> je njihova sifra in
  ne nasa, zato se nanjo ne naslanjamo. Izdelek, ki ga ne vodimo, se preskoci — to ni
  napaka, dobaviteljev XML normalno vsebuje vec, kot imamo mi (glej 040).

  Pretvorbe, ki jih Nowodvorski ne rabi, Braytron pa:

    NUMBER/UNIT  Braytron pise vrednost in enoto v enem nizu ("30 mm", "10,8 kg"), predloga
                 pa ima za nekatere dve mesti. Kjer stolpec 'Enota ...' obstaja, se niz
                 razbije; kjer ga ni (npr. 'Zivljenjska doba' = "20000 h"), niz ostane cel,
                 da se enota ne izgubi.
    TRIM +       'Elektricni razred' pride kot " CLASS II" in "Class I" — isti dobavitelj
    STRIPPREFIX  pise isto stvar na vec nacinov.
    LOOKUP SL    stolpci s pripono SLO, enako kot pri Nowodvorskem.

  Kaj namenoma ni tu: slug=sensor_type ('Motion', 'PIR', 'Microwave') ni Da/Ne in ni isto
  kot stolpec 'Senzor gibanja'. Dokler ni odloceno, kaj naj bo, se ne preslika.

  Zagon zajema (datoteka je lahko kjerkoli, pot je nastavitev):

    $env:PIM_XML_SOURCE_CODE='BT_XML'
    $env:PIM_XML_ORGANIZATION_ID='2'
    $env:PIM_XML_ROOT='C:\Users\David\Desktop\PIM\NoviPIM\PIM_Solution\fixtures\bt'
    dotnet run --project workers\PIM.XmlFileWorker
*/

SET XACT_ABORT ON;

MERGE map.SourceConnector AS target
USING (VALUES (N'BT_XML', 2, N'FILE_XML')) AS source(SourceCode, OrganizationId, ConnectorType)
  ON target.SourceCode = source.SourceCode AND target.OrganizationId = source.OrganizationId
WHEN NOT MATCHED THEN
  INSERT (SourceCode, OrganizationId, ConnectorType, IsActive)
  VALUES (source.SourceCode, source.OrganizationId, source.ConnectorType, 1);

DECLARE @ConnectorId int =
  (SELECT SourceConnectorId FROM map.SourceConnector
   WHERE SourceCode = N'BT_XML' AND OrganizationId = 2);

IF @ConnectorId IS NULL
  THROW 52410, 'Konektor BT_XML ni nastal.', 1;

MERGE map.EntityMapping AS target
USING (VALUES (N'Attribute', N'/response/products/product')) AS source(EntityType, RecordXPath)
  ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
WHEN NOT MATCHED THEN
  INSERT (SourceConnectorId, EntityType, RecordXPath, IsActive)
  VALUES (@ConnectorId, source.EntityType, source.RecordXPath, 1);

DECLARE @Vir TABLE (SourceElement nvarchar(200), TargetFieldCode nvarchar(200), IsRequired bit);

/* Kljuc ujemanja. Brez njega zapisa ni mogoce povezati z izdelkom. */
INSERT @Vir (SourceElement, TargetFieldCode, IsRequired)
VALUES (N'code_ean/text()', N'Product.EAN', 1);

INSERT @Vir (SourceElement, TargetFieldCode, IsRequired)
SELECT vrednost.SourceElement, vrednost.TargetFieldCode, 0
FROM (VALUES
  (N'.//attribute[slug="socket"]/value/text()', N'ProductAttribute.Grlo')  /* stolpec 54 */,
  (N'.//attribute[slug="max-wattage"]/value/text()', N'ProductAttribute.Max moč sijalke')  /* stolpec 59 */,
  (N'.//attribute[slug="warranty"]/value/text()', N'ProductAttribute.Garancija')  /* stolpec 60 */,
  (N'.//attribute[slug="air_flow"]/value/text()', N'ProductAttribute.Zračni pretok')  /* stolpec 61 */,
  (N'.//attribute[slug="battery"]/value/text()', N'ProductAttribute.Baterija')  /* stolpec 67 */,
  (N'.//attribute[slug="battery_capacity"]/value/text()', N'ProductAttribute.Kapaciteta baterije')  /* stolpec 68 */,
  (N'.//attribute[slug="beam_angle"]/value/text()', N'ProductAttribute.Kot svetlobnega snopa')  /* stolpec 69 */,
  (N'.//attribute[slug="cable_cross_section"]/value/text()', N'ProductAttribute.Presek kabla')  /* stolpec 71 */,
  (N'.//attribute[slug="charging_time"]/value/text()', N'ProductAttribute.Čas polnjenja')  /* stolpec 76 */,
  (N'.//attribute[slug="charging_type"]/value/text()', N'ProductAttribute.Način polnjenja ANG')  /* stolpec 77 */,
  (N'.//attribute[slug="charging_type"]/value/text()', N'ProductAttribute.Način polnjenja SLO')  /* stolpec 78 */,
  (N'.//attribute[slug="current"]/value/text()', N'ProductAttribute.Nazivna jakost toka')  /* stolpec 79 */,
  (N'.//attribute[slug="voltage"]/value/text()', N'ProductAttribute.Nazivna napetost')  /* stolpec 80 */,
  (N'.//attribute[slug="wattage"]/value/text()', N'ProductAttribute.Nazivna moč')  /* stolpec 81 */,
  (N'.//attribute[slug="color_temperature"]/value/text()', N'ProductAttribute.Temperatura barve')  /* stolpec 83 */,
  (N'.//attribute[slug="color_rendering_index_cri"]/value/text()', N'ProductAttribute.Indeks barvnega videza (CRI)')  /* stolpec 96 */,
  (N'.//attribute[slug="cutout"]/value/text()', N'ProductAttribute.Izvrtina (cutout)')  /* stolpec 98 */,
  (N'.//attribute[slug="detection_angle"]/value/text()', N'ProductAttribute.Kot detekcije')  /* stolpec 99 */,
  (N'.//attribute[slug="detection_distance"]/value/text()', N'ProductAttribute.Razdalja detekcije')  /* stolpec 100 */,
  (N'.//attribute[slug="detection_speed"]/value/text()', N'ProductAttribute.Hitrost detekcije')  /* stolpec 101 */,
  (N'.//attribute[slug="diameter"]/value/text()', N'ProductAttribute.Premer')  /* stolpec 102 */,
  (N'.//attribute[slug="height"]/value/text()', N'ProductAttribute.Višina')  /* stolpec 103 */,
  (N'.//attribute[slug="height"]/value/text()', N'ProductAttribute.Enota višine')  /* stolpec 104 */,
  (N'.//attribute[slug="length"]/value/text()', N'ProductAttribute.Dolžina')  /* stolpec 105 */,
  (N'.//attribute[slug="length"]/value/text()', N'ProductAttribute.Enota dolžine')  /* stolpec 106 */,
  (N'.//attribute[slug="width"]/value/text()', N'ProductAttribute.Širina')  /* stolpec 107 */,
  (N'.//attribute[slug="width"]/value/text()', N'ProductAttribute.Enota širine')  /* stolpec 108 */,
  (N'.//attribute[slug="dimmable"]/value/text()', N'ProductAttribute.Zatemnljivo ANG')  /* stolpec 109 */,
  (N'.//attribute[slug="dimmable"]/value/text()', N'ProductAttribute.Zatemnljivo SLO')  /* stolpec 110 */,
  (N'.//attribute[slug="class"]/value/text()', N'ProductAttribute.Električni razred ANG')  /* stolpec 114 */,
  (N'.//attribute[slug="emergency_mode"]/value/text()', N'ProductAttribute.Režim nujne osvetlitve ANG')  /* stolpec 115 */,
  (N'.//attribute[slug="emergency_mode"]/value/text()', N'ProductAttribute.Režim nujne osvetlitve SLO')  /* stolpec 116 */,
  (N'.//attribute[slug="energy_efficiency_level"]/value/text()', N'ProductAttribute.Energijski razred')  /* stolpec 117 */,
  (N'.//attribute[slug="equivalent"]/value/text()', N'ProductAttribute.Ekvivalent')  /* stolpec 118 */,
  (N'.//attribute[slug="quse_lumen"]/value/text()', N'ProductAttribute.Svetlobni tok')  /* stolpec 120 */,
  (N'.//attribute[slug="gw"]/value/text()', N'ProductAttribute.Bruto teža (2)')  /* stolpec 124 */,
  (N'.//attribute[slug="gw"]/value/text()', N'ProductAttribute.Enota bruto teže (2)')  /* stolpec 125 */,
  (N'.//attribute[slug="icons"]/value/text()', N'ProductAttribute.Ikone')  /* stolpec 139 */,
  (N'.//attribute[slug="ik"]/value/text()', N'ProductAttribute.IK stopnja')  /* stolpec 140 */,
  (N'.//attribute[slug="installation_height"]/value/text()', N'ProductAttribute.Montažna višina')  /* stolpec 141 */,
  (N'.//attribute[slug="ip"]/value/text()', N'ProductAttribute.IP stopnja zaščite')  /* stolpec 142 */,
  (N'.//attribute[slug="lamp_shape"]/value/text()', N'ProductAttribute.Oblika svetilke ANG')  /* stolpec 143 */,
  (N'.//attribute[slug="lamp_shape"]/value/text()', N'ProductAttribute.Oblika svetilke SLO')  /* stolpec 144 */,
  (N'.//attribute[slug="body_color"]/value/text()', N'ProductAttribute.Prevladujoča barva ANG')  /* stolpec 145 */,
  (N'.//attribute[slug="body_color"]/value/text()', N'ProductAttribute.Prevladujoča barva SLO')  /* stolpec 146 */,
  (N'.//attribute[slug="material"]/value/text()', N'ProductAttribute.Prevladujoč material ANG')  /* stolpec 147 */,
  (N'.//attribute[slug="material"]/value/text()', N'ProductAttribute.Prevladujoč material SLO')  /* stolpec 148 */,
  (N'.//attribute[slug="lifetime"]/value/text()', N'ProductAttribute.Življenjska doba')  /* stolpec 157 */,
  (N'.//attribute[slug="light_source"]/value/text()', N'ProductAttribute.Vrsta svetlobnega vira ANG')  /* stolpec 158 */,
  (N'.//attribute[slug="light_source"]/value/text()', N'ProductAttribute.Vrsta svetlobnega vira SLO')  /* stolpec 159 */,
  (N'.//attribute[slug="lux"]/value/text()', N'ProductAttribute.Luks')  /* stolpec 160 */,
  (N'.//attribute[slug="model"]/value/text()', N'ProductAttribute.Model')  /* stolpec 161 */,
  (N'.//attribute[slug="motor_rotation"]/value/text()', N'ProductAttribute.Vrtenje motorja')  /* stolpec 162 */,
  (N'.//attribute[slug="nw"]/value/text()', N'ProductAttribute.Neto teža (2)')  /* stolpec 163 */,
  (N'.//attribute[slug="nw"]/value/text()', N'ProductAttribute.Enota neto teže (2)')  /* stolpec 164 */,
  (N'.//attribute[slug="noise"]/value/text()', N'ProductAttribute.Hrup')  /* stolpec 165 */,
  (N'.//attribute[slug="number_of_charging_cycles"]/value/text()', N'ProductAttribute.Število ciklov polnjenja')  /* stolpec 169 */,
  (N'.//attribute[slug="pcsctn"]/value/text()', N'ProductAttribute.Kosov na karton')  /* stolpec 171 */,
  (N'.//attribute[slug="package_height"]/value/text()', N'ProductAttribute.Višina paketa I')  /* stolpec 172 */,
  (N'.//attribute[slug="package_height"]/value/text()', N'ProductAttribute.Enota višine paketa I')  /* stolpec 175 */,
  (N'.//attribute[slug="package_length"]/value/text()', N'ProductAttribute.Dolžina paketa I')  /* stolpec 178 */,
  (N'.//attribute[slug="package_length"]/value/text()', N'ProductAttribute.Enota dolžine paketa I')  /* stolpec 181 */,
  (N'.//attribute[slug="package_width"]/value/text()', N'ProductAttribute.Širina paketa I')  /* stolpec 186 */,
  (N'.//attribute[slug="package_width"]/value/text()', N'ProductAttribute.Enota širine paketa I')  /* stolpec 189 */,
  (N'.//attribute[slug="power_factor"]/value/text()', N'ProductAttribute.Faktor moči')  /* stolpec 192 */,
  (N'.//attribute[slug="size"]/value/text()', N'ProductAttribute.Velikost')  /* stolpec 195 */,
  (N'.//attribute[slug="socket"]/value/text()', N'ProductAttribute.Podnožje / socket')  /* stolpec 196 */,
  (N'.//attribute[slug="solar_panel"]/value/text()', N'ProductAttribute.Solarni panel')  /* stolpec 199 */,
  (N'.//attribute[slug="solar_power"]/value/text()', N'ProductAttribute.Solarna moč')  /* stolpec 200 */,
  (N'.//attribute[slug="time_delay"]/value/text()', N'ProductAttribute.Časovna zakasnitev')  /* stolpec 204 */,
  (N'.//attribute[slug="type_of_cable"]/value/text()', N'ProductAttribute.Vrsta kabla')  /* stolpec 205 */,
  (N'.//attribute[slug="video"]/value/text()', N'ProductAttribute.Video')  /* stolpec 206 */,
  (N'.//attribute[slug="voltage"]/value/text()', N'ProductAttribute.Napetost')  /* stolpec 207 */,
  (N'.//attribute[slug="working_temperature"]/value/text()', N'ProductAttribute.Delovna temperatura')  /* stolpec 213 */,
  (N'.//attribute[slug="working_time"]/value/text()', N'ProductAttribute.Delovni čas')  /* stolpec 214 */
) AS vrednost(SourceElement, TargetFieldCode);

MERGE map.FieldMapping AS target
USING
(
  SELECT @ConnectorId AS SourceConnectorId, N'Attribute' AS EntityType,
    vir.SourceElement, vir.TargetFieldCode, vir.IsRequired
  FROM @Vir vir
) AS source
  ON target.SourceConnectorId = source.SourceConnectorId
    AND target.EntityType = source.EntityType
    AND target.SourceElement = source.SourceElement
    AND target.TargetFieldCode = source.TargetFieldCode
WHEN NOT MATCHED THEN
  INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive, MappingVersion)
  VALUES (source.SourceConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode,
          source.IsRequired, 1, 1);

DECLARE @Pretvorba TABLE (TargetFieldCode nvarchar(200), StepOrder int, TransformCode nvarchar(20), Argument nvarchar(400));
INSERT @Pretvorba (TargetFieldCode, StepOrder, TransformCode, Argument) VALUES
  (N'ProductAttribute.Način polnjenja SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Višina', 1, N'NUMBER', NULL),
  (N'ProductAttribute.Enota višine', 1, N'UNIT', NULL),
  (N'ProductAttribute.Dolžina', 1, N'NUMBER', NULL),
  (N'ProductAttribute.Enota dolžine', 1, N'UNIT', NULL),
  (N'ProductAttribute.Širina', 1, N'NUMBER', NULL),
  (N'ProductAttribute.Enota širine', 1, N'UNIT', NULL),
  (N'ProductAttribute.Zatemnljivo SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Električni razred ANG', 1, N'TRIM', NULL),
  (N'ProductAttribute.Električni razred ANG', 2, N'STRIPPREFIX', N'CLASS '),
  (N'ProductAttribute.Režim nujne osvetlitve SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Bruto teža (2)', 1, N'NUMBER', NULL),
  (N'ProductAttribute.Enota bruto teže (2)', 1, N'UNIT', NULL),
  (N'ProductAttribute.Oblika svetilke SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Prevladujoča barva SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Prevladujoč material SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Vrsta svetlobnega vira SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Neto teža (2)', 1, N'NUMBER', NULL),
  (N'ProductAttribute.Enota neto teže (2)', 1, N'UNIT', NULL),
  (N'ProductAttribute.Višina paketa I', 1, N'NUMBER', NULL),
  (N'ProductAttribute.Enota višine paketa I', 1, N'UNIT', NULL),
  (N'ProductAttribute.Dolžina paketa I', 1, N'NUMBER', NULL),
  (N'ProductAttribute.Enota dolžine paketa I', 1, N'UNIT', NULL),
  (N'ProductAttribute.Širina paketa I', 1, N'NUMBER', NULL),
  (N'ProductAttribute.Enota širine paketa I', 1, N'UNIT', NULL);

INSERT map.FieldTransform (FieldMappingId, StepOrder, TransformCode, Argument)
SELECT mapping.FieldMappingId, pretvorba.StepOrder, pretvorba.TransformCode, pretvorba.Argument
FROM @Pretvorba pretvorba
INNER JOIN map.FieldMapping mapping
  ON mapping.SourceConnectorId = @ConnectorId AND mapping.EntityType = N'Attribute'
    AND mapping.TargetFieldCode = pretvorba.TargetFieldCode
WHERE NOT EXISTS
(
  SELECT 1 FROM map.FieldTransform obstojeca
  WHERE obstojeca.FieldMappingId = mapping.FieldMappingId AND obstojeca.StepOrder = pretvorba.StepOrder
);

/* --- preverba ------------------------------------------------------------- */

IF NOT EXISTS
(
  SELECT 1 FROM map.FieldMapping
  WHERE SourceConnectorId = @ConnectorId AND EntityType = N'Attribute'
    AND TargetFieldCode = N'Product.EAN' AND IsRequired = 1 AND IsActive = 1
)
  THROW 52411, 'Braytron nima kljuca ujemanja po EAN.', 1;

IF
(
  SELECT COUNT(*) FROM map.FieldMapping
  WHERE SourceConnectorId = @ConnectorId AND EntityType = N'Attribute'
    AND TargetFieldCode LIKE N'ProductAttribute.%' AND IsActive = 1
) < 75
  THROW 52412, 'Preslikave lastnosti Braytrona niso vse nastale.', 1;
