# JO-ENWSim 打包脚本
# 产物统一进 dist/（见 AGENTS.md 规则 7）
#
# 用法（用 pwsh，即 PowerShell 7）：
#   pwsh -ExecutionPolicy Bypass -File scripts\build.ps1
#   pwsh -ExecutionPolicy Bypass -File scripts\build.ps1 -SkipAndroid

param(
  [switch]$SkipAndroid
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

Write-Host "== 1/3  Windows release ==" -ForegroundColor Cyan
# Flutter 的 Windows 版本信息在 CMake 配置时注入；增量构建不会刷新（exe 版本会停在旧值）。
# 故先清掉 build\windows 强制重编，保证版本 / 身份正确。
Remove-Item -Recurse -Force "build\windows" -ErrorAction SilentlyContinue
flutter build windows --release

Write-Host "== 2/3  Inno Setup 安装程序 ==" -ForegroundColor Cyan

# 版本号唯一真源：pubspec.yaml 的 version
$pubspec = Get-Content "pubspec.yaml" -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\S+)') { throw "pubspec.yaml 里找不到 version" }
$full = $Matches[1]                 # 例：0.1.0+1
$ver = ($full -split '\+')[0]        # 例：0.1.0
Write-Host "  版本：$full（version $ver）"

$iscc = @(
  "C:\Program Files\Inno Setup 7\ISCC.exe",
  "C:\Program Files (x86)\Inno Setup 7\ISCC.exe",
  "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "找不到 ISCC.exe（请先装 Inno Setup）" }
& $iscc "/DMyAppVersion=$ver" "/DMyAppFullVersion=$full" "installer\JO-ENWSim.iss"

if (-not $SkipAndroid) {
  Write-Host "== 3/3  安卓分体式 release APK ==" -ForegroundColor Cyan
  flutter build apk --release --split-per-abi
  if ($LASTEXITCODE -eq 0 -and (Test-Path "build\app\outputs\flutter-apk")) {
    Copy-Item -Force "build\app\outputs\flutter-apk\*.apk" $dist
  } else {
    Write-Warning "安卓构建失败或未产出（退出码 $LASTEXITCODE），跳过拷贝。"
  }
}

Write-Host "`n== dist 产物 ==" -ForegroundColor Green
Get-ChildItem $dist | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}} | Format-Table
