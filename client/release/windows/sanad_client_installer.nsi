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
!ifndef APP_DISPLAY_NAME
  !define APP_DISPLAY_NAME "Sanad"
!endif
!ifndef APP_REGISTRY_KEY
  !define APP_REGISTRY_KEY "Software\Sanad"
!endif
!ifndef APP_UNINSTALL_REGISTRY_KEY
  !define APP_UNINSTALL_REGISTRY_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Sanad"
!endif

Name "${APP_DISPLAY_NAME}"
OutFile "${OUTPUT_FILE}"
!ifdef GATE_E_INSTALL_DIR
  InstallDir "${GATE_E_INSTALL_DIR}"
!else
  InstallDir "$PROGRAMFILES64\Sanad"
!endif
InstallDirRegKey HKCU "${APP_REGISTRY_KEY}" "Install_Dir"

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
  InitPluginsDir

  ; Extract and validate a complete payload before touching the installed
  ; executable. The staging directory lives under $INSTDIR so the replacement
  ; helper can use same-volume moves instead of partial in-place writes.
  RMDir /r "$INSTDIR\.sanad-install-staging"
  IfFileExists "$INSTDIR\.sanad-install-staging" 0 staging_ready
    DetailPrint "A previous Sanad Client staging directory could not be removed."
    Abort
  staging_ready:
  ClearErrors
  SetOutPath "$INSTDIR\.sanad-install-staging"
  File "..\..\build\windows\x64\runner\Release\sanad-client.exe"
  File "..\..\build\windows\x64\runner\Release\*.dll"
  SetOutPath "$INSTDIR\.sanad-install-staging\data"
  File /r "..\..\build\windows\x64\runner\Release\data\*"
  ${If} ${Errors}
    RMDir /r "$INSTDIR\.sanad-install-staging"
    DetailPrint "The Sanad Client payload could not be staged completely."
    Abort
  ${EndIf}

  ; WinSparkle launches the installer before requesting graceful shutdown.
  ; New clients flush and exit through before-quit-for-update. The helper waits
  ; for that handoff and only force-stops the exact installed path as a bounded
  ; compatibility fallback for clients released before the listener existed.
  SetOutPath "$PLUGINSDIR"
  File /oname=stop_installed_client.ps1 "stop_installed_client.ps1"
  File /oname=install_staged_client.ps1 "install_staged_client.ps1"
  nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\stop_installed_client.ps1" -TargetPath "$INSTDIR\sanad-client.exe"'
  Pop $0
  Pop $1
  ${If} $0 != 0
    RMDir /r "$INSTDIR\.sanad-install-staging"
    DetailPrint "The installed Sanad Client did not close safely: $1"
    Abort
  ${EndIf}

  ; Swap the staged executable, DLLs, and data into place using same-volume
  ; moves. The helper verifies hashes and restores the previous payload if any
  ; replacement step fails.
  nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\install_staged_client.ps1" -TargetDirectory "$INSTDIR" -StagedDirectory "$INSTDIR\.sanad-install-staging"'
  Pop $0
  Pop $1
  ${If} $0 != 0
    DetailPrint "The Sanad Client payload could not be replaced safely: $1"
    Abort
  ${EndIf}

  ; Install Visual C++ Redistributable
  SetOutPath "$TEMP"
  File "..\..\build\windows\x64\runner\Release\vc_redist.x64.exe"
  DetailPrint "Installing Microsoft Visual C++ Redistributable..."
  ExecWait '"$TEMP\vc_redist.x64.exe" /install /quiet /norestart'
  Delete "$TEMP\vc_redist.x64.exe"
  SetOutPath "$INSTDIR"
  
  !ifndef GATE_E_NO_SHORTCUTS
    ; Create start menu and desktop shortcuts for production packages.
    SetOutPath "$INSTDIR"
    CreateDirectory "$SMPROGRAMS\Sanad"
    CreateShortcut "$SMPROGRAMS\Sanad\Sanad.lnk" "$INSTDIR\sanad-client.exe"
    CreateShortcut "$SMPROGRAMS\Sanad\Uninstall.lnk" "$INSTDIR\uninstall.exe"
    CreateShortcut "$DESKTOP\Sanad.lnk" "$INSTDIR\sanad-client.exe"
  !endif

  ; Create uninstaller
  WriteUninstaller "$INSTDIR\uninstall.exe"
  
  ; Store installation folder and Windows Installed Apps metadata.
  WriteRegStr HKCU "${APP_REGISTRY_KEY}" "Install_Dir" "$INSTDIR"
  WriteRegStr HKCU "${APP_UNINSTALL_REGISTRY_KEY}" "DisplayName" "${APP_DISPLAY_NAME}"
  WriteRegStr HKCU "${APP_UNINSTALL_REGISTRY_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${APP_UNINSTALL_REGISTRY_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${APP_UNINSTALL_REGISTRY_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "${APP_UNINSTALL_REGISTRY_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${APP_UNINSTALL_REGISTRY_KEY}" "NoRepair" 1
SectionEnd

; Uninstaller section
Section "Uninstall"
  SetShellVarContext current
  !ifndef GATE_E_NO_SHORTCUTS
    ; Remove production shortcuts.
    RMDir /r "$SMPROGRAMS\Sanad"
    Delete "$DESKTOP\Sanad.lnk"
  !endif
  
  ; Remove application files
  RMDir /r "$INSTDIR"
  
  ; Remove registry entries
  DeleteRegKey HKCU "${APP_REGISTRY_KEY}"
  DeleteRegKey HKCU "${APP_UNINSTALL_REGISTRY_KEY}"
SectionEnd

; Function to ensure admin rights
Function .onInit
  ${If} ${RunningX64}
    SetRegView 64
  ${EndIf}
FunctionEnd
