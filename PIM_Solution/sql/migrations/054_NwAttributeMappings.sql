/*
  054 — preslikave lastnosti iz Nowodvorskega XML v atribute kataloga.

  Zakaj: register izvoza (045) ze ve, kateri stolpec Magento predloge nosi kateri
  atribut; manjkal je drugi konec — od kod atribut pride. Do zdaj je obstajala ena
  sama vrstica za atribute (attribute_symbol -> CategoryRequired), zato so bili vsi
  atributni stolpci izvoza prazni.

  Vir vsake vrstice je datoteka dobavitelja (fixtures\nw\products_en_US.xml, 2.619
  izdelkov, 64 razlicnih lastnosti), potrdil pa jih je uporabnik v
  docs\Magento_stolpci_ZA-POTRDITEV.csv. Nobena pot ni ugibana: vsaka obstaja v XML.

  106 preslikav in 15 pretvorb. Pretvorbe so tri vrste:

    LOOKUP SL  — stolpci s pripono SLO dobijo isti vir kot njihov ANG dvojcek in gredo
                 skozi slovar vrednosti (049). Cesar slovar ne zna, ostane v anglescini
                 in se zapise v map.MissingTranslation — to je delovni seznam, ne napaka.
    BOOL       — 'Svetilka vkljucuje svetlobni vir' in 'Senzor gibanja' sta v XML Yes/No,
                 v izvozu pa 1/0 (odlocitev uporabnika: prevoda ne rabita).
    PREFIX     — 'Simbol atributa' je sifra Nowodvorskega in dobi predpono 'NW.', da se
                 loci od nasih sifer.

  Kaj namenoma ni tu:
    - 'EAN koda' (stolpec 113) in 'Ime izdelka' (193) sta dvojnika stolpcev 2 oziroma
      4/5; dokler ni odloceno, ali naj bosta izpolnjena dvakrat, ostaneta prazna.
    - obstojeca vrstica attribute_symbol -> ProductAttribute.CategoryRequired ostane
      nedotaknjena, ceprav je ime zavajajoce (s kategorijo nima zveze): nanjo se sklicuje
      izvozni profil WEB_B2C_PRODUCTS iz migracije 005 in bi ga ugasnitev izpraznila.
      Ista vrednost zdaj tece se v 'Simbol atributa' s predpono.

  Migracija samo dodaja; rocna sprememba preslikave prezivi ponoven zagon.
*/

SET XACT_ABORT ON;

DECLARE @ConnectorId int =
  (SELECT SourceConnectorId FROM map.SourceConnector
   WHERE SourceCode = N'NW_XML' AND OrganizationId = 2 AND IsActive = 1);

IF @ConnectorId IS NULL
  THROW 52400, 'Konektor NW_XML za organizacijo 2 ne obstaja; najprej mora tece migracija 011.', 1;

