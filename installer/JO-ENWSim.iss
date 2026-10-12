; JO-ENWSim Windows 安装程序（Inno Setup）
; 编译前先跑：flutter build windows --release

#define MyAppName "JO-ENWSim"
#define MyAppPublisher "JO-Beacon"
#define MyAppExeName "joenws.exe"

; 版本号由 build.ps1 从 pubspec.yaml 传入（ISCC /DMyAppVersion=... /DMyAppFullVersion=...）；
; 直接手编译本文件时，用下面兜底默认值。
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef MyAppFullVersion
  #define MyAppFullVersion MyAppVersion
#endif

[Setup]
AppId={{08DEA881-6B28-4BF3-905D-2BEE6B67B82F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\JO-ENWSim
DefaultGroupName={#MyAppName}
UsePreviousAppDir=no
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=..\windows\runner\resources\app_icon.ico
OutputDir=..\dist
OutputBaseFilename=JO-ENWSim-Setup-{#MyAppFullVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
Name: "startmenu"; Description: "创建开始菜单项"; GroupDescription: "快捷方式："
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: unchecked

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: startmenu
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent
