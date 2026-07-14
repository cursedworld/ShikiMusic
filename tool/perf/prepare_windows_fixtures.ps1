[CmdletBinding()]
param(
  [string]$SourceDataDirectory = "$env:USERPROFILE\Documents\ShikiMusic",
  [string]$OutputDirectory = ".omx\perf\data",
  [int]$SourceTrackId = 62,
  [int]$Video30TrackId = 62030,
  [int]$Video60TrackId = 62060,
  [int]$DownloadTrackId = 62070,
  [int]$FixtureServerPort = 48765,
  [string]$Ffmpeg = "E:\ffmpeg\bin\ffmpeg.exe",
  [string]$Ffprobe = "E:\ffmpeg\bin\ffprobe.exe",
  [string]$LargeDownloadFixture = "E:\Player\music_server\media\tracks\Computer_Clan_-_What_is_APFS_-_The_Apple_File_System_Explained.mp3",
  [string]$LargeVideoFixture = "E:\Player\music_server\media\clips\video_109.mp4"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-TextAtomic {
  param(
    [string]$Path,
    [string]$Contents
  )

  $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
  $backupPath = "$Path.$([Guid]::NewGuid().ToString('N')).bak"
  try {
    [IO.File]::WriteAllText($temporaryPath, $Contents, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) {
      [IO.File]::Replace($temporaryPath, $Path, $backupPath)
    }
    else {
      [IO.File]::Move($temporaryPath, $Path)
    }
  }
  finally {
    if ([IO.File]::Exists($temporaryPath)) {
      [IO.File]::Delete($temporaryPath)
    }
    if ([IO.File]::Exists($backupPath)) {
      [IO.File]::Delete($backupPath)
    }
  }
}

function Write-JsonAtomic {
  param(
    [string]$Path,
    [object]$Value
  )

  Write-TextAtomic -Path $Path -Contents ($Value | ConvertTo-Json -Depth 100 -Compress)
}

function Write-JsonTemplatePair {
  param(
    [string]$Name,
    [object]$Value
  )

  Write-JsonAtomic -Path (Join-Path $resolvedOutput "$Name.template.json") -Value $Value
  Write-JsonAtomic -Path (Join-Path $resolvedOutput "$Name.json") -Value $Value
}

function Write-TextTemplatePair {
  param(
    [string]$Name,
    [string]$Contents
  )

  Write-TextAtomic -Path (Join-Path $resolvedOutput "$Name.template.json") -Contents $Contents
  Write-TextAtomic -Path (Join-Path $resolvedOutput "$Name.json") -Contents $Contents
}

function Convert-RationalRate {
  param([string]$Value)

  $parts = $Value.Split('/')
  if ($parts.Count -ne 2 -or [double]$parts[1] -eq 0) {
    throw "Invalid ffprobe frame rate '$Value'."
  }
  return [double]$parts[0] / [double]$parts[1]
}

function Assert-H264Fixture {
  param(
    [string]$Path,
    [double]$MinimumFps,
    [double]$MaximumFps
  )

  $probeJson = & $ffprobePath -v error -select_streams v:0 -show_entries stream=codec_name,pix_fmt,width,height,avg_frame_rate -of json $Path | Out-String
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($probeJson)) {
    throw "ffprobe failed for fixture: $Path"
  }
  $probe = $probeJson | ConvertFrom-Json
  $stream = @($probe.streams)[0]
  if ($null -eq $stream -or $stream.codec_name -ne "h264" -or $stream.pix_fmt -ne "yuv420p") {
    throw "Fixture must be H.264/yuv420p: $Path"
  }
  if ([int]$stream.height -gt 480) {
    throw "Fixture height exceeds 480p: $Path"
  }
  $fps = Convert-RationalRate -Value ([string]$stream.avg_frame_rate)
  if ($fps -lt $MinimumFps -or $fps -gt $MaximumFps) {
    throw "Fixture FPS $fps is outside [$MinimumFps, $MaximumFps]: $Path"
  }
}

