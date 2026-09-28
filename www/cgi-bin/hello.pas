program hello;

// A native Pascal CGI script for agena.
//
// Standard output is the response body.  An optional first line of
// "Content-Type: <mime>" sets the response metadata and is not part of
// the body.
//
// Build:  fpc -O1 hello.pas -ohello

{$mode delphi}{$H+}

uses
  SysUtils;

function EnvOr(const AName, AFallback: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := AFallback;
end;

var
  Query: string;
  InputText: string;
  ContentLength: Integer;
  Read: Integer;
begin
  WriteLn('Content-Type: text/gemini; charset=utf-8');
  WriteLn;
  WriteLn('# hello from a Pascal CGI script');
  WriteLn;
  WriteLn('asked for ', EnvOr('GEMINI_URL', '?'));
  WriteLn('method:    ', EnvOr('REQUEST_METHOD', 'GET'));

  Query := EnvOr('QUERY_STRING', '');
  if Query <> '' then
    WriteLn('query:     ', Query)
  else
    WriteLn('no query string');

  WriteLn('remote:    ', EnvOr('REMOTE_ADDR', '?'));
  WriteLn('server:    ', EnvOr('SERVER_NAME', '?'), ':',
    EnvOr('SERVER_PORT', '?'));

  { Request input arrives on stdin, with CONTENT_LENGTH bytes of it. }
  ContentLength := StrToIntDef(EnvOr('CONTENT_LENGTH', '0'), 0);
  if ContentLength > 0 then
  begin
    SetLength(InputText, ContentLength);
    Read := 0;
    if Length(InputText) > 0 then
      Read := FileRead(StdInputHandle, InputText[1], ContentLength);
    SetLength(InputText, Read);
    if InputText <> '' then
      WriteLn('input:     ', StringReplace(InputText, LineEnding,
        ' | ', [rfReplaceAll]))
    else
      WriteLn('input:     (none after all)');
  end
  else
    WriteLn('input:     none');
end.
