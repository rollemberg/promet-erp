unit umain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, simpleipc, FileUtil, ExtCtrls, Menus, Controls, ActnList,
  uProcessManagement,process, XMLConf,uSystemMessage,uBaseDbClasses,uBaseERPDBClasses,
  Graphics, LCLType,umashineid,uBaseVisualApplication;

type
  TfMain = class(TDataModule)
    acHistory: TAction;
    acExit: TAction;
    acMarkRead: TAction;
    ActionList1: TActionList;
    IPCTimer: TIdleTimer;
    ImageList1: TImageList;
    ImageList2: TImageList;
    ImageList3: TImageList;
    MenuItem1: TMenuItem;
    miExit: TMenuItem;
    miHistory: TMenuItem;
    pmTray: TPopupMenu;
    ProgTimer: TTimer;
    TrayIcon: TTrayIcon;
    procedure acExitExecute(Sender: TObject);
    procedure acHistoryExecute(Sender: TObject);
    procedure acMarkReadExecute(Sender: TObject);
    procedure aItemClick(Sender: TObject);
    procedure ApplicationEndSession(Sender: TObject);
    procedure DataModuleCreate(Sender: TObject);
    procedure DataModuleDestroy(Sender: TObject);
    procedure IPCTimerTimer(Sender: TObject);
    procedure ProgTimerTimer(Sender: TObject);
    procedure TrayIconClick(Sender: TObject);
    procedure TrayIconDblClick(Sender: TObject);
  private
    { private declarations }
    aNow: TDateTime;
    aRefresh : Integer;
    FFilter: string;
    InformRecTime : TDateTime;
    FHistory : TBaseHistory;
    Processes : array of TProcProcess;
    function CommandReceived(Sender : TObject;aCommand : string) : Boolean;
    procedure SetFilter(AValue: string);
    procedure SwitchAnimationOff;
    procedure DoExit;
  public
    { public declarations }
    property History : TBaseHistory read FHistory;
    property Filter : string read FFilter write SetFilter;
  end;
var
  fMain: TfMain;
implementation
uses uData,Utils,Forms,uBaseApplication,uIntfStrConsts,math,eventlog,uBaseDBInterface,
  umTimeLine,XMLPropStorage,LCLProc,uprometipc;
{$R *.lfm}
const
  RefreshAll = 30;//5 mins refresh
resourcestring
  strNewEntrys        = 'Neue Einträge in Verlauf';
  strNewEntrysC       = 'Sie haben %d neue Einträge in Ihrem Verlauf';

function OnMessageReceived(aMessage: string): Boolean;
begin
  Result := fMain.CommandReceived(nil,aMessage);
end;
procedure TfMain.ProgTimerTimer(Sender: TObject);
var
  aProcess: String;
  Found: Boolean;
  tmp: String;
  i: Integer;
  bProcess: TProcProcess;
  cmd : string;
  sl: TStringList;
  a: Integer;
  Process: TProcProcess;
  aLog: TStringList;
  procedure DoLog(aStr: string;bLog : TStringList);
  begin
    with Application as IBaseApplication do
      Log(aStr);
    bLog.Add(aStr);
  end;
  function BuildCmdLine : string;
  begin
    with Data.ProcessClient.Processes.Parameters.DataSet do
      begin
        First;
        while not EOF do
          begin
            cmd := cmd+' '+{$IFNDEF WINDOWS}'"'+{$ENDIF}'--'+FieldByName('NAME').AsString+'='+{$IFDEF WINDOWS}'"'+{$ENDIF}FieldByName('VALUE').AsString;
            Next;
          end;
      end;
    if pos('--mandant',lowercase(cmd)) = 0 then
      begin
        {$IFDEF WINDOWS}
        cmd := cmd+' --mandant="'+Application.GetOptionValue('m','mandant')+'"';
        {$ELSE}
        cmd := cmd+' --mandant='+Application.GetOptionValue('m','mandant')+'';
        {$ENDIF}
      end;
    if Data.Users.DataSet.Active then
      cmd := cmd+' '+{$IFNDEF WINDOWS}'"'+{$ENDIF}'--user='+{$IFDEF WINDOWS}'"'+{$ENDIF}Data.Users.FieldByName('NAME').AsString+'"';
  end;
