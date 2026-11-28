# 发布构建：固定打 arm64-v8a / armeabi-v7a / x86_64 三个单 ABI Android 包。
# 不使用 --split-per-abi，避免 Flutter 给 versionCode 叠加 1000×ABI 偏移。
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Flutter/Gradle 会把 WARNING 写到 stderr。Windows PowerShell 在 Stop 模式下
# 会把原生命令的 stderr 当成终止错误，即使进程实际退出码是 0。这里统一把
# 原生输出转成普通文本，再按 $LASTEXITCODE 判断真实结果。
function Invoke-Flutter {
  param([string[]]$Arguments)
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & flutter @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $old
  }
  if ($code -ne 0) { throw "Flutter 构建失败（$code）：$($Arguments -join ' ')" }
}

$versionLine = Get-Content 'pubspec.yaml' |
  Where-Object { $_ -match '^version:' } |
  Select-Object -First 1
$version = ($versionLine -replace '^version:\s*', '').Trim()
$versionName = ($version -split '\+')[0]
$dest = Join-Path (Split-Path -Parent $root) 'release'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$targets = @(
  @{ Platform = 'android-arm64'; Abi = 'arm64-v8a' },
  @{ Platform = 'android-arm'; Abi = 'armeabi-v7a' },
  @{ Platform = 'android-x64'; Abi = 'x86_64' }
)

foreach ($target in $targets) {
  Invoke-Flutter @(
    'build', 'apk', '--release',
    '--target-platform', $target.Platform,
    "--android-project-arg=tbankTargetAbis=$($target.Abi)"
  )
  $apk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
  $out = Join-Path $dest "TBank-v$versionName-android-$($target.Abi).apk"
  Copy-Item $apk $out -Force
  Write-Host "已生成：$out"
}

$env:PATH = "D:\tools\nuget;$env:PATH"
Invoke-Flutter @('build', 'windows', '--release')
$winDir = Join-Path $root 'build\windows\x64\runner\Release'
$winZip = Join-Path $dest "TBank-v$versionName-windows-x64.zip"
Compress-Archive -Path "$winDir\*" -DestinationPath $winZip -CompressionLevel Optimal -Force
Write-Host "已生成：$winZip"
Write-Host "发布版本：$version"
