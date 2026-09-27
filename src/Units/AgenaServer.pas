unit AgenaServer;

{$mode delphi}{$H+}

interface

uses
  Classes, IdContext, IdTCPServer, IdSocketHandle, IdSSL, IdGemini,
  IdGeminiServer, AgenaConfig;

{ A Gemini server that serves a document root and runs CGI programs found
  under the configured prefix.

  The IOHandler is supplied by the caller, so the same class works with
  TaurusTLS or with Indy's own OpenSSL handler. }

type
  TAgenaServer = class(TIdGeminiServer)
  private
    FConfig: TAgenaConfig;
    procedure HandleRequest(AContext: TIdContext; const AURL: string;
      out Status: TGeminiStatus; out Meta: string; var Response: TStream);
    procedure ServeStatic(const URLPath: string; out Status: TGeminiStatus;
      out Meta: string; var Response: TStream);
    procedure ServeNotFound(var Response: TStream; out Status: TGeminiStatus;
      out Meta: string);
  public
    procedure Configure(const AConfig: TAgenaConfig);
    procedure Listen(ABindAddress: string; APort: Integer);
  end;

implementation

uses
  SysUtils, IdURI, AgenaLog, AgenaMime, AgenaPaths, AgenaCGI;

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
  TIdGeminiServer.WriteStringToStream(Response,
    '# not found' + LineEnding + LineEnding + 'Nothing here.' + LineEnding,
    TEncoding.UTF8);
end;

procedure TAgenaServer.ServeStatic(const URLPath: string;
  out Status: TGeminiStatus; out Meta: string; var Response: TStream);
var
  Full: string;
  F: TFileStream;
begin
  Full := ResolveUnderRoot(FConfig.DocumentRoot, URLPath);
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

  { Indy frees the stream once the request is written. }
  Status := gsSuccess;
  Meta := MetaForPath(Full);
  Response := F;
end;

procedure TAgenaServer.HandleRequest(AContext: TIdContext; const AURL: string;
  out Status: TGeminiStatus; out Meta: string; var Response: TStream);
var
  U: TIdURI;
  Path: string;
  Query: string;
  Prefix: string;
  Q: Integer;
begin
  { TIdURI follows the HTTP-era convention of splitting a URL into a
    directory Path and a Document, so "/cgi-bin/hello.py" comes back as
    Path="/cgi-bin/" and Document="hello.py".  The two have to be joined again
    before the path can be resolved. }
  U := TIdURI.Create(AURL);
  try
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

  Prefix := FConfig.CGIPrefix;
  while (Prefix <> '') and (Prefix[1] = '/') do
    Delete(Prefix, 1, 1);

  if (Prefix <> '') and (Length(Path) >= Length(Prefix)) and
     (CompareText(Copy(Path, 1, Length(Prefix)), Prefix) = 0) then
  begin
    LogLine('CGI  ' + AURL);
    RunAgenaCGI(AContext, FConfig.DocumentRoot, AURL, Path, Query, Status, Meta,
      Response);
  end
  else
  begin
    LogLine('GET  ' + AURL);
    ServeStatic(Path, Status, Meta, Response);
  end;
end;

end.
