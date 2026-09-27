program agena;

{ agena - a small Gemini server.

  Reads an INI file, serves a document root and runs CGI programs, over TLS
  provided by TaurusTLS (the default) or by Indy's own OpenSSL handler. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, IdGlobal, IdSocketHandle, IdContext, IdTCPServer, IdSSL,
  IdSSLOpenSSL, IdGemini, IdGeminiServer, AgenaConfig, AgenaLog, AgenaServer,
  {$IFDEF USE_TAURUS}
  TaurusTLS
  {$ENDIF};

procedure ExplainMissingCertificate(const Config: TAgenaConfig);
begin
  WriteLn('certificate not found: ', Config.CertFile);
  WriteLn('generate one with:');
  WriteLn('  openssl req -x509 -newkey rsa:4096 -keyout ', Config.KeyFile,
    ' -out ', Config.CertFile, ' -days 365 -nodes -subj "/CN=localhost"');
end;

var
  Config: TAgenaConfig;
  Server: TAgenaServer;
  TaurusHandler: TTaurusTLSServerIOHandler;
  IndyHandler: TIdServerIOHandlerSSLOpenSSL;
begin
  if (ParamCount < 1) or (ParamStr(1) = '') then
  begin
    WriteLn('usage: ', ExtractFileName(ParamStr(0)), ' [config.ini]');
    Halt(1);
  end;

  try
    Config := LoadAgenaConfig(ParamStr(1));
  except
    on E: Exception do
    begin
      WriteLn('config error: ', E.Message);
      Halt(1);
    end;
  end;

  if not FileExists(Config.CertFile) then
  begin
    ExplainMissingCertificate(Config);
    Halt(1);
  end;
  if not FileExists(Config.KeyFile) then
  begin
    WriteLn('private key not found: ', Config.KeyFile);
    Halt(1);
  end;

  Server := TAgenaServer.Create(nil);
  try
    Server.Configure(Config);

{$IFDEF USE_TAURUS}
    { TaurusTLS takes over from the handler TIdGeminiServer made for itself. }
    TaurusHandler := TTaurusTLSServerIOHandler.Create(Server);
    TaurusHandler.DefaultCert.PublicKey := Config.CertFile;
    TaurusHandler.DefaultCert.PrivateKey := Config.KeyFile;
    if Config.RequireTLS13 then
      TaurusHandler.SSLOptions.MinTLSVersion := TLSv1_3
    else
      TaurusHandler.SSLOptions.MinTLSVersion := TLSv1_2;
    Server.IOHandler := TaurusHandler;
    LogLine('TLS backend:   TaurusTLS, TLS 1.3 available');
{$ELSE}
    IndyHandler := Server.SSLIOHandler;
    IndyHandler.SSLOptions.CertFile := Config.CertFile;
    IndyHandler.SSLOptions.KeyFile := Config.KeyFile;
    LogLine('TLS backend:   Indy OpenSSL, TLS 1.2 at most');
{$ENDIF}

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
