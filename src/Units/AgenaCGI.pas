unit AgenaCGI;

{$mode delphi}{$H+}

interface

uses
  Classes, IdContext, IdGemini, IdGeminiServer;

{ Runs the program named by AScriptPath under ADocumentRoot and makes its
  standard output the response body.

  The script's standard input receives any Gemini request input, and
  CONTENT_LENGTH reports its length, so a script can distinguish a query with
  input from one without.

  If the first output line is a "Content-Type: ..." header it is taken as the
  response metadata and stripped from the body; otherwise the body is used as
  is and the metadata defaults to text/gemini. }
procedure RunAgenaCGI(AContext: TIdContext; const ADocumentRoot, ARawURL,
  AScriptPath, AQuery: string; out Status: TGeminiStatus; out Meta: string;
  var Response: TStream);

implementation

uses
  SysUtils, Process, IdGlobal, IdSocketHandle, IdIOHandler, AgenaLog,
  AgenaPaths;

const
  CONTENT_TYPE_HEADER = 'Content-Type:';

{ The request input, if any, consumed from the connection. }
function TakeRequestInput(AContext: TIdContext): string;
var
  H: TIdIOHandler;
begin
  Result := '';
  H := AContext.Connection.IOHandler;
  if H = nil then
    Exit;
  if H.InputBufferIsEmpty then
    Exit;
  Result := H.InputBufferAsString(nil);
  if Result <> '' then
    Result := Result + LineEnding;
end;

function ServerNameFor(AContext: TIdContext): string;
begin
  Result := AContext.Binding.IP;
  if (Result = '') or (Result = '0.0.0.0') or (Result = '::') then
    Result := 'localhost';
end;

procedure Fail(out Status: TGeminiStatus; out Meta: string; var Response: TStream;
  const Msg: string);
begin
  Status := gsTempFailure;
  Meta := 'text/gemini; charset=utf-8';
  TIdGeminiServer.WriteStringToStream(Response, Msg, TEncoding.UTF8);
end;

procedure RunAgenaCGI(AContext: TIdContext; const ADocumentRoot, ARawURL,
  AScriptPath, AQuery: string; out Status: TGeminiStatus; out Meta: string;
  var Response: TStream);
var
  Script: string;
  P: TProcess;
  OutLines: TStringList;
  InputData: string;
  Body: string;
  FirstLine: string;
  Eol: Integer;
begin
  Script := ResolveUnderRoot(ADocumentRoot, AScriptPath);
  if Script = '' then
  begin
    Status := gsTempFailure;
    Meta := 'text/gemini; charset=utf-8';
    TIdGeminiServer.WriteStringToStream(Response, '# no such script' + LineEnding,
      TEncoding.UTF8);
    Exit;
  end;

  InputData := TakeRequestInput(AContext);

  P := TProcess.Create(nil);
  OutLines := TStringList.Create;
  try
    P.Executable := Script;
    P.CurrentDirectory := ADocumentRoot;
    { poUsePipes gives us both the stdout pipe we read and the stdin pipe we
      hand the request input to. }
    P.Options := [poUsePipes];

    { The environment list belongs to P: TProcess.Destroy frees it, and the
      property refuses to be set to nil, so it must not be freed here. }
    P.Environment := TStringList.Create;
    P.Environment.Add('SERVER_PROTOCOL=GEMINI');
    P.Environment.Add('SERVER_SOFTWARE=agena');
    P.Environment.Add('SERVER_NAME=' + ServerNameFor(AContext));
    P.Environment.Add('SERVER_PORT=' +
      IntToStr(AContext.Connection.Socket.Binding.Port));
    P.Environment.Add('REQUEST_METHOD=' +
      BoolToStr(InputData <> '', 'POST', 'GET'));
    P.Environment.Add('SCRIPT_NAME=' + AScriptPath);
    P.Environment.Add('SCRIPT_FILENAME=' + Script);
    P.Environment.Add('PATH_INFO=' + AScriptPath);
    P.Environment.Add('QUERY_STRING=' + AQuery);
    P.Environment.Add('GEMINI_URL=' + ARawURL);
    P.Environment.Add('REMOTE_ADDR=' + AContext.Connection.Socket.Binding.PeerIP);
    P.Environment.Add('CONTENT_LENGTH=' + IntToStr(Length(InputData)));
    P.Environment.Add('DOCUMENT_ROOT=' + ADocumentRoot);

    try
      P.Execute;

      { Always close stdin, whether or not there was input. A script that
        reads stdin would otherwise wait for a close that never comes. }
      if P.Input <> nil then
      begin
        if InputData <> '' then
          P.Input.WriteBuffer(InputData[1], Length(InputData));
        P.CloseInput;
      end;

      { Drain stdout before waiting.  Waiting first would deadlock as soon as
        a script writes more than the pipe buffer holds. }
      if P.Output <> nil then
        OutLines.LoadFromStream(P.Output);

      { FPC spells this WaitOnExit; it also has a timeout overload. }
      P.WaitOnExit;

      if P.ExitCode <> 0 then
      begin
        LogLine(Format('cgi %s exited with %d', [Script, P.ExitCode]));
        Fail(Status, Meta, Response, '# cgi error' + LineEnding);
        Exit;
      end;

      Body := OutLines.Text;
      Meta := 'text/gemini; charset=utf-8';

      Eol := Pos(LineEnding, Body);
      if Eol > 0 then
      begin
        FirstLine := Copy(Body, 1, Eol - 1);
        if (Length(FirstLine) > Length(CONTENT_TYPE_HEADER)) and
           (CompareText(Copy(FirstLine, 1, Length(CONTENT_TYPE_HEADER)),
             CONTENT_TYPE_HEADER) = 0) then
        begin
          Meta := Trim(Copy(FirstLine, Length(CONTENT_TYPE_HEADER) + 1,
            Length(FirstLine)));
          Delete(Body, 1, Eol + Length(LineEnding) - 1);
          { CGI separates the headers from the body with a blank line, so drop
            that too rather than leaving it at the top of the gemtext. }
          if Copy(Body, 1, Length(LineEnding)) = LineEnding then
            Delete(Body, 1, Length(LineEnding));
        end;
      end;

      Status := gsSuccess;
      TIdGeminiServer.WriteStringToStream(Response, Body, TEncoding.UTF8);
    except
      on E: Exception do
      begin
        LogLine('cgi ' + Script + ': ' + E.Message);
        Fail(Status, Meta, Response, '# cgi failure' + LineEnding);
      end;
    end;
  finally
    OutLines.Free;
    P.Free;
  end;
end;

end.
