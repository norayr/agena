unit AgenaServer;

{$mode delphi}{$H+}

interface

uses
  Classes, IdContext, IdTCPServer, IdSocketHandle, IdSSL, IdGemini,
  IdGeminiServer, AgenaConfig;

{ A Gemini server that serves a document root and runs CGI programs found
  under the configured prefix.

  The TaurusTLS IOHandler is supplied by the caller. }

type
  TAgenaServer = class(TIdGeminiServer)
  private
    FConfig: TAgenaConfig;
    procedure HandleRequest(AContext: TIdContext; const AURL: string;
      out Status: TGeminiStatus; out Meta: string; var Response: TStream);
    procedure ServeStatic(const AHost: TAgenaVirtualHost;
      const URLPath: string; out Status: TGeminiStatus;
      out Meta: string; var Response: TStream);
    function SelectHost(AContext: TIdContext; const AHostname, APort: string;
      out AHost: TAgenaVirtualHost): Boolean;
    procedure ServeNotFound(var Response: TStream; out Status: TGeminiStatus;
      out Meta: string);
  public
    procedure Configure(const AConfig: TAgenaConfig);
    procedure Listen(ABindAddress: string; APort: Integer);
  end;

implementation

uses
  SysUtils, IdGlobal, IdURI, TaurusTLS, TaurusTLSHeaders_tls1,
  AgenaLog, AgenaMime, AgenaPaths, AgenaCGI, AgenaIDN;

procedure TAgenaServer.Configure(const AConfig: TAgenaConfig);
begin
  FConfig := AConfig;
  OnGeminiRequest := HandleRequest;
end;

procedure TAgenaServer.Listen(ABindAddress: string; APort: Integer);
var
  Binding: TIdSocketHandle;
begin
  Binding := Bindings.Add;
  Binding.IP := ABindAddress;
  Binding.Port := APort;
  Active := True;
  LogLine(Format('listening on  %s:%d', [ABindAddress, APort]));
end;

procedure TAgenaServer.ServeNotFound(var Response: TStream;
  out Status: TGeminiStatus; out Meta: string);
begin
  Status := gsTempFailure;
  Meta := 'text/gemini; charset=utf-8';
  WriteStringToStream(Response,
    '# not found' + LineEnding + LineEnding + 'Nothing here.' + LineEnding,
    IndyTextEncoding_UTF8);
end;

procedure TAgenaServer.ServeStatic(const AHost: TAgenaVirtualHost;
  const URLPath: string;
  out Status: TGeminiStatus; out Meta: string; var Response: TStream);
var
  Full: string;
  F: TFileStream;
begin
  Full := ResolveUnderRoot(AHost.DocumentRoot, URLPath, AHost.IndexFile);
  if Full = '' then
  begin
    ServeNotFound(Response, Status, Meta);
    Exit;
  end;

  try
    F := TFileStream.Create(Full, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
    begin
      LogLine('cannot open ' + Full + ': ' + E.Message);
      ServeNotFound(Response, Status, Meta);
      Exit;
    end;
  end;

  { Fill Indy's response rather than abandoning its preallocated stream. }
  try
    Response.CopyFrom(F, 0);
    Status := gsSuccess;
    Meta := MetaForPath(Full, FConfig.MimeTypes);
  finally
    F.Free;
  end;
end;

function TAgenaServer.SelectHost(AContext: TIdContext;
  const AHostname, APort: string; out AHost: TAgenaVirtualHost): Boolean;
var
  Name, SNI: string;
  I, Port: Integer;
  Handler: TTaurusTLSIOHandlerSocket;
  ServerName: PAnsiChar;
begin
  Result := False;
  if Length(FConfig.VirtualHosts) = 0 then
  begin
    { Preserve the original unnamed, single-host configuration. }
    AHost.Hostname := AHostname;
    AHost.DocumentRoot := FConfig.DocumentRoot;
    AHost.IndexFile := FConfig.IndexFile;
    AHost.CertFile := FConfig.CertFile;
    AHost.KeyFile := FConfig.KeyFile;
    AHost.CGIPrefix := FConfig.CGIPrefix;
    Exit(True);
  end;

  Port := 1965;
  if (APort <> '') and not TryStrToInt(APort, Port) then
    Exit;
  if Port <> FConfig.Port then
    Exit;
  try
    Name := IDNToASCII(AHostname);
  except
    on E: EConvertError do
      Exit;
  end;

  if not (AContext.Connection.IOHandler is TTaurusTLSIOHandlerSocket) then
    Exit;
  Handler := TTaurusTLSIOHandlerSocket(AContext.Connection.IOHandler);
  if (Handler.SSLSocket = nil) or (Handler.SSLSocket.SSL = nil) then
    Exit;
  ServerName := SSL_get_servername(Handler.SSLSocket.SSL,
    TLSEXT_NAMETYPE_host_name);
  if ServerName = nil then
  begin
    { No SNI uses the first host's certificate, so only serve that host. }
    if Name <> FConfig.VirtualHosts[0].Hostname then
      Exit;
  end
  else
  begin
    try
      SNI := IDNToASCII(string(ServerName));
    except
      on E: EConvertError do
        Exit;
    end;
    if SNI <> Name then
      Exit;
  end;

  for I := 0 to High(FConfig.VirtualHosts) do
    if FConfig.VirtualHosts[I].Hostname = Name then
    begin
      AHost := FConfig.VirtualHosts[I];
      Exit(True);
    end;
end;

procedure TAgenaServer.HandleRequest(AContext: TIdContext; const AURL: string;
  out Status: TGeminiStatus; out Meta: string; var Response: TStream);
var
  U: TIdURI;
  Path: string;
  Query: string;
  Prefix: string;
  Q: Integer;
  Host: TAgenaVirtualHost;
begin
  { TIdURI follows the HTTP-era convention of splitting a URL into a
    directory Path and a Document, so "/cgi-bin/hello.py" comes back as
    Path="/cgi-bin/" and Document="hello.py".  The two have to be joined again
    before the path can be resolved. }
  U := TIdURI.Create(AURL);
  try
    if not SelectHost(AContext, U.Host, U.Port, Host) then
    begin
      Status := gsPermFailure;
      Meta := 'Unknown virtual host or mismatched SNI/URL authority';
      LogLine('DENY ' + AURL);
      Exit;
    end;
    Path := U.Path + U.Document;
    Query := U.Params;
  finally
    U.Free;
  end;

  { Be explicit: a query string must not reach the path resolver. }
  Q := Pos('?', Path);
  if Q > 0 then
    Path := Copy(Path, 1, Q - 1);

  if (Path <> '') and (Path[1] = '/') then
    Path := Copy(Path, 2, Length(Path));

  Prefix := Host.CGIPrefix;
  while (Prefix <> '') and (Prefix[1] = '/') do
    Delete(Prefix, 1, 1);

  if (Prefix <> '') and (Length(Path) >= Length(Prefix)) and
     (CompareText(Copy(Path, 1, Length(Prefix)), Prefix) = 0) then
  begin
    LogLine('CGI  ' + AURL);
    RunAgenaCGI(AContext, Host.DocumentRoot, Host.Hostname, AURL, Path, Query,
      Status, Meta, Response);
  end
  else
  begin
    LogLine('GET  ' + AURL);
    ServeStatic(Host, Path, Status, Meta, Response);
  end;
end;

end.
