; DriveWise Setup Script (NSIS)
; Author: Aadesh Gulumbe (github.com/aadesh0706)
;
; Per-user installer (no admin rights needed to install). DriveWise itself
; requests elevation at runtime when it actually needs deep filesystem
; access for scanning.

!include "MUI2.nsh"

; ---------------------------------------------------------------------------
; General
; ---------------------------------------------------------------------------
Name "DriveWise"
OutFile "DriveWise-Setup-1.0.0.exe"
InstallDir "$LOCALAPPDATA\Programs\DriveWise"
InstallDirRegKey HKCU "Software\DriveWise" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define PRODUCT_NAME "DriveWise"
!define PRODUCT_VERSION "1.0.0"
!define PRODUCT_PUBLISHER "Aadesh Gulumbe"
!define PRODUCT_WEBSITE "https://github.com/aadesh0706/DriveWise"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\DriveWise"

VIProductVersion "1.0.0.0"
VIAddVersionKey "ProductName" "${PRODUCT_NAME}"
VIAddVersionKey "ProductVersion" "${PRODUCT_VERSION}"
VIAddVersionKey "CompanyName" "${PRODUCT_PUBLISHER}"
VIAddVersionKey "LegalCopyright" "(c) 2026 ${PRODUCT_PUBLISHER}"
VIAddVersionKey "FileDescription" "${PRODUCT_NAME} Setup"
VIAddVersionKey "FileVersion" "${PRODUCT_VERSION}"

!define MUI_ICON "icon.ico"
!define MUI_UNICON "icon.ico"
!define MUI_ABORTWARNING

; ---------------------------------------------------------------------------
; Pages
; ---------------------------------------------------------------------------
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_RUN "$INSTDIR\Start-DriveWise.bat"
!define MUI_FINISHPAGE_RUN_TEXT "Launch DriveWise now"
!define MUI_FINISHPAGE_LINK "Visit the DriveWise GitHub page"
!define MUI_FINISHPAGE_LINK_LOCATION "${PRODUCT_WEBSITE}"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ---------------------------------------------------------------------------
; Install
; ---------------------------------------------------------------------------
Section "DriveWise" SEC01
    SetOutPath "$INSTDIR"
    File "..\src\DriveWise.ps1"
    File "..\src\Start-DriveWise.bat"
    File "icon.ico"
    File "..\LICENSE"
    File "..\README.md"

    WriteRegStr HKCU "Software\DriveWise" "InstallDir" "$INSTDIR"
    WriteRegStr HKCU "Software\DriveWise" "Version" "${PRODUCT_VERSION}"

    CreateDirectory "$SMPROGRAMS\DriveWise"
    CreateShortcut "$SMPROGRAMS\DriveWise\DriveWise.lnk" "$INSTDIR\Start-DriveWise.bat" "" "$INSTDIR\icon.ico"
    CreateShortcut "$SMPROGRAMS\DriveWise\Uninstall DriveWise.lnk" "$INSTDIR\Uninstall.exe"
    CreateShortcut "$DESKTOP\DriveWise.lnk" "$INSTDIR\Start-DriveWise.bat" "" "$INSTDIR\icon.ico"

    WriteUninstaller "$INSTDIR\Uninstall.exe"

    WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "DriveWise"
    WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${PRODUCT_VERSION}"
    WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
    WriteRegStr HKCU "${UNINST_KEY}" "URLInfoAbout" "${PRODUCT_WEBSITE}"
    WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\icon.ico"
    WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" "$INSTDIR\Uninstall.exe"
    WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
    WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
SectionEnd

; ---------------------------------------------------------------------------
; Uninstall
; ---------------------------------------------------------------------------
Section "Uninstall"
    Delete "$INSTDIR\DriveWise.ps1"
    Delete "$INSTDIR\Start-DriveWise.bat"
    Delete "$INSTDIR\icon.ico"
    Delete "$INSTDIR\LICENSE"
    Delete "$INSTDIR\README.md"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir "$INSTDIR"

    Delete "$SMPROGRAMS\DriveWise\DriveWise.lnk"
    Delete "$SMPROGRAMS\DriveWise\Uninstall DriveWise.lnk"
    RMDir "$SMPROGRAMS\DriveWise"
    Delete "$DESKTOP\DriveWise.lnk"

    DeleteRegKey HKCU "${UNINST_KEY}"
    DeleteRegKey HKCU "Software\DriveWise"
SectionEnd