function Copy-TrackSidecar {
  param(
    [string]$Extension,
    [int]$TargetTrackId
  )

  $source = Join-Path $SourceDataDirectory "track_$SourceTrackId.$Extension"
  if (-not [IO.File]::Exists($source) -or (Get-Item -LiteralPath $source).Length -le 0) {
    throw "Required non-empty .$Extension sidecar is missing for source track $SourceTrackId."
  }
  Copy-Item -LiteralPath $source -Destination (Join-Path $resolvedOutput "track_$TargetTrackId.$Extension") -Force
}

function Copy-Cover {
  param([int]$TargetTrackId)

  $sourceCover = Get-ChildItem -LiteralPath $SourceDataDirectory -Filter "cover_$SourceTrackId`_*" -File | Select-Object -First 1
  if ($null -eq $sourceCover) {
    throw "No local cover for source track $SourceTrackId."
  }
  $suffix = $sourceCover.Name.Substring("cover_$SourceTrackId".Length)
  Copy-Item -LiteralPath $sourceCover.FullName -Destination (Join-Path $resolvedOutput "cover_$TargetTrackId$suffix") -Force
}

function Copy-TrackObject {
  param(
    [object]$Source,
    [int]$TargetTrackId,
    [string]$Title
  )

  $copy = $Source | ConvertTo-Json -Depth 100 | ConvertFrom-Json
  $copy.id = $TargetTrackId
  $copy.title = $Title
  $copy.audio_file = "benchmark-local-audio"
  $copy.video_file = "benchmark-local-video"
  return $copy
}

function Copy-RepeatedFixture {
  param(
    [string]$Source,
    [string]$Destination,
    [long]$MinimumBytes
  )

  $output = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    while ($output.Length -lt $MinimumBytes) {
      $input = [IO.File]::OpenRead($Source)
      try {
        $input.CopyTo($output)
      }
      finally {
        $input.Dispose()
      }
    }
    $output.Flush($true)
  }
  finally {
    $output.Dispose()
  }
}