begin
  if not Data.Ping(Data.MainConnection) then exit;
  ProgTimer.Enabled:=False;
  try
  with Application as IBaseApplication do
    begin
      aNow := Now();
      if aNow > 0 then
        begin
          if aRefresh = 0 then
            begin
              Data.ProcessClient.DataSet.Refresh;
              Data.ProcessClient.Processes.DataSet.Refresh;
              aRefresh:=RefreshAll;
            end;
          if Data.ProcessClient.DataSet.Locate('NAME',GetSystemName,[]) then
            if Data.ProcessClient.FieldByName('STATUS').AsString <> 'R' then
              begin
                Application.Terminate;
                exit;
              end;
          aLog := TStringList.Create;
          Data.ProcessClient.Processes.DataSet.First;
          while not Data.ProcessClient.Processes.DataSet.EOF do
            begin
              //aLog.Text := Data.ProcessClient.Processes.DataSet.FieldByName('LOG').AsString;
              aProcess := Data.ProcessClient.Processes.FieldByName('NAME').AsString;
              if FileExistsUTF8(ExpandFileNameUTF8(aProcess+ExtractFileExt(Application.ExeName))) then
                begin
                  Found := False;
                  tmp := aProcess;
                  for i := 0 to length(Processes)-1 do
                    if copy(Processes[i].CommandLine,0,length(tmp)) = tmp then
                      begin
                        bProcess := Processes[i];
                        if bProcess.Active then
                          Found := True
                        else
                          begin
                            tmp := aProcess+BuildCmdLine;
                            sl := TStringList.Create;
                            sl.LoadFromStream(bProcess.Output);
                            for a := 0 to sl.Count-1 do
                              Log(aprocess+':'+sl[a]);
                            sl.Free;
                            if not bProcess.Informed then
                              begin
                                DoLog(aprocess+':'+strExitted,aLog);
                                if Data.ProcessClient.Processes.DataSet.FieldByName('LOG').AsString<>aLog.Text then
                                  begin
                                    if not Data.ProcessClient.Processes.CanEdit then Data.ProcessClient.Processes.DataSet.Edit;
                                    Data.ProcessClient.Processes.DataSet.FieldByName('LOG').AsString:=aLog.Text;
                                    Data.ProcessClient.Processes.DataSet.Post;
                                  end;
                                bProcess.DoExit;
                                bProcess.Informed := True;
                              end;
                            if (aNow > bProcess.Timeout) {and (bProcess.Timeout > 0)} then
                              begin
                                DoLog(aprocess+':'+strStartingProcessTimeout+' '+DateTimeToStr(bProcess.Timeout)+'>'+DateTimeToStr(aNow),aLog);
                                bProcess.Timeout := aNow+(max(Data.ProcessClient.Processes.FieldByName('INTERVAL').AsInteger,2)/MinsPerDay);
                                DoLog(aProcess+':'+strStartingProcess+' ('+bProcess.CommandLine+')',aLog);
                                bProcess.Execute;
                                bProcess.Informed := False;
                                DoLog(aprocess+':'+strStartingNextTimeout+' '+DateTimeToStr(bProcess.Timeout),aLog);
                              end;
                            Found := True;
                          end;
                      end;
                  if not Found then
                    begin
                      aLog.Clear;
                      cmd := aProcess+ExtractFileExt(Application.ExeName);
                      cmd := cmd+BuildCmdLine;
                      DoLog(aProcess+':'+strStartingProcess+' ('+cmd+')',aLog);
                      Process := TProcProcess.Create(Self);
                      Process.Id := Data.ProcessClient.Processes.Id.AsVariant;
                      Process.Informed:=False;
                      Setlength(Processes,length(Processes)+1);
                      Processes[length(Processes)-1] := Process;
                      Process.CommandLine:=cmd;
                      Process.CurrentDirectory:=Application.Location;
                      Process.Options := [poNoConsole,poUsePipes];
                      Process.Execute;
                      Process.Timeout := aNow+(max(Data.ProcessClient.Processes.FieldByName('INTERVAL').AsInteger,2)/MinsPerDay);
                      DoLog(aprocess+':'+strStartingNextTimeout+' '+DateTimeToStr(Processes[i].Timeout),aLog);
                    end;
                end
              else DoLog(ExpandFileNameUTF8(aProcess+ExtractFileExt(Application.ExeName))+':'+'File dosend exists',aLog);
              Data.ProcessClient.Processes.DataSet.Next;
            end;
          aLog.Free;
        end;
    end;
  except
  end;
  if acHistory.Enabled then
    begin
      //Show new History Entrys
      if (FHistory.DataSet.EOF) then //all shown, refresh list
        begin
          Data.SetFilter(FHistory,'('+FFilter+') AND ('+Data.QuoteField('TIMESTAMPD')+'>='+Data.DateTimeToFilter(InformRecTime)+')',30,'TIMESTAMPD','DESC');
          History.DataSet.Refresh;
          History.DataSet.First;
        end;
      if (FHistory.Count > 0) then
        begin
          TrayIcon.BalloonTitle:=strNewEntrys;
          tmp := '';
          while not FHistory.DataSet.EOF do
            begin
              if FHistory.FieldByName('CHANGEDBY').AsString <> Data.Users.FieldByName('IDCODE').AsString then
                begin
                  tmp:=tmp+FHistory.FieldByName('ACTION').AsString+' '+FHistory.FieldByName('REFERENCE').AsString+lineending;
                end;
              FHistory.DataSet.Next;
            end;
          if tmp <> '' then
            begin
              TrayIcon.BalloonHint:=tmp;
              TrayIcon.ShowBalloonHint;
              TrayIcon.Icons := ImageList2;
              TrayIcon.Animate:=True;
              InformRecTime:=History.TimeStamp.AsDateTime+0.0001;
              with Application as IBaseDBInterface do
                DBConfig.WriteString('INFORMRECTIME',DateTimeToStr(InformRecTime));
              TrayIcon.Tag := 0;
            end;
        end;
    end;
  {$IFDEF LINUX}
  Trayicon.visible := False;
  TrayIcon.Visible:=True;
  {$ENDIF}
  ProgTimer.Enabled:=True;
