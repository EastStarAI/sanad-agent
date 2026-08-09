; Installer for Sanad
; Built with NSIS

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

; General
!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif
!ifndef OUTPUT_FILE
  !define OUTPUT_FILE "..\..\build\sanad-client-setup.exe"
!endif

Name "Sanad"
OutFile "${OUTPUT_FILE}"
!ifdef GATE_E_INSTALL_DIR
  InstallDir "${GATE_E_INSTALL_DIR}"
!else
  InstallDir "$PROGRAMFILES64\Sanad"
!endif
InstallDirRegKey HKCU "Software\Sanad" "Install_Dir"

!ifdef GATE_E_USER_INSTALL
  RequestExecutionLevel user
!else
  RequestExecutionLevel admin
!endif

; MUI Settings
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "Arabic"

; Installer sections
Section "Install"
  SetShellVarContext current
  SetOutPath "$INSTDIR"

  ; WinSparkle launches the installer before requesting graceful shutdown.
  ; New clients flush and exit through before-quit-for-update. The helper waits
  ; for that handoff and only force-stops the exact installed path as a bounded
  ; compatibility fallback for clients released before the listener existed.
  InitPluginsDir
  File /oname=$PLUGINSDIR\stop_installed_client.ps1 "stop_installed_client.ps1"
  nsExec::ExecToStack 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\stop_installed_client.ps1" -TargetPath "$INSTDIR\sanad-client.exe"'
  Pop $0
  Pop $1
  ${If} $0 != 0
    DetailPrint "The installed Sanad Client did not close safely: $1"
    Abort
  ${EndIf}

  ; Remove the previous application payload so upgrades cannot retain stale
  ; DLLs or data.
  Delete "$INSTDIR\sanad-client.exe"
  Delete "$INSTDIR\*.dll"
  RMDir /r "$INSTDIR\data"
  
  ; Copy main executable
  ClearErrors
  File "..\..\build\windows\x64\runner\Release\sanad-client.exe"
  IfFileExists "$INSTDIR\sanad-client.exe" +3 0
    DetailPrint "The Sanad Client executable could not be installed."
    Abort
  
  ; Copy DLL files
  File "..\..\build\windows\x64\runner\Release\*.dll"
  
  ; Copy data folder
  SetOutPath "$INSTDIR\data"
  File /r "..\..\build\windows\x64\runner\Release\data\*"
  
  ; Install Visual C++ Redistributable
  SetOutPath "$TEMP"
  File "..\..\build\windows\x64\runner\Release\vc_redist.x64.exe"
  DetailPrint "Installing Microsoft Visual C++ Redistributable..."
  ExecWait '"$TEMP\vc_redist.x64.exe" /install /quiet /norestart'
  Delete "$TEMP\vc_redist.x64.exe"
  SetOutPath "$INSTDIR"
  
  ; Create start menu shortcuts
  SetOutPath "$INSTDIR"
  CreateDirectory "$SMPROGRAMS\Sanad"
  CreateShortcut "$SMPROGRAMS\Sanad\Sanad.lnk" "$INSTDIR\sanad-client.exe"
  CreateShortcut "$SMPROGRAMS\Sanad\Uninstall.lnk" "$INSTDIR\uninstall.exe"
  
  ; Create desktop shortcut
  CreateShortcut "$DESKTOP\Sanad.lnk" "$INSTDIR\sanad-client.exe"
  
  ; Create uninstaller
  WriteUninstaller "$INSTDIR\uninstall.exe"
  
  ; Store installation folder and Windows Installed Apps metadata.
  WriteRegStr HKCU "Software\Sanad" "Install_Dir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Sanad" "DisplayName" "Sanad"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Sanad" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Sanad" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Sanad" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Sanad" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Sanad" "NoRepair" 1
SectionEnd

; Uninstaller section
Section "Uninstall"
  SetShellVarContext current
  ; Remove shortcuts
  RMDir /r "$SMPROGRAMS\Sanad"
  Delete "$DESKTOP\Sanad.lnk"
  
  ; Remove application files
  RMDir /r "$INSTDIR"
  
  ; Remove registry entries
  DeleteRegKey HKCU "Software\Sanad"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Sanad"
SectionEnd

; Function to ensure admin rights
Function .onInit
  ${If} ${RunningX64}
    SetRegView 64
  ${EndIf}
FunctionEnd
