; ==========================================================================
; Dispatch Orchestrator - Inno Setup Installer Script
; ==========================================================================
; Builds a professional Windows installer for the multi-machine
; Claude Dispatch Orchestrator project.
;
; Requires: Inno Setup 6+ (https://jrsoftware.org/isinfo.php)
; Build:    Run installer/build.ps1 or invoke ISCC.exe directly.
; ==========================================================================

#include "version.iss"
#define MyAppName      "Dispatch Orchestrator"
#define MyAppPublisher "Dispatch Orchestrator"
#define MyAppURL       "https://github.com/fryzhykau/dispatch-extender-agent"
#define MyAppExeName   "node.exe"

[Setup]
; Application identity
AppId={{B5E2F8A1-3D4C-4E6F-9A1B-7C8D2E3F4A5B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases

; Installation directories
DefaultDirName={autopf}\DispatchOrchestrator
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes

; Output settings
OutputDir=..\dist
OutputBaseFilename=DispatchOrchestratorSetup
SetupIconFile=assets\icon.ico

; Compression (LZMA2 ultra for smallest output)
Compression=lzma2/ultra64
SolidCompression=yes
LZMANumBlockThreads=4

; Modern wizard style
WizardStyle=modern
WizardImageFile=assets\wizard-banner.bmp
WizardSmallImageFile=assets\wizard-small.bmp

; Privileges and platform
PrivilegesRequired=admin
MinVersion=10.0
ArchitecturesInstallIn64BitMode=x64compatible

; Uninstall settings
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\installer\assets\icon.ico

; Misc
AllowNoIcons=yes
ChangesEnvironment=no

; --------------------------------------------------------------------------
; Files to install
; --------------------------------------------------------------------------
[Files]
; Core application directories
Source: "..\relay\*";         DestDir: "{app}\relay";       Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\worker\*";        DestDir: "{app}\worker";      Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\coordinator\*";   DestDir: "{app}\coordinator"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\dashboard\*";     DestDir: "{app}\dashboard";   Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\lib\*";           DestDir: "{app}\lib";         Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\install\*";       DestDir: "{app}\install";     Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\scripts\*";       DestDir: "{app}\scripts";     Flags: ignoreversion recursesubdirs createallsubdirs

; Package manifests (needed for npm install)
Source: "..\package.json";      DestDir: "{app}"; Flags: ignoreversion
Source: "..\package-lock.json"; DestDir: "{app}"; Flags: ignoreversion

; Documentation
Source: "..\CLAUDE.md";  DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md";  DestDir: "{app}"; Flags: ignoreversion

; Icon for uninstall display and shortcuts
Source: "assets\icon.ico"; DestDir: "{app}\installer\assets"; Flags: ignoreversion

; Launcher scripts (with logging)
Source: "launch-wizard.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "launch-dashboard.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion

; Images for setup wizard
Source: "..\logo\integration-diagram-simple.png"; DestDir: "{app}\installer\assets"; DestName: "integration-diagram.png"; Flags: ignoreversion

; --------------------------------------------------------------------------
; Registry entries
; --------------------------------------------------------------------------
[Registry]
; Store the install path for other tools / scripts to find
Root: HKLM; Subkey: "SOFTWARE\DispatchOrchestrator"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\DispatchOrchestrator"; ValueType: string; ValueName: "Version";     ValueData: "{#MyAppVersion}"; Flags: uninsdeletekey

; --------------------------------------------------------------------------
; Start Menu and Desktop shortcuts
; --------------------------------------------------------------------------
[Icons]
; Setup wizard
Name: "{group}\Dispatch Orchestrator Setup"; Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -File ""{app}\install\setup-wizard.ps1"""; \
  WorkingDir: "{app}"; Comment: "Run the setup wizard to configure relay or worker"

; Dashboard (opens in default browser)
Name: "{group}\Dispatch Dashboard"; Filename: "http://localhost:7070/dashboard"; \
  Comment: "Open the live monitoring dashboard in your browser"

; Start Relay
Name: "{group}\Start Relay"; Filename: "cmd.exe"; \
  Parameters: "/K node relay/server.js"; \
  WorkingDir: "{app}"; Comment: "Start the WebSocket relay server"; \
  IconFilename: "{app}\installer\assets\icon.ico"

; Desktop shortcuts (user can deselect via Tasks)
Name: "{autodesktop}\Dispatch Dashboard"; Filename: "http://localhost:7070/dashboard"; \
  Comment: "Open the Dispatch Orchestrator dashboard"; Tasks: desktopicon; \
  IconFilename: "{app}\installer\assets\icon.ico"

Name: "{autodesktop}\Start Relay"; Filename: "cmd.exe"; \
  Parameters: "/K node relay/server.js"; WorkingDir: "{app}"; \
  Comment: "Start the WebSocket relay server"; Tasks: desktopicon; \
  IconFilename: "{app}\installer\assets\icon.ico"

Name: "{autodesktop}\Dispatch Setup"; Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -File ""{app}\install\setup-wizard.ps1"""; WorkingDir: "{app}"; \
  Comment: "Run the setup wizard"; Tasks: desktopicon; \
  IconFilename: "{app}\installer\assets\icon.ico"

; --------------------------------------------------------------------------
; Optional tasks presented to the user
; --------------------------------------------------------------------------
[Tasks]
Name: "desktopicon"; Description: "Create &desktop shortcuts (Dashboard, Start Relay, Setup)"; GroupDescription: "Additional shortcuts:"
; --------------------------------------------------------------------------
; Post-install actions
; --------------------------------------------------------------------------
[Run]
; Install npm dependencies (production only)
Filename: "cmd.exe"; Parameters: "/C npm install --production"; \
  WorkingDir: "{app}"; StatusMsg: "Installing Node.js dependencies..."; \
  Flags: runhidden waituntilterminated; Check: NodeJsInstalled

; Kill any existing relay process before launching the wizard (avoids EADDRINUSE)
Filename: "cmd.exe"; \
  Parameters: "/C for /f ""tokens=5"" %a in ('netstat -ano ^| findstr :7070 ^| findstr LISTENING') do taskkill /PID %a /F >nul 2>&1"; \
  Flags: runhidden waituntilterminated

; Launch the setup wizard after installation completes
Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -File ""{app}\installer\launch-wizard.ps1"""; \
  WorkingDir: "{app}"; Description: "Launch the Setup Wizard now"; \
  Flags: postinstall skipifsilent waituntilterminated

; Start the relay and open the dashboard (single checkbox)
Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -File ""{app}\installer\launch-dashboard.ps1"""; \
  WorkingDir: "{app}"; \
  Description: "Start the Relay and open the Dashboard"; \
  Flags: nowait postinstall skipifsilent unchecked; Check: NodeJsInstalled

; --------------------------------------------------------------------------
; Uninstall actions — clean up Windows services
; --------------------------------------------------------------------------
[UninstallRun]
; Stop and remove the relay service if it exists
Filename: "cmd.exe"; Parameters: "/C sc stop DispatchRelay >nul 2>&1 & sc delete DispatchRelay >nul 2>&1"; \
  Flags: runhidden waituntilterminated
; Stop and remove the worker service if it exists
Filename: "cmd.exe"; Parameters: "/C sc stop DispatchWorker >nul 2>&1 & sc delete DispatchWorker >nul 2>&1"; \
  Flags: runhidden waituntilterminated
; Also try NSSM-based services (different naming convention)
Filename: "cmd.exe"; Parameters: "/C nssm stop DispatchRelay >nul 2>&1 & nssm remove DispatchRelay confirm >nul 2>&1"; \
  Flags: runhidden waituntilterminated
Filename: "cmd.exe"; Parameters: "/C nssm stop DispatchWorker >nul 2>&1 & nssm remove DispatchWorker confirm >nul 2>&1"; \
  Flags: runhidden waituntilterminated

; --------------------------------------------------------------------------
; Directories to clean up on uninstall
; --------------------------------------------------------------------------
[UninstallDelete]
Type: filesandordirs; Name: "{app}\node_modules"
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\certs"

; --------------------------------------------------------------------------
; Pascal Script — custom logic
; --------------------------------------------------------------------------
[Code]

// Check if Node.js is available on the system PATH
function NodeJsInstalled: Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec('cmd.exe', '/C node --version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
            and (ResultCode = 0);
end;

// Retrieve the installed Node.js version string (e.g. "v20.11.0")
function GetNodeVersion: String;
var
  TmpFile: String;
  Lines: TArrayOfString;
  ResultCode: Integer;
begin
  Result := '(unknown)';
  TmpFile := ExpandConstant('{tmp}\nodeversion.txt');
  if Exec('cmd.exe', '/C node --version > "' + TmpFile + '" 2>&1', '',
           SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if LoadStringsFromFile(TmpFile, Lines) and (GetArrayLength(Lines) > 0) then
      Result := Trim(Lines[0]);
    DeleteFile(TmpFile);
  end;
end;

// Check if NSSM is available on PATH
function NssmInstalled: Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec('cmd.exe', '/C nssm version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
            and (ResultCode = 0);
end;

// Extract the major version number from a Node version string like "v20.11.0"
function GetNodeMajorVersion(const Ver: String): Integer;
var
  S: String;
  DotPos: Integer;
begin
  Result := 0;
  S := Ver;
  // Strip leading 'v'
  if (Length(S) > 0) and ((S[1] = 'v') or (S[1] = 'V')) then
    S := Copy(S, 2, Length(S) - 1);
  DotPos := Pos('.', S);
  if DotPos > 0 then
    S := Copy(S, 1, DotPos - 1);
  Result := StrToIntDef(S, 0);
end;

var
  PrereqPage: TWizardPage;
  PrereqMemo: TNewMemo;

// Create a custom wizard page that shows prerequisite status
procedure CreatePrereqPage;
begin
  PrereqPage := CreateCustomPage(wpSelectDir,
    'Prerequisites Check',
    'Verifying that required software is available on this system.');

  PrereqMemo := TNewMemo.Create(PrereqPage);
  PrereqMemo.Parent := PrereqPage.Surface;
  PrereqMemo.Left := 0;
  PrereqMemo.Top := 0;
  PrereqMemo.Width := PrereqPage.SurfaceWidth;
  PrereqMemo.Height := PrereqPage.SurfaceHeight;
  PrereqMemo.ReadOnly := True;
  PrereqMemo.ScrollBars := ssVertical;
  PrereqMemo.Font.Name := 'Consolas';
  PrereqMemo.Font.Size := 10;
  PrereqMemo.WordWrap := True;
end;

// Populate the prerequisites page with current status
procedure UpdatePrereqPage;
var
  NodeVer: String;
  NodeMajor: Integer;
  Info: String;
begin
  Info := '';

  // --- Node.js ---
  if NodeJsInstalled then
  begin
    NodeVer := GetNodeVersion;
    NodeMajor := GetNodeMajorVersion(NodeVer);
    Info := Info + '[OK]  Node.js is installed: ' + NodeVer + #13#10;
    if NodeMajor < 18 then
      Info := Info + '[!!]  WARNING: Node.js 18+ is required. You have version '
              + IntToStr(NodeMajor) + '.x' + #13#10
              + '      Please upgrade Node.js before continuing.' + #13#10;
  end
  else
  begin
    Info := Info + '[!!]  Node.js is NOT installed.' + #13#10;
    Info := Info + '      Node.js 18+ is required for Dispatch Orchestrator.' + #13#10;
    Info := Info + '      Download from: https://nodejs.org/' + #13#10;
  end;

  Info := Info + #13#10;

  // --- NSSM ---
  if NssmInstalled then
    Info := Info + '[OK]  NSSM is installed (Windows service helper).' + #13#10
  else
  begin
    Info := Info + '[--]  NSSM is not installed (optional).' + #13#10;
    Info := Info + '      NSSM is needed only if you want to run relay/worker' + #13#10;
    Info := Info + '      as Windows services. Download: https://nssm.cc/' + #13#10;
  end;

  Info := Info + #13#10;
  Info := Info + '---------------------------------------------' + #13#10;
  Info := Info + 'You may continue the installation even if Node.js is missing,' + #13#10;
  Info := Info + 'but you will need to install it before running the application.' + #13#10;

  PrereqMemo.Text := Info;
end;

// Called when the wizard initialises — create our custom pages
procedure InitializeWizard;
begin
  CreatePrereqPage;
end;

// Called when the active wizard page changes
procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = PrereqPage.ID then
    UpdatePrereqPage;
end;

// Called at each major installation step
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    // If Node.js is missing, warn the user and offer to open download page
    if not NodeJsInstalled then
    begin
      if MsgBox('Node.js was not found on this system.' + #13#10 + #13#10 +
                'Dispatch Orchestrator requires Node.js 18 or newer.' + #13#10 +
                'Would you like to open the Node.js download page now?',
                mbConfirmation, MB_YESNO) = IDYES then
      begin
        ShellExec('open', 'https://nodejs.org/en/download/', '', '', SW_SHOWNORMAL, ewNoWait, ResultCode);
      end;
    end;
  end;
end;

// Confirm uninstall — remind user about services
function InitializeUninstall: Boolean;
begin
  Result := MsgBox('This will uninstall {#MyAppName} and remove any associated Windows services.' + #13#10 + #13#10 +
                   'Continue?', mbConfirmation, MB_YESNO) = IDYES;
end;
