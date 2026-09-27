unit AgenaPaths;

{$mode delphi}{$H+}

interface

{ Maps a request path onto a file inside the document root.
  Returns an absolute filename, or '' when the path escapes the root, is
  absolute, or names a file that does not exist.  A directory path, or an
  empty path, resolves to "index.gmi" inside it.

  This is the only place that turns a URL into a filename, so it is the only
  place that has to be careful about traversal. }
function ResolveUnderRoot(const ADocumentRoot, AURLPath: string): string;

implementation

uses
  SysUtils;

{ True when AFull is ADirectory itself or sits below it.  ADirectory carries a
  trailing path delimiter, which is what stops "/srv/wwwroot" from counting as
  being inside "/srv/www". }
function PathIsUnder(const ADirectory, AFull: string): Boolean;
begin
{$IFDEF MSWINDOWS}
  Result := CompareText(Copy(AFull, 1, Length(ADirectory)), ADirectory) = 0;
{$ELSE}
  Result := Copy(AFull, 1, Length(ADirectory)) = ADirectory;
{$ENDIF}
end;

function ResolveUnderRoot(const ADocumentRoot, AURLPath: string): string;
var
  Rel: string;
  Root: string;
  Full: string;
begin
  Result := '';

  Rel := StringReplace(AURLPath, '\', '/', [rfReplaceAll]);
  while (Rel <> '') and (Rel[1] = '/') do
    Delete(Rel, 1, 1);

  { A colon in the first segment would make it a drive or stream spec. }
  if Pos(':', Rel) > 0 then
    Exit('');

  if (Rel = '') or (Rel[Length(Rel)] = '/') then
    Rel := Rel + 'index.gmi';

  Root := IncludeTrailingPathDelimiter(ExpandFileName(ADocumentRoot));
  Full := ExpandFileName(Root + Rel);

  if not PathIsUnder(Root, Full) then
    Exit('');

  if not FileExists(Full) then
    Exit('');

  Result := Full;
end;

end.
