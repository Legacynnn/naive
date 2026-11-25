; Naive for Windows — per-user installer (Inno Setup 6).
;
; Built by scripts/package-windows.ps1, which passes the version, the package
; architecture, and the staged portable directory:
;   ISCC.exe /DAppVersion=0.2.97 /DArch=x86_64 /DPackageDir=<stage> /DOutputDir=<out> naive.iss
;
; Installs into %LOCALAPPDATA%\Programs\Naive without elevation, like VS
; Code's user setup: the directory stays writable by its user, so the in-app
; updater (crates/update/src/windows.rs) can replace naive.exe in place. The
; staged directory already carries naive-update.json, which marks the install
; as update-managed. Re-running a newer installer upgrades in place; user data
; lives in %LOCALAPPDATA%\Naive and is never touched here.

#ifndef AppVersion
  #error AppVersion must be defined (/DAppVersion=x.y.z)
#endif
#ifndef Arch
  #error Arch must be defined (/DArch=x86_64 or /DArch=aarch64)
#endif
#ifndef PackageDir
  #error PackageDir must be defined (/DPackageDir=<staged package directory>)
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
; The zgx app (scripts/package-windows.ps1 -ZgxVersion, /DZgx=1) brings its
; version's folder, beta\<version>, stable or beta. The file version must be
; numeric; a beta's AppVersion (x.y.z-beta.n) isn't.
#ifndef FileVersion
  #define FileVersion AppVersion
#endif

#if Arch == "aarch64"
  #define ArchAllowed "arm64"
#else
  #define ArchAllowed "x64compatible"
#endif

[Setup]
; Never change AppId: it identifies the installation across upgrades, and
; crates/update/src/windows.rs refreshes DisplayVersion under this key after
; in-app updates.
AppId={{AD5DEC34-E254-467B-8F24-8127EBAF4DA6}
AppName=Naive
AppVersion={#AppVersion}
AppVerName=Naive {#AppVersion}
AppPublisher=Naive
AppPublisherURL=https://naive.sh
AppSupportURL=https://github.com/zeronsh/zeron/issues
AppUpdatesURL=https://github.com/zeronsh/zeron/releases
VersionInfoVersion={#FileVersion}
PrivilegesRequired=lowest
DefaultDirName={autopf}\Naive
DisableProgramGroupPage=yes
DisableDirPage=auto
DisableReadyPage=yes
ArchitecturesAllowed={#ArchAllowed}
ArchitecturesInstallIn64BitMode={#ArchAllowed}
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=naive-{#AppVersion}-windows-{#Arch}-setup
SetupIconFile=naive.ico
UninstallDisplayIcon={app}\naive.exe
UninstallDisplayName=Naive
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; A running Naive is closed through the Restart Manager before its files are
; replaced; the updated app starts again from the finish page.
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PackageDir}\naive.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\naive-update.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs createallsubdirs
#ifdef Zgx
; The zgx app's scripts, plugins and engine, by version.
Source: "{#PackageDir}\beta\*"; DestDir: "{app}\beta"; Flags: ignoreversion recursesubdirs createallsubdirs
#endif

[Icons]
Name: "{autoprograms}\Naive"; Filename: "{app}\naive.exe"
Name: "{autodesktop}\Naive"; Filename: "{app}\naive.exe"; Tasks: desktopicon

[Registry]
; naive:// conversation links — the scheme macOS registers in Info.plist and
; Linux in naive.desktop.
Root: HKCU; Subkey: "Software\Classes\naive"; ValueType: string; ValueName: ""; ValueData: "URL:Naive"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\naive"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\naive\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\naive.exe"",0"
Root: HKCU; Subkey: "Software\Classes\naive\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\naive.exe"" ""%1"""

[Run]
Filename: "{app}\naive.exe"; Description: "{cm:LaunchProgram,Naive}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Leftovers of in-app updates (crates/update/src/windows.rs).
Type: files; Name: "{app}\naive.exe.old"
Type: files; Name: "{app}\.naive-update-incoming.exe"
Type: filesandordirs; Name: "{app}\.naive-update-*"
Type: files; Name: "{app}\.naive-completing.lock"
Type: files; Name: "{app}\naive-version"
; The zgx app's folder, whichever versions an update brought.
Type: filesandordirs; Name: "{app}\beta"
