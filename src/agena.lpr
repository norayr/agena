program agena;

{ agena - a small Gemini server.

  Reads an INI file, serves a document root and runs CGI programs, over TLS
  provided by TaurusTLS. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, TaurusTLS, AgenaConfig, AgenaLog, AgenaServer;

procedure CheckCertificateFiles(const AName, ACertFile, AKeyFile: string);
begin
  if not FileExists(ACertFile) then
    raise Exception.Create(AName + ': certificate not found: ' + ACertFile);
  if not FileExists(AKeyFile) then
    raise Exception.Create(AName + ': private key not found: ' + AKeyFile);
end;

var
  Config: TAgenaConfig;
  Server: TAgenaServer;
  TaurusHandler: TTaurusTLSServerIOHandler;
  I: Integer;
begin
  if (ParamCount < 1) or (ParamStr(1) = '') then
  begin
    WriteLn('usage: ', ExtractFileName(ParamStr(0)), ' [config.ini]');
    Halt(1);
  end;

  try
    Config := LoadAgenaConfig(ParamStr(1));
    if Length(Config.VirtualHosts) = 0 then
      CheckCertificateFiles('server', Config.CertFile, Config.KeyFile)
    else
      for I := 0 to High(Config.VirtualHosts) do
        with Config.VirtualHosts[I] do
          CheckCertificateFiles(Hostname, CertFile, KeyFile);
  except
    on E: Exception do
    begin
      WriteLn('config error: ', E.Message);
      Halt(1);
    end;
  end;

  Server := TAgenaServer.Create(nil);
  try
    Server.Configure(Config);

    { TLS, including SNI certificate selection, belongs to TaurusTLS. }
    TaurusHandler := TTaurusTLSServerIOHandler.Create(Server);
    if Length(Config.VirtualHosts) = 0 then
    begin
      TaurusHandler.DefaultCert.PublicKey := Config.CertFile;
      TaurusHandler.DefaultCert.PrivateKey := Config.KeyFile;
    end
    else
    begin
      TaurusHandler.DefaultCert.PublicKey := Config.VirtualHosts[0].CertFile;
      TaurusHandler.DefaultCert.PrivateKey := Config.VirtualHosts[0].KeyFile;
      for I := 0 to High(Config.VirtualHosts) do
        with TaurusHandler.Certificates.AddX509File do
        begin
          PublicKey := Config.VirtualHosts[I].CertFile;
          PrivateKey := Config.VirtualHosts[I].KeyFile;
        end;
    end;
    if Config.RequireTLS13 then
      TaurusHandler.SSLOptions.MinTLSVersion := TLSv1_3
    else
      TaurusHandler.SSLOptions.MinTLSVersion := TLSv1_2;
    Server.IOHandler := TaurusHandler;
    LogLine('TLS backend:   TaurusTLS, TLS 1.3 available');

    Server.Listen(Config.BindAddress, Config.Port);
    LogLine('Ctrl-C to stop');

    while Server.Active do
      Sleep(250);
  except
    on E: Exception do
    begin
      LogLine('fatal: ' + E.Message);
      Server.Free;
      Halt(1);
    end;
  end;

  Server.Free;
  LogLine('stopped');
end.
