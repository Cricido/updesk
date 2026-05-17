#define MyAppName "UptimeDesk"
#define MyAppVersion "1.0.2"
#define MyAppPublisher "MED srl"
#define MyAppURL "https://www.uptimeservice.it/"
#define MyAppExeName "uptimedesk.exe"
#define MySourceDir "flutter\build\windows\x64\runner\Release"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename=UptimeDesk-Assistenza-Setup
SetupIconFile=flutter\windows\runner\resources\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[Tasks]
Name: "desktopicon"; Description: "Crea un'icona sul &desktop"; GroupDescription: "Icone aggiuntive:"

[Files]
Source: "{#MySourceDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MySourceDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "target\release\updesk_updater.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MySourceDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName} Assistenza"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--portable-service"; Comment: "Avvia UptimeDesk in modalità assistenza remota"
Name: "{group}\Disinstalla {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#MyAppName} Assistenza"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--portable-service"; Comment: "Avvia UptimeDesk in modalità assistenza remota"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Parameters: "--portable-service"; Description: "Avvia {#MyAppName} Assistenza"; Flags: nowait postinstall skipifsilent
