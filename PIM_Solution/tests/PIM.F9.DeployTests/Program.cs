var root=FindRoot();var deploy=Path.Combine(root,"deploy");var failures=new List<string>();
Check("Publish-Intranet.ps1",new[]{"SupportsShouldProcess","WhatIf","win-x64","--self-contained true","app_offline.htm","appsettings.Local.json","backup","rollback","health"});
Check("Install-Workers.ps1",new[]{"SupportsShouldProcess","WhatIf","LocalSystem","PIM.Operations","New-Service"});
Check("Configure-ScheduledTasks.ps1",new[]{"SupportsShouldProcess","WhatIf","Register-ScheduledTask","ServiceAccount","PIM.Watchdog","PIM.AlertDispatcher"});
Check("README-Windows.md",new[]{"Prenos","Skrivnosti","SQL","worker","IIS","Povrnitev","resničnimi podatki","najmanjš"});
if(failures.Count>0){failures.ForEach(Console.Error.WriteLine);return 1;}Console.WriteLine("F9 deploy: pogodba skriptov in navodil PASS.");return 0;
void Check(string file,IEnumerable<string> values){var path=Path.Combine(deploy,file);if(!File.Exists(path)){failures.Add("Manjka "+file);return;}var text=File.ReadAllText(path);foreach(var value in values)if(!text.Contains(value,StringComparison.OrdinalIgnoreCase))failures.Add($"{file} manjka: {value}");}
string FindRoot(){var current=new DirectoryInfo(Directory.GetCurrentDirectory());while(current is not null){if(Directory.Exists(Path.Combine(current.FullName,"sql","migrations")))return current.FullName;current=current.Parent;}throw new InvalidOperationException("PIM_Solution ni najden.");}
