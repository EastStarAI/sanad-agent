[Setup]
AppName=Sanad
AppVersion=1.0.6
AppPublisher=EastStar AI
AppPublisherURL=https://eaststarai.com
AppSupportURL=https://eaststarai.com/support
AppUpdatesURL=https://updates.sanad.eaststarai.com
DefaultDirName={pf}\Sanad
DefaultGroupName=Sanad
OutputBaseFilename=sanad-client-setup
OutputDir=.\installer\output
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\sanad-client.exe
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ar"; MessagesFile: "compiler:Arabic.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall ignoreversion
Source: "..\build\windows\x64\runner\Release\sanad-client.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\window_manager_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\screen_capturer_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\screen_retriever_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\url_launcher_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\connectivity_plus_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\bixat_key_mouse.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Sanad"; Filename: "{app}\sanad-client.exe"
Name: "{group}\Uninstall Sanad"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Sanad"; Filename: "{app}\sanad-client.exe"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing Microsoft Visual C++ Redistributable..."; Flags: waituntilterminated skipifdoesntexist
Filename: "{app}\sanad-client.exe"; Description: "{cm:LaunchProgram,Sanad}"; Flags: nowait postinstall skipifsilent