DECLARE @Vir TABLE (SourceElement nvarchar(200), TargetFieldCode nvarchar(200));
INSERT @Vir (SourceElement, TargetFieldCode) VALUES
  (N'attributes/attribute_light_source/light_source_value/text()', N'ProductAttribute.Grlo')  /* stolpec 54 */,
  (N'attributes/attribute_lamp_includes_source_of_light/lamp_includes_source_of_light_value/text()', N'ProductAttribute.Svetilka vključuje svetlobni vir')  /* stolpec 56 */,
  (N'attributes/attribute_motion_sensor/motion_sensor_value/text()', N'ProductAttribute.Senzor gibanja')  /* stolpec 57 */,
  (N'attributes/attribute_maximum_wattage/maximum_wattage_value/text()', N'ProductAttribute.Max moč sijalke')  /* stolpec 59 */,
  (N'attributes/attribute_warranty/warranty_value/text()', N'ProductAttribute.Garancija')  /* stolpec 60 */,
  (N'attributes/attribute_application/application_value/text()', N'ProductAttribute.Uporaba ANG')  /* stolpec 62 */,
  (N'attributes/attribute_application/application_value/text()', N'ProductAttribute.Uporaba SLO')  /* stolpec 63 */,
  (N'attributes/attribute_assembly_method/assembly_method_value/text()', N'ProductAttribute.Način montaže ANG')  /* stolpec 64 */,
  (N'attributes/attribute_assembly_method/assembly_method_value/text()', N'ProductAttribute.Način montaže SLO')  /* stolpec 65 */,
  (N'attributes/attribute_symbol/text()', N'ProductAttribute.Simbol atributa')  /* stolpec 66 */,
  (N'attributes/attribute_beam_angle/beam_angle_value/text()', N'ProductAttribute.Kot svetlobnega snopa')  /* stolpec 69 */,
  (N'attributes/attribute_beam_angle/beam_angle_unit/text()', N'ProductAttribute.Enota kota svetlobnega snopa')  /* stolpec 70 */,
  (N'attributes/attribute_ceiling_cup_height/ceiling_cup_height_value/text()', N'ProductAttribute.Višina stropne kapice')  /* stolpec 72 */,
  (N'attributes/attribute_ceiling_cup_height/ceiling_cup_height_unit/text()', N'ProductAttribute.Enota višine stropne kapice')  /* stolpec 73 */,
  (N'attributes/attribute_ceiling_cup_width/ceiling_cup_width_value/text()', N'ProductAttribute.Širina stropne kapice')  /* stolpec 74 */,
  (N'attributes/attribute_ceiling_cup_width/ceiling_cup_width_unit/text()', N'ProductAttribute.Enota širine stropne kapice')  /* stolpec 75 */,
  (N'collection/text()', N'ProductAttribute.Kolekcija')  /* stolpec 82 */,
  (N'attributes/attribute_colour_temperature/colour_temperature_value/text()', N'ProductAttribute.Temperatura barve')  /* stolpec 83 */,
  (N'attributes/attribute_comments/comments_value/text()', N'ProductAttribute.Komentarji')  /* stolpec 84 */,
  (N'attributes/attribute_complementary_colour_i/complementary_colour_i_value/text()', N'ProductAttribute.Dopolnilna barva I ANG')  /* stolpec 85 */,
  (N'attributes/attribute_complementary_colour_i/complementary_colour_i_value/text()', N'ProductAttribute.Dopolnilna barva I SLO')  /* stolpec 86 */,
  (N'attributes/attribute_complementary_colour_ii/complementary_colour_ii_value/text()', N'ProductAttribute.Dopolnilna barva II ANG')  /* stolpec 87 */,
  (N'attributes/attribute_complementary_colour_ii/complementary_colour_ii_value/text()', N'ProductAttribute.Dopolnilna barva II SLO')  /* stolpec 88 */,
  (N'attributes/attribute_complementary_fabric_symbol_from_swatch_box_i/complementary_fabric_symbol_from_swatch_box_i_value/text()', N'ProductAttribute.Dopolnilni simbol tkanine iz vzorčne škatle I')  /* stolpec 89 */,
  (N'attributes/attribute_complementary_material_i/complementary_material_i_value/text()', N'ProductAttribute.Dopolnilni material I ANG')  /* stolpec 90 */,
  (N'attributes/attribute_complementary_material_i/complementary_material_i_value/text()', N'ProductAttribute.Dopolnilni material I SLO')  /* stolpec 91 */,
  (N'attributes/attribute_complementary_material_ii/complementary_material_ii_value/text()', N'ProductAttribute.Dopolnilni material II ANG')  /* stolpec 92 */,
  (N'attributes/attribute_complementary_material_ii/complementary_material_ii_value/text()', N'ProductAttribute.Dopolnilni material II SLO')  /* stolpec 93 */,
  (N'attributes/attribute_complementary_material_iii/complementary_material_iii_value/text()', N'ProductAttribute.Dopolnilni material III ANG')  /* stolpec 94 */,
  (N'attributes/attribute_complementary_material_iii/complementary_material_iii_value/text()', N'ProductAttribute.Dopolnilni material III SLO')  /* stolpec 95 */,
  (N'attributes/attribute_cri/cri_value/text()', N'ProductAttribute.Indeks barvnega videza (CRI)')  /* stolpec 96 */,
  (N'attributes/attribute_distance_from_wall/distance_from_wall_value/text()', N'ProductAttribute.Razdalja od stene')  /* stolpec 111 */,
  (N'attributes/attribute_distance_from_wall/distance_from_wall_unit/text()', N'ProductAttribute.Enota razdalje od stene')  /* stolpec 112 */,
  (N'attributes/attribute_electrical_security_class/electrical_security_class_value/text()', N'ProductAttribute.Električni razred ANG')  /* stolpec 114 */,
  (N'attributes/attribute_energy_efficiency_class/energy_efficiency_class_value/text()', N'ProductAttribute.Energijski razred')  /* stolpec 117 */,
  (N'attributes/attribute_fabric_symbol_from_swatch_box/fabric_symbol_from_swatch_box_value/text()', N'ProductAttribute.Simbol tkanine iz vzorčne škatle')  /* stolpec 119 */,
  (N'attributes/attribute_flux/flux_value/text()', N'ProductAttribute.Svetlobni tok')  /* stolpec 120 */,
  (N'attributes/attribute_flux/flux_unit/text()', N'ProductAttribute.Enota svetlobnega toka')  /* stolpec 121 */,
  (N'attributes/attribute_frequency/frequency_value/text()', N'ProductAttribute.Frekvenca')  /* stolpec 122 */,
  (N'attributes/attribute_frequency/frequency_unit/text()', N'ProductAttribute.Enota frekvence')  /* stolpec 123 */,
  (N'attributes/attribute_height_modification/height_modification_value/text()', N'ProductAttribute.Nastavitev višine')  /* stolpec 126 */,
  (N'attributes/attribute_height_modification_range/height_modification_range_value/text()', N'ProductAttribute.Razpon nastavitve višine')  /* stolpec 127 */,
  (N'attributes/attribute_height_modification_range/height_modification_range_unit/text()', N'ProductAttribute.Enota razpona nastavitve višine')  /* stolpec 128 */,
  (N'attributes/attribute_height_of__longer_arm/height_of__longer_arm_value/text()', N'ProductAttribute.Višina daljše roke')  /* stolpec 129 */,
  (N'attributes/attribute_height_of__longer_arm/height_of__longer_arm_unit/text()', N'ProductAttribute.Enota višine daljše roke')  /* stolpec 130 */,
  (N'attributes/attribute_height_of_shade__spot_light/height_of_shade__spot_light_value/text()', N'ProductAttribute.Višina senčnika reflektorja')  /* stolpec 131 */,
  (N'attributes/attribute_height_of_shade__spot_light/height_of_shade__spot_light_unit/text()', N'ProductAttribute.Enota višine senčnika reflektorja')  /* stolpec 132 */,
  (N'attributes/attribute_height_of_shorter_arm/height_of_shorter_arm_value/text()', N'ProductAttribute.Višina krajše roke')  /* stolpec 133 */,
  (N'attributes/attribute_height_of_shorter_arm/height_of_shorter_arm_unit/text()', N'ProductAttribute.Enota višine krajše roke')  /* stolpec 134 */,
  (N'attributes/attribute_hole_dimensions/hole_dimensions_value/text()', N'ProductAttribute.Dimenzije odprtine')  /* stolpec 135 */,
  (N'attributes/attribute_hole_dimensions/hole_dimensions_unit/text()', N'ProductAttribute.Enota dimenzij odprtine')  /* stolpec 136 */,
  (N'attributes/attribute_hole_shape/hole_shape_value/text()', N'ProductAttribute.Oblika odprtine ANG')  /* stolpec 137 */,
  (N'attributes/attribute_hole_shape/hole_shape_value/text()', N'ProductAttribute.Oblika odprtine SLO')  /* stolpec 138 */,
  (N'attributes/attribute_ip/ip_value/text()', N'ProductAttribute.IP stopnja zaščite')  /* stolpec 142 */,
  (N'attributes/attribute_leading_colour/leading_colour_value/text()', N'ProductAttribute.Prevladujoča barva ANG')  /* stolpec 145 */,
  (N'attributes/attribute_leading_colour/leading_colour_value/text()', N'ProductAttribute.Prevladujoča barva SLO')  /* stolpec 146 */,
  (N'attributes/attribute_leading_material/leading_material_value/text()', N'ProductAttribute.Prevladujoč material ANG')  /* stolpec 147 */,
  (N'attributes/attribute_leading_material/leading_material_value/text()', N'ProductAttribute.Prevladujoč material SLO')  /* stolpec 148 */,
  (N'attributes/attribute_lenght_of_base/lenght_of_base_value/text()', N'ProductAttribute.Dolžina podnožja')  /* stolpec 149 */,
  (N'attributes/attribute_lenght_of_base/lenght_of_base_unit/text()', N'ProductAttribute.Enota dolžine podnožja')  /* stolpec 150 */,
  (N'attributes/attribute_lenght_of_horizontal_arm/lenght_of_horizontal_arm_value/text()', N'ProductAttribute.Dolžina horizontalne roke')  /* stolpec 151 */,
  (N'attributes/attribute_lenght_of_horizontal_arm/lenght_of_horizontal_arm_unit/text()', N'ProductAttribute.Enota dolžine horizontalne roke')  /* stolpec 152 */,
  (N'attributes/attribute_lenght_of_shade/lenght_of_shade_value/text()', N'ProductAttribute.Dolžina senčnika')  /* stolpec 153 */,
  (N'attributes/attribute_lenght_of_shade/lenght_of_shade_unit/text()', N'ProductAttribute.Enota dolžine senčnika')  /* stolpec 154 */,
  (N'attributes/attribute_lenght_of_vertical_arm/lenght_of_vertical_arm_value/text()', N'ProductAttribute.Dolžina vertikalne roke')  /* stolpec 155 */,
  (N'attributes/attribute_lenght_of_vertical_arm/lenght_of_vertical_arm_unit/text()', N'ProductAttribute.Enota dolžine vertikalne roke')  /* stolpec 156 */,
  (N'attributes/attribute_lifetime/lifetime_value/text()', N'ProductAttribute.Življenjska doba')  /* stolpec 157 */,
  (N'attributes/attribute_light_sources_type/light_sources_type_value/text()', N'ProductAttribute.Vrsta svetlobnega vira ANG')  /* stolpec 158 */,
  (N'attributes/attribute_light_sources_type/light_sources_type_value/text()', N'ProductAttribute.Vrsta svetlobnega vira SLO')  /* stolpec 159 */,
  (N'attributes/attribute_number_of_light_sections/number_of_light_sections_value/text()', N'ProductAttribute.Število svetlobnih segmentov')  /* stolpec 166 */,
  (N'attributes/attribute_number_of_light_sources/number_of_light_sources_value/text()', N'ProductAttribute.Število svetlobnih virov')  /* stolpec 167 */,
  (N'attributes/attribute_the_number_of_packages/the_number_of_packages_value/text()', N'ProductAttribute.Število paketov')  /* stolpec 168 */,
  (N'attributes/attribute_pcn/pcn_value/text()', N'ProductAttribute.PCN')  /* stolpec 170 */,
  (N'attributes/attribute_package_height/package_height_value/text()', N'ProductAttribute.Višina paketa I')  /* stolpec 172 */,
  (N'attributes/attribute_package_height_ii/package_height_ii_value/text()', N'ProductAttribute.Višina paketa II')  /* stolpec 173 */,
  (N'attributes/attribute_package_height_iii/package_height_iii_value/text()', N'ProductAttribute.Višina paketa III')  /* stolpec 174 */,
  (N'attributes/attribute_package_height/package_height_unit/text()', N'ProductAttribute.Enota višine paketa I')  /* stolpec 175 */,
  (N'attributes/attribute_package_height_ii/package_height_ii_unit/text()', N'ProductAttribute.Enota višine paketa II')  /* stolpec 176 */,
  (N'attributes/attribute_package_height_iii/package_height_iii_unit/text()', N'ProductAttribute.Enota višine paketa III')  /* stolpec 177 */,
  (N'attributes/attribute_length_packing/length_packing_value/text()', N'ProductAttribute.Dolžina paketa I')  /* stolpec 178 */,
  (N'attributes/attribute_length_packing_ii/length_packing_ii_value/text()', N'ProductAttribute.Dolžina paketa II')  /* stolpec 179 */,
  (N'attributes/attribute_length_packing_iii/length_packing_iii_value/text()', N'ProductAttribute.Dolžina paketa III')  /* stolpec 180 */,
  (N'attributes/attribute_length_packing/length_packing_unit/text()', N'ProductAttribute.Enota dolžine paketa I')  /* stolpec 181 */,
  (N'attributes/attribute_length_packing_ii/length_packing_ii_unit/text()', N'ProductAttribute.Enota dolžine paketa II')  /* stolpec 182 */,
  (N'attributes/attribute_length_packing_iii/length_packing_iii_unit/text()', N'ProductAttribute.Enota dolžine paketa III')  /* stolpec 183 */,
  (N'attributes/attribute_packaging_volume/packaging_volume_value/text()', N'ProductAttribute.Volumen paketa')  /* stolpec 184 */,
  (N'attributes/attribute_packaging_volume/packaging_volume_unit/text()', N'ProductAttribute.Enota volumna paketa')  /* stolpec 185 */,
  (N'attributes/attribute_width_packaging/width_packaging_value/text()', N'ProductAttribute.Širina paketa I')  /* stolpec 186 */,
  (N'attributes/attribute_width_packaging_ii/width_packaging_ii_value/text()', N'ProductAttribute.Širina paketa II')  /* stolpec 187 */,
  (N'attributes/attribute_width_packaging_iii/width_packaging_iii_value/text()', N'ProductAttribute.Širina paketa III')  /* stolpec 188 */,
  (N'attributes/attribute_width_packaging/width_packaging_unit/text()', N'ProductAttribute.Enota širine paketa I')  /* stolpec 189 */,
  (N'attributes/attribute_width_packaging_ii/width_packaging_ii_unit/text()', N'ProductAttribute.Enota širine paketa II')  /* stolpec 190 */,
  (N'attributes/attribute_width_packaging_iii/width_packaging_iii_unit/text()', N'ProductAttribute.Enota širine paketa III')  /* stolpec 191 */,
  (N'attributes/attribute_power_factor/power_factor_value/text()', N'ProductAttribute.Faktor moči')  /* stolpec 192 */,
  (N'attributes/attribute_section_division/section_division_value/text()', N'ProductAttribute.Razdelitev na segmente')  /* stolpec 194 */,
  (N'attributes/attribute_soffit_ceiling_length/soffit_ceiling_length_value/text()', N'ProductAttribute.Dolžina spuščenega stropa')  /* stolpec 197 */,
  (N'attributes/attribute_soffit_ceiling_length/soffit_ceiling_length_unit/text()', N'ProductAttribute.Enota dolžine spuščenega stropa')  /* stolpec 198 */,
  (N'attributes/attribute_style/style_value/text()', N'ProductAttribute.Slog ANG')  /* stolpec 201 */,
  (N'attributes/attribute_style/style_value/text()', N'ProductAttribute.Slog SLO')  /* stolpec 202 */,
  (N'attributes/attribute_voltage/voltage_value/text()', N'ProductAttribute.Napetost')  /* stolpec 207 */,
  (N'attributes/attribute_voltage/voltage_unit/text()', N'ProductAttribute.Enota napetosti')  /* stolpec 208 */,
  (N'attributes/attribute_width_of_base/width_of_base_value/text()', N'ProductAttribute.Širina podnožja')  /* stolpec 209 */,
  (N'attributes/attribute_width_of_base/width_of_base_unit/text()', N'ProductAttribute.Enota širine podnožja')  /* stolpec 210 */,
  (N'attributes/attribute_width_of_shadespot_light/width_of_shadespot_light_value/text()', N'ProductAttribute.Širina senčnika reflektorja')  /* stolpec 211 */,
  (N'attributes/attribute_width_of_shadespot_light/width_of_shadespot_light_unit/text()', N'ProductAttribute.Enota širine senčnika reflektorja')  /* stolpec 212 */,
  (N'attributes/attribute_works_with/works_with_value/text()', N'ProductAttribute.Združljivo z')  /* stolpec 215 */;

