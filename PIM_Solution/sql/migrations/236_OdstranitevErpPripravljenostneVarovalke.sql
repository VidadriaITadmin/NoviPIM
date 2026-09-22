/*
  236 - odstranitev varovalke "artikel ni pripravljen za ERP" (194/195).

  Uporabnik je na kartici izdelka poskusil hkrati popraviti dve manjkajoci obvezni SAOP polji
  (Knjizna skupina, Skupina popusta) na artiklu s 5 odprtimi blokirajocimi napakami. Oba poskusa
  je sprozilec out.TR_OutboxMessage_ErpQualityGate (194, popravljen v 195) zavrnil z 51497
  "Artikel ni pripravljen za ERP.". Popravek 195 izvzame iz preverbe samo polje, ki ga trenutno
  vpisano sporocilo samo popravlja - a pri VEC hkratnih blokirajocih napakah na istem artiklu
  ostane vsak posamezen popravek zavrnjen, ker sosednje, se neresene napake ostanejo v preverbi.
  Vsak nadaljnji popravek te izjeme (izvzemi cel nabor poljih trenutne oddaje, ne le enega) bi bil
  se ena zakrpa istega vzorca.

  Namesto tega (dogovor z uporabnikom, 2026-09-21): vsako polje - ERP ali ne - se vedno da urediti
  in uvrstiti v vrsto za SAOP. Ce artikel ni pripravljen, to ni vec razlog za zavrnitev vpisa,
  ampak samo stanje, ki ga uporabnik ze vidi na kartici ("caka odobritev" / vrsta za SAOP) - SAOP
  lastna validacija ob dejanskem posiljanju ostane edina preostala zavora.

  Sprozilec iz 194 je bil edina "neobhodna ERP varovalka" v celi odhodni poti - pokrival je
  enqueue IN vsak kasnejsi prehod stanja (odobritev iz out.ApproveOutboundBatch, claim iz
  out.ClaimItemDocument/out.ClaimItemDocumentByKey, retry). Z njegovo odstranitvijo izginejo vsi
  trije prehodi zavrnitve hkrati, ne le vstop v vrsto.

  val.IsProductChannelReady (194) in val.IsProductChannelReadyForField (195) gresta stran skupaj
  s sprozilcem - edini klicatelj obeh je bil ta sprozilec (glej opombo v 195), noben drug objekt
  v bazi ali aplikaciji ju ne uporablja (preverjeno: grep po sql/migrations in PIM.Intranet).

  Kaj OSTANE nespremenjeno - to ni razveljavitev migracije 194, samo umik ene varovalke iz nje:
    - val.ProductHold / val.SetProductHold (rocni zadrzek) ostaneta; se naprej izkljucujeta
      artikel iz spletnega izvoza (out.GetExportRows). Po tej migraciji rocni zadrzek ne vpliva
      vec na ERP vrsto (edina pot, po kateri je ERP kanal sploh vedel zanj, je bil ta sprozilec) -
      za ERP ostane samo se informativen, na nadzorni plosci kakovosti.
    - val.ProductChannelReadiness / intranet.GetQualityProducts (nadzorna plosca kakovosti,
      "5 blokirajocih napak" na kartici) ostaneta nespremenjena - blokirajoce napake se naprej
      stejejo in prikazujejo, samo vec ne zapirajo vrste.
*/
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF OBJECT_ID(N'out.TR_OutboxMessage_ErpQualityGate', N'TR') IS NOT NULL
  DROP TRIGGER out.TR_OutboxMessage_ErpQualityGate;

IF OBJECT_ID(N'val.IsProductChannelReadyForField', N'FN') IS NOT NULL
  DROP FUNCTION val.IsProductChannelReadyForField;

IF OBJECT_ID(N'val.IsProductChannelReady', N'FN') IS NOT NULL
  DROP FUNCTION val.IsProductChannelReady;

/* --- Preverbe -------------------------------------------------------- */

IF OBJECT_ID(N'out.TR_OutboxMessage_ErpQualityGate', N'TR') IS NOT NULL
  THROW 51502, '236: sprozilec ERP varovalke se vedno obstaja.', 1;

IF OBJECT_ID(N'val.IsProductChannelReady', N'FN') IS NOT NULL
   OR OBJECT_ID(N'val.IsProductChannelReadyForField', N'FN') IS NOT NULL
  THROW 51503, '236: funkciji pripravljenosti kanala se vedno obstajata.', 1;

/* Kar mora ostati: rocni zadrzek in nadzorna plosca kakovosti se ne smeta izgubiti mimogrede. */
IF OBJECT_ID(N'val.ProductHold', N'U') IS NULL OR OBJECT_ID(N'val.SetProductHold', N'P') IS NULL
  THROW 51504, '236: rocni zadrzek (val.ProductHold/SetProductHold) manjka.', 1;

IF OBJECT_ID(N'val.ProductChannelReadiness', N'V') IS NULL OR OBJECT_ID(N'intranet.GetQualityProducts', N'P') IS NULL
  THROW 51505, '236: nadzorna plosca kakovosti (ProductChannelReadiness/GetQualityProducts) manjka.', 1;
