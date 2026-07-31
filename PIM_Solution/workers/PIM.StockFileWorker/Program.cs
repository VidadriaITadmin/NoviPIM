using PIM.StockFileWorker;

if (args.Length != 2 || !args[0].Equals("--fixture", StringComparison.OrdinalIgnoreCase))
{
  Console.Error.WriteLine("Uporaba: PIM.StockFileWorker --fixture <pot-do-datoteke>");
  return 2;
}
var path = Path.GetFullPath(args[1]);
var batch = path.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)
  ? await new BtXmlTransport().ReadFixtureAsync(path)
  : await new NwFtpTransport().ReadFixtureAsync(path);
Console.WriteLine($"Prebranih zapisov: {batch.Records.Count}; SHA-256: {batch.PayloadHash}");
return 0;