MERGE map.FieldMapping AS target
USING
(
  SELECT @ConnectorId AS SourceConnectorId, N'Attribute' AS EntityType, vir.SourceElement, vir.TargetFieldCode
  FROM @Vir vir
) AS source
  ON target.SourceConnectorId = source.SourceConnectorId
    AND target.EntityType = source.EntityType
    AND target.SourceElement = source.SourceElement
    AND target.TargetFieldCode = source.TargetFieldCode
WHEN NOT MATCHED THEN
  INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive, MappingVersion)
  VALUES (source.SourceConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, 0, 1, 1);

DECLARE @Pretvorba TABLE (TargetFieldCode nvarchar(200), StepOrder int, TransformCode nvarchar(20), Argument nvarchar(400));
INSERT @Pretvorba (TargetFieldCode, StepOrder, TransformCode, Argument) VALUES
  (N'ProductAttribute.Svetilka vključuje svetlobni vir', 1, N'BOOL', N'Yes;Da;True;1'),
  (N'ProductAttribute.Senzor gibanja', 1, N'BOOL', N'Yes;Da;True;1'),
  (N'ProductAttribute.Uporaba SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Način montaže SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Simbol atributa', 1, N'PREFIX', N'NW.'),
  (N'ProductAttribute.Dopolnilna barva I SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Dopolnilna barva II SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Dopolnilni material I SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Dopolnilni material II SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Dopolnilni material III SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Oblika odprtine SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Prevladujoča barva SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Prevladujoč material SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Vrsta svetlobnega vira SLO', 1, N'LOOKUP', N'SL'),
  (N'ProductAttribute.Slog SLO', 1, N'LOOKUP', N'SL');

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

IF
(
  SELECT COUNT(*) FROM map.FieldMapping
  WHERE SourceConnectorId = @ConnectorId AND EntityType = N'Attribute'
    AND TargetFieldCode LIKE N'ProductAttribute.%' AND IsActive = 1
) < 106
  THROW 52401, 'Preslikave lastnosti Nowodvorskega niso vse nastale.', 1;
