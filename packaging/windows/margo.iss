; Compile with scripts/build-windows-installer.ps1 after building the Windows client.
#define ReleaseDir "..\..\apps\margo_flutter\build\windows\x64\runner\Release"
#define AppExe SourcePath + ReleaseDir + "\margo.exe"
#define BuildVersion GetFileVersionString(AppExe)
#define BuildSeparator Pos("+", BuildVersion)
#define AppVersion BuildSeparator ? Copy(BuildVersion, 1, BuildSeparator - 1) : BuildVersion

[Setup]
#ifdef ProductionSigning
SignTool=margo
SignedUninstaller=yes
#endif
AppId={{57EF15D1-5612-49DB-A93C-2CA03D5024E3}
AppName=MARGO
AppVersion={#AppVersion}
VersionInfoVersion={#GetVersionNumbersString(AppExe)}
DefaultDirName={localappdata}\Programs\MARGO
DefaultGroupName=MARGO
PrivilegesRequired=lowest
OutputDir=..\..\dist
OutputBaseFilename=MARGO-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\..\apps\margo_flutter\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\margo.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Excludes: "START-HERE.txt,msvcp140.dll,vcruntime140.dll,vcruntime140_1.dll"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#CRuntimeDir}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CRuntimeDir}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CRuntimeDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\MARGO"; Filename: "{app}\margo.exe"; WorkingDir: "{app}"; AppUserModelID: "dev.thoth.app"
Name: "{userdesktop}\MARGO"; Filename: "{app}\margo.exe"; WorkingDir: "{app}"; Tasks: desktopicon; AppUserModelID: "dev.thoth.app"

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Run]
Filename: "{app}\margo.exe"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,MARGO}"; Flags: nowait postinstall skipifsilent
