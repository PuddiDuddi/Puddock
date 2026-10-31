; Puddock installer (Inno Setup 6) - per-user, no administrator rights.
; Built by build\build.ps1:  ISCC /DAppVersion=X.Y.Z /DDistDir=<repo>\dist /O<repo>\dist installer\puddock.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef DistDir
  #define DistDir "..\dist"
#endif

#define AppName "Puddock"
#define AppExe  "puddock.exe"

[Setup]
; Never change AppId: it identifies the installation for upgrades / uninstall.
AppId={{A205EC21-423E-4B91-B172-7AD03673B7CF}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Puddock contributors
AppPublisherURL=https://github.com/puddiduddi/Puddock
AppSupportURL=https://github.com/puddiduddi/Puddock/issues
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputBaseFilename={#AppName}-Setup-{#AppVersion}
SetupIconFile=..\app\assets\puddock.ico
UninstallDisplayIcon={app}\{#AppExe}
LicenseFile=..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
; Code signing: build.ps1 -SignScript <script> passes /DSignInstaller=1 and a sign tool named
; "puddock" (/Spuddock=...), so setup.exe and the uninstaller are signed by the same script that
; signed puddock.exe before it was packed.
#ifdef SignInstaller
SignTool=puddock
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#DistDir}\{#AppExe}";   DestDir: "{app}"; Flags: ignoreversion
Source: "{#DistDir}\extension\*"; DestDir: "{app}\extension"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\LICENSE";              DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md";            DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{userprograms}\{#AppName} Setup"; Filename: "{app}\{#AppExe}"; Parameters: "--setup"

[Run]
; Register the native messaging host (browser <-> app) for all supported browsers, per user.
Filename: "{app}\{#AppExe}"; Parameters: "--install"; Flags: runhidden waituntilterminated; StatusMsg: "Connecting browsers..."
Filename: "{app}\{#AppExe}"; Parameters: "--setup"; Description: "Open Puddock setup (streamlink, mpv, browser extension)"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{app}\{#AppExe}"; Parameters: "--uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "PuddockUnregister"