end;

procedure TfMain.TrayIconClick(Sender: TObject);
begin
  if (not Assigned(fmTimeline)) or (not fmTimeline.Visible) then
    begin
      fmTimeline.Execute;
      SwitchAnimationOff;
    end
  else fmTimeline.Close;
end;

procedure TfMain.TrayIconDblClick(Sender: TObject);
begin

end;

function TfMain.CommandReceived(Sender: TObject; aCommand: string
  ): Boolean;
var
  tmp: String;
  aMenue: TMenuItem;
  Found: Boolean = False;
  aItem: TMenuItem;
  tmp1: String;
  i: Integer;
  aMessage: String;
begin
  debugln('CommdReceived:'+aCommand);
  Result := False;
  aMessage := aCommand;
  if copy(aMessage,0,9) = 'AddMenue(' then
    begin
      tmp := copy(aMessage,10,length(aMessage));
      tmp := copy(tmp,0,length(tmp)-1);
      aMenue := pmTray.Items;
      while length(tmp)>0 do
        begin
          tmp1 := copy(tmp,0,pos('/',tmp)-1);
          if pos('/',tmp) = 0 then
            begin
              tmp1 := tmp;
              tmp := ''
            end
          else  tmp := copy(tmp,pos('/',tmp)+1,length(tmp));
          Found := False;
          for i := 0 to aMenue.Count-1 do
            if aMenue.Items[i].Caption = tmp1 then
              begin
                Found := True;
                aMenue := aMenue.Items[i];
                break;
              end;
          if not Found then
            begin
              aItem := TMenuItem.Create(Self);
              aItem.Caption:=tmp1;
              aItem.OnClick:=@aItemClick;
              aMenue.Add(aItem);
              aMenue := aItem;
              acExit.Visible:=False;
            end;
        end;
      Result := True;
    end
  else if copy(aMessage,0,12) = 'RemoveMenue(' then
    begin
      tmp := copy(aMessage,13,length(aMessage));
      tmp := copy(tmp,0,length(tmp)-1);
      aMenue := pmTray.Items;
      while length(tmp)>0 do
        begin
          tmp1 := copy(tmp,0,pos('/',tmp)-1);
          if pos('/',tmp) = 0 then
            begin
              tmp1 := tmp;
              tmp := ''
            end
          else  tmp := copy(tmp,pos('/',tmp)+1,length(tmp));
          Found := False;
          for i := 0 to aMenue.Count-1 do
            if aMenue.Items[i].Caption = tmp1 then
              begin
                Found := True;
                aMenue := aMenue.Items[i];
                aMenue.Free;
                Result := True;
                if pmTray.Items.Count=2 then
                  acExit.Visible:=True;
                exit;
              end;
        end;
      Result := True;
    end;
