[CmdletBinding()]
param(
  [switch] $Draft,
  [switch] $Prerelease,
  [string] $ManifestPath = (Join-Path $PSScriptRoot "..\module.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw "GitHub CLI (gh) is required. Install it from https://cli.github.com/ and run this script again."
}

& gh auth status --hostname github.com 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
  Write-Host "GitHub authentication is required. Opening the GitHub CLI web login..."
  & gh auth login --hostname github.com --git-protocol https --web
  if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI authentication did not complete successfully."
  }
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifest = Get-Content -Raw -LiteralPath $resolvedManifestPath | ConvertFrom-Json

foreach ($field in @("id", "title", "version", "url", "download")) {
  if (-not $manifest.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace($manifest.$field)) {
    throw "The package manifest is missing the required '$field' field."
  }
}

if ($manifest.url -notmatch "^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$") {
  throw "The package URL must identify a GitHub repository."
}

$owner = $Matches[1]
$repository = $Matches[2]
$repositoryName = "$owner/$repository"
$tag = "v$($manifest.version)"
$expectedDownloadUrl = "https://github.com/$repositoryName/releases/download/$tag/module.zip"

if ($manifest.download -ne $expectedDownloadUrl) {
  throw "The manifest download URL must be '$expectedDownloadUrl'."
}

$workingTreeStatus = & git -C $repositoryRoot status --porcelain
if ($LASTEXITCODE -ne 0) {
  throw "Unable to inspect the Git working tree."
}
if ($workingTreeStatus) {
  throw "The Git working tree must be clean before creating a release. Commit or stash the current changes."
}

$headCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($headCommit)) {
  throw "Unable to resolve the current Git commit."
}

# Verify that the exact commit is available to GitHub before creating its tag.
& gh api "repos/$repositoryName/commits/$headCommit" --silent
if ($LASTEXITCODE -ne 0) {
  throw "The current commit is not available on GitHub. Push it before creating the release."
}

& gh release view $tag --repo $repositoryName 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
  throw "GitHub release $tag already exists."
}

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("narratron-release-" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $temporaryDirectory

try {
  $zipPath = Join-Path $temporaryDirectory "module.zip"
  $packageItems = @("module.json", "README.md", "scripts", "styles", "templates") |
    ForEach-Object { Join-Path $repositoryRoot $_ }

  foreach ($item in $packageItems) {
    if (-not (Test-Path -LiteralPath $item)) {
      throw "Required package item does not exist: $item"
    }
  }

  Compress-Archive -LiteralPath $packageItems -DestinationPath $zipPath

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
  try {
    if (-not $archive.GetEntry("module.json")) {
      throw "The generated ZIP does not contain module.json at its root."
    }
  }
  finally {
    $archive.Dispose()
  }

  $arguments = @(
    "release", "create", $tag,
    $resolvedManifestPath, $zipPath,
    "--repo", $repositoryName,
    "--target", $headCommit,
    "--title", "$($manifest.title) $tag",
    "--generate-notes"
  )

  if ($Draft) {
    $arguments += "--draft"
  }
  if ($Prerelease) {
    $arguments += "--prerelease"
  }

  & gh @arguments
  if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI failed to create release $tag."
  }

  Write-Host "Created GitHub release $tag with module.json and module.zip."
}
finally {
  if (Test-Path -LiteralPath $temporaryDirectory) {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
  }
}
