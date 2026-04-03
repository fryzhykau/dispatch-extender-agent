; ==========================================================================
; Dispatch Agent - Inno Setup Installer Script
; ==========================================================================
; Builds a lightweight Windows installer for the worker agent only.
; This is distributed to remote machines that only need the agent component.
;
; Requires: Inno Setup 6+ (https://jrsoftware.org/isinfo.php)
; Build:    Run installer/build.ps1 -Target agent
; ==========================================================================

#include "version.iss"
#define MyAppName      "Dispatch Agent"
#define MyAppPublisher "Dispatch Orchestrator"
#define MyAppURL       "https://github.com/fryzhykau/dispatch-extender-agent"
#define MyAppExeName   "node.exe"

[Setup]
; Application identity (different GUID from the full orchestrator)
AppId={{A3D1E7B2-5F6C-4A8E-B9C0-1D2E3F4A5B6C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases

; Installation directories
DefaultDirName={autopf}\DispatchAgent
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes

; Output settings
OutputDir=..\dist
OutputBaseFilename=DispatchAgentSetup
SetupIconFile=assets\agent-icon.ico

; Compression (LZMA2 ultra for smallest output)
Compression=lzma2/ultra64
SolidCompression=yes
LZMANumBlockThreads=4

; Modern wizard style
WizardStyle=modern
WizardImageFile=assets\agent-wizard-banner.bmp
WizardSmallImageFile=assets\agent-wizard-small.bmp

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
; Files to install (agent-only — lightweight)
; --------------------------------------------------------------------------
[Files]
; Worker agent
Source: "..\worker\agent-relay.js";      DestDir: "{app}\worker";    Flags: ignoreversion
Source: "..\worker\discovery.js";        DestDir: "{app}\worker";    Flags: ignoreversion
Source: "..\worker\worker-config.json";  DestDir: "{app}\worker";    Flags: ignoreversion onlyifdoesntexist

; Shared library
Source: "..\lib\keep-awake.js";          DestDir: "{app}\lib";       Flags: ignoreversion

; Install / setup scripts
Source: "..\install\install-worker.ps1"; DestDir: "{app}\install";   Flags: ignoreversion
Source: "..\install\generate-certs.ps1"; DestDir: "{app}\install";   Flags: ignoreversion

; Agent setup wizard
Source: "agent-setup-wizard.ps1";        DestDir: "{app}\installer"; Flags: ignoreversion
Source: "launch-agent-wizard.ps1";       DestDir: "{app}\installer"; Flags: ignoreversion

; Minimal package.json for npm install (only ws dependency)
Source: "agent-package.json";            DestDir: "{app}"; DestName: "package.json"; Flags: ignoreversion

; Icon for uninstall display and shortcuts
Source: "assets\agent-icon.ico";         DestDir: "{app}\installer\assets"; DestName: "icon.ico"; Flags: ignoreversion

; Diagram for agent setup wizard welcome page
Source: "..\logo\agent-diagram-simple.png"; DestDir: "{app}\installer\assets"; DestName: "agent-diagram.png"; Flags: ignoreversion

; --------------------------------------------------------------------------
; Registry entries
; --------------------------------------------------------------------------
[Registry]
Root: HKLM; Subkey: "SOFTWARE\DispatchAgent"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\DispatchAgent"; ValueType: string; ValueName: "Version";     ValueData: "{#MyAppVersion}"; Flags: uninsdeletekey

; --------------------------------------------------------------------------
; Start Menu shortcuts
; --------------------------------------------------------------------------
[Icons]
; Agent Setup Wizard
Name: "{group}\Agent Setup"; Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -File ""{app}\installer\agent-setup-wizard.ps1"""; \
  WorkingDir: "{app}"; Comment: "Run the agent setup wizard to configure this worker"

; Start Agent (console)
Name: "{group}\Start Agent"; Filename: "cmd.exe"; \
  Parameters: "/K node worker/agent-relay.js"; \
  WorkingDir: "{app}"; Comment: "Start the worker agent connected to the coordinator"; \
  IconFilename: "{app}\installer\assets\icon.ico"

; Stop Agent
Name: "{group}\Stop Agent"; Filename: "cmd.exe"; \
  Parameters: "/C echo Stopping Dispatch Agent... & taskkill /F /FI ""WINDOWTITLE eq worker/agent-relay.js*"" >nul 2>&1 & sc stop DispatchWorker >nul 2>&1 & nssm stop DispatchWorker >nul 2>&1 & echo Done. & pause"; \
  WorkingDir: "{app}"; Comment: "Stop the running worker agent or service"; \
  IconFilename: "{app}\installer\assets\icon.ico"

; Desktop shortcuts (user can deselect via Tasks)
Name: "{autodesktop}\Start Agent"; Filename: "cmd.exe"; \
  Parameters: "/K node worker/agent-relay.js"; WorkingDir: "{app}"; \
  Comment: "Start the worker agent"; Tasks: desktopicon; \
  IconFilename: "{app}\installer\assets\icon.ico"

Name: "{autodesktop}\Agent Setup"; Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -File ""{app}\installer\agent-setup-wizard.ps1"""; WorkingDir: "{app}"; \
  Comment: "Run the agent setup wizard"; Tasks: desktopicon; \
  IconFilename: "{app}\installer\assets\icon.ico"

; --------------------------------------------------------------------------
; Optional tasks presented to the user
; --------------------------------------------------------------------------
[Tasks]
Name: "desktopicon"; Description: "Create &desktop shortcuts (Start Agent, Agent Setup)"; GroupDescription: "Additional shortcuts:"
; --------------------------------------------------------------------------
; Post-install actions
; --------------------------------------------------------------------------
[Run]
; Install npm dependencies (production only)
Filename: "cmd.exe"; Parameters: "/C npm install --production"; \
  WorkingDir: "{app}"; StatusMsg: "Installing Node.js dependencies..."; \
  Flags: runhidden waituntilterminated; Check: NodeJsInstalled

; Launch the agent setup wizard after installation completes
Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -File ""{app}\installer\launch-agent-wizard.ps1"""; \
  WorkingDir: "{app}"; Description: "Launch the Agent Setup Wizard now"; \
  Flags: postinstall skipifsilent waituntilterminated

; --------------------------------------------------------------------------
; Uninstall actions — clean up Windows services
; --------------------------------------------------------------------------
[UninstallRun]
; Stop and remove the worker service (sc-based)
Filename: "cmd.exe"; Parameters: "/C sc stop DispatchWorker >nul 2>&1 & sc delete DispatchWorker >nul 2>&1"; \
  Flags: runhidden waituntilterminated
; Stop and remove the worker service (NSSM-based)
Filename: "cmd.exe"; Parameters: "/C nssm stop DispatchWorker >nul 2>&1 & nssm remove DispatchWorker confirm >nul 2>&1"; \
  Flags: runhidden waituntilterminated

; --------------------------------------------------------------------------
; Directories to clean up on uninstall
; --------------------------------------------------------------------------
[UninstallDelete]
Type: filesandordirs; Name: "{app}\node_modules"
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

// Check if Claude Code CLI is available on PATH
function ClaudeCliInstalled: Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec('cmd.exe', '/C claude --version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
            and (ResultCode = 0);
end;

// Retrieve the installed Claude CLI version string
function GetClaudeVersion: String;
var
  TmpFile: String;
  Lines: TArrayOfString;
  ResultCode: Integer;
begin
  Result := '(not found)';
  TmpFile := ExpandConstant('{tmp}\claudeversion.txt');
  if Exec('cmd.exe', '/C claude --version > "' + TmpFile + '" 2>&1', '',
           SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if LoadStringsFromFile(TmpFile, Lines) and (GetArrayLength(Lines) > 0) then
      Result := Trim(Lines[0]);
    DeleteFile(TmpFile);
  end;
end;

// Extract the major version number from a Node version string like "v20.11.0"
function GetNodeMajorVersion(const Ver: String): Integer;
var
  S: String;
  DotPos: Integer;
begin
  Result := 0;
  S := Ver;
  if (Length(S) > 0) and ((S[1] = 'v') or (S[1] = 'V')) then
    S := Copy(S, 2, Length(S) - 1);
  DotPos := Pos('.', S);
  if DotPos > 0 then
    S := Copy(S, 1, DotPos - 1);
  Result := StrToIntDef(S, 0);
end;

// Check if NSSM is available on PATH
function NssmInstalled: Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec('cmd.exe', '/C nssm version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
            and (ResultCode = 0);
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
  ClaudeVer: String;
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
    Info := Info + '      Node.js 18+ is required for the Dispatch Agent.' + #13#10;
    Info := Info + '      Download from: https://nodejs.org/' + #13#10;
  end;

  Info := Info + #13#10;

  // --- Claude Code CLI ---
  if ClaudeCliInstalled then
  begin
    ClaudeVer := GetClaudeVersion;
    Info := Info + '[OK]  Claude Code CLI is installed: ' + ClaudeVer + #13#10;
  end
  else
  begin
    Info := Info + '[!!]  Claude Code CLI is NOT installed.' + #13#10;
    Info := Info + '      The agent requires Claude Code to execute tasks.' + #13#10;
    Info := Info + '      Install: npm install -g @anthropic-ai/claude-code' + #13#10;
  end;

  Info := Info + #13#10;

  // --- NSSM ---
  if NssmInstalled then
    Info := Info + '[OK]  NSSM is installed (Windows service helper).' + #13#10
  else
  begin
    Info := Info + '[--]  NSSM is not installed (optional).' + #13#10;
    Info := Info + '      NSSM is needed only if you want to run the agent' + #13#10;
    Info := Info + '      as a Windows service. Download: https://nssm.cc/' + #13#10;
  end;

  Info := Info + #13#10;
  Info := Info + '---------------------------------------------' + #13#10;
  Info := Info + 'You may continue even if prerequisites are missing,' + #13#10;
  Info := Info + 'but you will need to install them before running the agent.' + #13#10;

  PrereqMemo.Text := Info;
end;

// Called when the wizard initialises
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
    if not NodeJsInstalled then
    begin
      if MsgBox('Node.js was not found on this system.' + #13#10 + #13#10 +
                'The Dispatch Agent requires Node.js 18 or newer.' + #13#10 +
                'Would you like to open the Node.js download page now?',
                mbConfirmation, MB_YESNO) = IDYES then
      begin
        ShellExec('open', 'https://nodejs.org/en/download/', '', '', SW_SHOWNORMAL, ewNoWait, ResultCode);
      end;
    end;

    if not ClaudeCliInstalled then
    begin
      if MsgBox('Claude Code CLI was not found on this system.' + #13#10 + #13#10 +
                'The agent needs Claude Code to execute tasks.' + #13#10 +
                'Install it later with: npm install -g @anthropic-ai/claude-code' + #13#10 + #13#10 +
                'Would you like to install it now? (requires npm)',
                mbConfirmation, MB_YESNO) = IDYES then
      begin
        Exec('cmd.exe', '/C npm install -g @anthropic-ai/claude-code', '',
             SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode);
      end;
    end;
  end;
end;

// Confirm uninstall
function InitializeUninstall: Boolean;
begin
  Result := MsgBox('This will uninstall {#MyAppName} and remove any associated Windows services.' + #13#10 + #13#10 +
                   'Continue?', mbConfirmation, MB_YESNO) = IDYES;
end;