$resolvedSource = (Resolve-Path -LiteralPath $SourceDataDirectory).Path
$SourceDataDirectory = $resolvedSource
$resolvedOutput = [IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputDirectory))
$repositoryPerfRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) ".omx\perf"))
$requiredOutputPrefix = $repositoryPerfRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $resolvedOutput.StartsWith($requiredOutputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Benchmark output must stay under $repositoryPerfRoot."
}
$sourcePrefix = $resolvedSource.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$outputPrefix = $resolvedOutput.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($resolvedOutput.Equals($resolvedSource, [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedOutput.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedSource.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Benchmark source and output directories must not overlap."
}
[IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null

$catalogPath = Join-Path $SourceDataDirectory "offline_tracks.json"
$catalog = [IO.File]::ReadAllText($catalogPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
$sourceTrack = $catalog | Where-Object { $_.id -eq $SourceTrackId } | Select-Object -First 1
if ($null -eq $sourceTrack) {
  throw "Track $SourceTrackId is absent from $catalogPath."
}

$sourceVideo = Join-Path $SourceDataDirectory "video_$SourceTrackId.mp4"
if (-not [IO.File]::Exists($sourceVideo)) {
  throw "Local video fixture is missing: $sourceVideo"
}
$video30Path = Join-Path $resolvedOutput "video_$Video30TrackId.mp4"
$video60Path = Join-Path $resolvedOutput "video_$Video60TrackId.mp4"
$downloadAudioPath = Join-Path $resolvedOutput "download_fixture.mp3"
$downloadVideoPath = Join-Path $resolvedOutput "download_fixture.mp4"
$downloadCoverPath = Join-Path $resolvedOutput "download_fixture_cover.jpg"

Copy-Item -LiteralPath $sourceVideo -Destination $video30Path -Force
Copy-TrackSidecar -Extension "mp3" -TargetTrackId $Video30TrackId
Copy-TrackSidecar -Extension "lrc" -TargetTrackId $Video30TrackId
Copy-Cover -TargetTrackId $Video30TrackId

Copy-TrackSidecar -Extension "mp3" -TargetTrackId $Video60TrackId
Copy-TrackSidecar -Extension "lrc" -TargetTrackId $Video60TrackId
Copy-Cover -TargetTrackId $Video60TrackId

$ffmpegPath = (Resolve-Path -LiteralPath $Ffmpeg).Path
$ffprobePath = (Resolve-Path -LiteralPath $Ffprobe).Path
& $ffmpegPath -hide_banner -loglevel error -y -i $sourceVideo -t 60 -vf "fps=60" -an -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -movflags +faststart $video60Path
if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($video60Path)) {
  throw "ffmpeg failed to create the 60 FPS fixture."
}

Assert-H264Fixture -Path $video30Path -MinimumFps 29 -MaximumFps 30.1
Assert-H264Fixture -Path $video60Path -MinimumFps 59 -MaximumFps 60.1

$largeFixturePath = (Resolve-Path -LiteralPath $LargeDownloadFixture).Path
$largeVideoFixturePath = (Resolve-Path -LiteralPath $LargeVideoFixture).Path
if ((Get-Item -LiteralPath $largeFixturePath).Length -le 0) {
  throw "Large MP3 fixture is empty: $largeFixturePath"
}
Assert-H264Fixture -Path $largeVideoFixturePath -MinimumFps 1 -MaximumFps 60.1
Copy-RepeatedFixture -Source $largeFixturePath -Destination $downloadAudioPath -MinimumBytes (128MB)
Copy-RepeatedFixture -Source $largeVideoFixturePath -Destination $downloadVideoPath -MinimumBytes (128MB)

$sourceCover = Get-ChildItem -LiteralPath $SourceDataDirectory -Filter "cover_$SourceTrackId`_*" -File | Select-Object -First 1
if ($null -eq $sourceCover) {
  throw "No local cover for source track $SourceTrackId."
}
Copy-Item -LiteralPath $sourceCover.FullName -Destination $downloadCoverPath -Force

$video30Track = Copy-TrackObject -Source $sourceTrack -TargetTrackId $Video30TrackId -Title "Benchmark local H.264 30 FPS"
$video60Track = Copy-TrackObject -Source $sourceTrack -TargetTrackId $Video60TrackId -Title "Benchmark local H.264 60 FPS"
$downloadTrack = Copy-TrackObject -Source $sourceTrack -TargetTrackId $DownloadTrackId -Title "Benchmark large MP3 and MP4 download"
$downloadTrack.audio_file = "http://127.0.0.1:$FixtureServerPort/download_fixture.mp3"
$downloadTrack.video_file = "http://127.0.0.1:$FixtureServerPort/download_fixture.mp4"
$downloadTrack.album.cover = "http://127.0.0.1:$FixtureServerPort/download_fixture_cover.jpg"
$fixtureCatalog = @($video30Track, $video60Track, $downloadTrack)

Write-JsonTemplatePair -Name "offline_tracks" -Value $fixtureCatalog
$appState = [ordered]@{
  volume = 0.1
  loopMode = 2
  playingIndex = 0
  playingQueue = $fixtureCatalog
  position = 0
  isShuffled = $false
  unshuffledQueue = @()
}
Write-JsonTemplatePair -Name "app_state" -Value $appState
$settings = [ordered]@{
  themeColor = "color_red"
  language = "ru"
  vinylRotation = $false
  playVideoClip = $false
  customBackground = $null
  accentColor = $null
}
Write-JsonTemplatePair -Name "shiki_settings" -Value $settings
Write-TextTemplatePair -Name "liked_tracks" -Contents "[]"
Write-TextTemplatePair -Name "my_playlists" -Contents "[]"

Write-Host "Prepared isolated benchmark data: $resolvedOutput"
Write-Host "30 FPS fixture: $video30Path"
Write-Host "60 FPS fixture: $video60Path"
Write-Host "Large MP3 fixture copy: $downloadAudioPath"
Write-Host "Large MP4 fixture copy: $downloadVideoPath"
