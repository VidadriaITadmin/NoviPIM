// Sprozi prenos datoteke brez drugega klika uporabnika: izvoz v ozadju (ExportJobService) obvesti
// stran, ko je zvezek gotov, stran pa preko tega pokliče prenos na isti nacin, kot bi ga sprozil
// klik na povezavo s href na to URL — brskalnik zato ravna z njim enako (Content-Disposition iz
// odgovora strežnika pove, da gre za prenos, ne za navigacijo).
window.pimDownloadFile = function (url) {
  const link = document.createElement('a');
  link.href = url;
  link.rel = 'noopener';
  document.body.appendChild(link);
  link.click();
  link.remove();
};