end;

procedure TfMain.SetFilter(AValue: string);
begin
  if FFilter=AValue then Exit;
  FFilter:=AValue;
end;

procedure TfMain.SwitchAnimationOff;
begin
  if TrayIcon.Tag=0 then
    begin
      TrayIcon.Animate:=False;
      TrayIcon.Icons := ImageList3;
      TrayIcon.Animate:=True;
      TrayIcon.Tag := 1;
    end;
end;

procedure TfMain.DoExit;
begin
  try
    if Data.ProcessClient.DataSet.Locate('NAME',GetSystemName,[]) then
      begin
        Data.ProcessClient.DataSet.Edit;
        Data.ProcessClient.FieldByName('STATUS').AsString:='N';
        Data.ProcessClient.DataSet.Post;
      end;
  except
  end;
end;

procedure TfMain.DataModuleCreate(Sender: TObject);
var
  XMLConfig: TXMLPropStorage;
  aUser: String;
  aMandant: String;
  function FindSettings(bMandant,aConfig : string) : Boolean;
  var
    aID: LongInt;
  begin
    Result := False;
    with Application as IBaseApplication do
      if FileExists(GetOurConfigDir+aConfig+'.xml') then
        begin
          XMLConfig := TXMLPropStorage.Create(Self);
          XMLConfig.Filename:=GetOurConfigDir+aConfig+'.xml';
          XMLConfig.RootNodePath:='Config';
          XMLConfig.Restore;
          if copy(XMLConfig.ReadString('LOGINMANDANT',''),0,length(bMandant)) = bMandant then
            begin
              Result := True;
              aID := CreateUserID;
              if ((XMLConfig.ReadString('AUTOMATICLOGIN','') = IntToStr(aId)) and (aId <> 0)) then
                aUser := XMLConfig.ReadString('LOGINUSER','');
              aMandant := XMLConfig.ReadString('LOGINMANDANT','');
            end;
          XMLConfig.Free;
        end;
  end;

