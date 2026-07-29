param(
  [switch]$VerifyOnly,
  [string]$MigrationPath = (Join-Path $PSScriptRoot "..\sql\migrations")
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($env:PIM_CONNECTION_STRING)) {
  throw "Manjka okoljska spremenljivka PIM_CONNECTION_STRING. Connection string ni zapisan v repozitorij."
}

$solutionRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$arguments = @("run", "--project", (Join-Path $solutionRoot "src\PIM.Migrator\PIM.Migrator.csproj"), "--", "--create-database", "--migrations", (Resolve-Path $MigrationPath))
if ($VerifyOnly) {
  $arguments += "--verify"
}

dotnet @arguments
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}
