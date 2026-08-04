# Trenutno stanje strani

## Globalno

- `MainLayout.razor` in `NavMenu.razor` že imata začetno temno navigacijo in zgornjo vrstico, vendar vsebujeta statični prikaz organizacije, jezika, iskalnega namiga, začetnice in imena uporabnika.
- Favicon oziroma Blazor znak še ni potrjeno nadomeščen s PIM identiteto.
- Večina vsebinskih strani uporablja osnovne Bootstrap tabele oziroma obrazce in zato ni vizualno skladna s potrjenimi UX slikami.

## Strani z branjem iz baze

| Pot | Stran | Trenutni podatkovni vir | Stanje UX |
|---|---|---|---|
| `/nadzorna-plosca` | Nadzorna plošča | `intranet.GetDashboard` | Delno stilizirana; ima statične odstotke in nepopolne sklope. |
| `/izdelki` | Izdelki | `intranet.GetProducts` | Osnovna tabela. |
| `/izdelki/{id}` | Izdelek | `intranet.GetProductDetail` | Osnovni prikaz profilov. |
| `/stranke` | Stranke | `intranet.GetCustomers` | Osnovna tabela. |
| `/stranke/{id}` | Stranka | `intranet.GetCustomerDetail` | Osnovni obrazec; zapisi se shranjujejo v bazo. |
| `/zaloge` | Zaloga | `intranet.GetStocks` | Osnovna tabela. |
| `/napake-validacije` | Kakovost | `intranet.GetValidationIssues` | Osnovna tabela. |
| `/karantena` | Karantena | `intranet.GetRawQuarantine` | Osnovna tabela. |
| `/teki-obdelave` | Uvozi/procesi | `intranet.GetPipelineRuns` | Osnovna tabela. |
| `/outbound` | Izvozi | `intranet.GetOutboundMessages` | Osnovna operativna tabela. |
| `/system/integracije` | Sistem | `intranet.GetSystemIntegrations` | Osnovne tabele in akcije. |
| `/system/uporabniki` | Uporabniki | AD + intranet uporabniki | Osnovni administrativni obrazec. |
| `/pravila-popustov` | Pravila/cene | B2B postopki | Osnovni obrazci in tabele. |

Strani `Counter`, `Home`, `Weather` in `Error` niso PIM delovni tokovi. Pred odstranitvijo ali preusmeritvijo se preveri, ali so javno dosegljive oziroma testirane.