begin
  TrayIcon.AnimateInterval:=200;
  aRefresh:=0;
  Application.OnEndSession:=@ApplicationEndSession;
  with Application as IBaseApplication do
    begin
      with Application as IBaseApplication do
        begin
          SetConfigName('MessageManager');
          AppVersion:={$I ../base/version.inc};
          AppRevision:={$I ../base/revision.inc};
        end;
      Info('processmanager starting...');
      with BaseApplication as IBaseDbInterface do
        begin
          Info('loading mandants...');
          if not LoadMandants then
            begin
              Error(strFailedtoLoadMandants);
              raise Exception.Create(strFailedtoLoadMandants);
              Application.Terminate;
            end;
          Info('search user...');
          FindSettings(aMandant,'PrometERP');
          if Application.GetOptionValue('m','mandant') <> '' then
            aMandant := Application.GetOptionValue('m','mandant');
          if Application.GetOptionValue('u','user') <> '' then
            aUser := Application.GetOptionValue('u','user');
          if aUser = '' then FindSettings(aMandant,'Timeregistering');
          if aUser = '' then FindSettings(aMandant,'Statistics');
          Info('User:'+aUser);
          Info('Mandant:'+aMandant);
          Info('login...');
          if aMandant = '' then
            begin
              debugln(strMandantnotSelected);
              acHistory.Enabled:=False;
              exit;
            end;
          if not DBLogin(aMandant,aUser,False,False) then
            begin
              debugln(strLoginFailed+' '+LastError);
              acHistory.Enabled:=False;
              aUser := '';
              aMandant := '';
              FindSettings(aMandant,'PrometERP');
              if aUser = '' then FindSettings(aMandant,'Timeregistering');
              if aUser = '' then FindSettings(aMandant,'Statistics');
              Info('User:'+aUser);
              Info('Mandant:'+aMandant);
              Info('relogin...');
              if not DBLogin(aMandant,aUser,False,False) then
                begin
                  debugln(strLoginFailed+' '+LastError);
                  acHistory.Enabled:=False;
                  exit;
                end;
            end;
          uData.Data := Data;
        end;
      Info('processmanager login successful');
      Data.ProcessClient.CreateTable;
      Data.ProcessClient.Open;
      if not Data.ProcessClient.DataSet.Locate('NAME',GetSystemName,[]) then
        begin
          Data.ProcessClient.Insert;
          Data.ProcessClient.FieldByName('NAME').AsString:=GetSystemName;
          Data.ProcessClient.FieldByName('STATUS').AsString:='R';
          Data.ProcessClient.DataSet.Post;
          Info(getSystemName+' added and running');
        end
      else
        begin
          Data.ProcessClient.DataSet.Edit;
          Data.ProcessClient.FieldByName('STATUS').AsString:='R';
          Data.ProcessClient.DataSet.Post;
          Info(getSystemName+' running');
        end;
      Data.ProcessClient.Processes.Open;
      Data.ProcessClient.Processes.Parameters.Open;
    end;
  acHistory.Enabled:=aUser <> '';
  FHistory := TBaseHistory.Create(Self,Data);
  FHistory.CreateTable;
  with Application as IBaseDBInterface do
    InformRecTime := StrToDateTime(DBConfig.ReadString('INFORMRECTIME',DateTimeToStr(Now()-5)));
  if aUser <> '' then
    begin
      FFilter := '('+Data.QuoteField('REF_ID')+'='+Data.QuoteValue(Data.Users.Id.AsString)+') OR ('+Data.QuoteField('REFERENCE')+'='+Data.QuoteValue(Data.Users.FieldByName('IDCODE').AsString)+')';
      Data.SetFilter(FHistory,'('+FFilter+') AND ('+Data.QuoteField('TIMESTAMPD')+'>'+Data.DateTimeToFilter(InformRecTime)+')',30,'TIMESTAMPD','DESC');
      FHistory.Open;
    end;
  ProgTimer.Enabled:=True;
  uprometipc.OnMessageReceived:=@OnMessageReceived;
end;
procedure TfMain.acHistoryExecute(Sender: TObject);
begin
  fmTimeline.Execute;
  SwitchAnimationOff;
end;

procedure TfMain.acMarkReadExecute(Sender: TObject);
begin
  SwitchAnimationOff;
end;

procedure TfMain.acExitExecute(Sender: TObject);
begin
  DoExit;
  FreeAndNil(FHistory);
  Application.Terminate;
end;

procedure TfMain.aItemClick(Sender: TObject);
var
  aItem: TMenuItem;
  tmp: string;
  i: Integer;
  sl: TStringList;
begin
  aItem := TMenuItem(Sender);
  tmp := aItem.Caption;
  while Assigned(aItem.Parent) do
    begin
      aItem := aItem.Parent;
      tmp := aItem.Caption+'/'+tmp;
    end;

  SendIPCMessage('OnClick('+tmp+')');
end;

procedure TfMain.ApplicationEndSession(Sender: TObject);
begin
  DoExit;
end;

procedure TfMain.DataModuleDestroy(Sender: TObject);
var
  i: Integer;
begin
  //fmTimeline.Free;
  for i := 0 to length(Processes)-1 do
    Processes[i].Free;
end;

procedure TfMain.IPCTimerTimer(Sender: TObject);
begin
  PeekIPCMessages;
end;

end.

