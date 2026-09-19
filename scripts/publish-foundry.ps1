[CmdletBinding()]
param(
  [switch] $Publish,
  [string] $ManifestPath = (Join-Path $PSScriptRoot "..\module.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$releaseEndpoint = "https://foundryvtt.com/_api/packages/release_version/"
$resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifest = Get-Content -Raw -LiteralPath $resolvedManifestPath | ConvertFrom-Json

foreach ($field in @("id", "version", "download")) {
  if (-not $manifest.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace($manifest.$field)) {
    throw "The package manifest is missing the required '$field' field."
  }
}

if (-not $manifest.compatibility.minimum -or -not $manifest.compatibility.verified) {
  throw "The package manifest must define compatibility.minimum and compatibility.verified."
}

$releaseManifestUrl = $manifest.download -replace "/module\.zip(?:\?.*)?$", "/module.json"
if ($releaseManifestUrl -eq $manifest.download) {
  throw "The download URL must end in /module.zip so the version-specific manifest URL can be derived."
}

$escapedVersion = [regex]::Escape([string] $manifest.version)
if ($releaseManifestUrl -notmatch "/releases/download/v?$escapedVersion/") {
  throw "The release asset URL does not contain manifest version $($manifest.version)."
}

$notesUrl = $releaseManifestUrl -replace "/releases/download/([^/]+)/module\.json$", "/releases/tag/`$1"

Write-Host "Validating release assets for $($manifest.id) v$($manifest.version)..."
$remoteManifest = Invoke-RestMethod -Uri $releaseManifestUrl -Method Get
if ($remoteManifest.id -ne $manifest.id) {
  throw "The release manifest ID '$($remoteManifest.id)' does not match '$($manifest.id)'."
}
if ($remoteManifest.version -ne $manifest.version) {
  throw "The release manifest version '$($remoteManifest.version)' does not match '$($manifest.version)'."
}
if ($remoteManifest.download -ne $manifest.download) {
  throw "The release manifest download URL does not match the local package manifest."
}

$null = Invoke-WebRequest -Uri $manifest.download -Method Head

$releaseToken = [Environment]::GetEnvironmentVariable("FOUNDRY_RELEASE_TOKEN")
$secureToken = $null
$tokenPointer = [IntPtr]::Zero

if ([string]::IsNullOrWhiteSpace($releaseToken)) {
  if (-not [Environment]::UserInteractive) {
    throw "Set FOUNDRY_RELEASE_TOKEN when running non-interactively."
  }

  $secureToken = Read-Host "Foundry package release token" -AsSecureString
  $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
  $releaseToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
}

try {
  $headers = @{
    Authorization = $releaseToken
    Accept = "application/json"
    "Content-Type" = "application/json"
  }

  $maximumCompatibility = $manifest.compatibility.PSObject.Properties["maximum"]
  $compatibility = @{
    minimum = [string] $manifest.compatibility.minimum
    verified = [string] $manifest.compatibility.verified
    maximum = if ($maximumCompatibility) { [string] $maximumCompatibility.Value } else { "" }
  }

  $release = @{
    version = [string] $manifest.version
    manifest = $releaseManifestUrl
    notes = $notesUrl
    compatibility = $compatibility
  }

  $dryRunBody = @{
    id = [string] $manifest.id
    "dry-run" = $true
    release = $release
  } | ConvertTo-Json -Depth 5

  $dryRun = Invoke-RestMethod -Uri $releaseEndpoint -Method Post -Headers $headers -Body $dryRunBody
  if ($dryRun.status -ne "success") {
    throw "Foundry's release validation did not succeed."
  }

  Write-Host "Foundry dry run succeeded for $($manifest.id) v$($manifest.version)."

  if (-not $Publish) {
    Write-Host "No changes were published. Run again with -Publish to create the release."
    exit 0
  }

  $publishBody = @{
    id = [string] $manifest.id
    release = $release
  } | ConvertTo-Json -Depth 5

  $result = Invoke-RestMethod -Uri $releaseEndpoint -Method Post -Headers $headers -Body $publishBody
  if ($result.status -ne "success") {
    throw "Foundry did not report a successful package release."
  }

  Write-Host "Published $($manifest.id) v$($manifest.version) to Foundry VTT."
  Write-Host "Package management page: $($result.page)"
}
finally {
  if ($tokenPointer -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
  }

  $releaseToken = $null
  $secureToken = $null
}
