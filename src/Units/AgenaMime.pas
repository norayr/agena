unit AgenaMime;

{$mode delphi}{$H+}

interface

type
  TAgenaMimeType = record
    Extension: string;
    Meta: string;
  end;
  TAgenaMimeTypes = array of TAgenaMimeType;

{ Response metadata for a file path, chosen from its extension. }
function MetaForPath(const APath: string;
  const AOverrides: TAgenaMimeTypes): string;

implementation

uses
  SysUtils;

function MetaForPath(const APath: string;
  const AOverrides: TAgenaMimeTypes): string;
var
  Ext: string;
  I: Integer;
begin
  Ext := LowerCase(ExtractFileExt(APath));
  for I := 0 to High(AOverrides) do
    if Ext = '.' + AOverrides[I].Extension then
      Exit(AOverrides[I].Meta);
  if Ext = '' then
    Exit('text/plain');
  if (Ext = '.gmi') or (Ext = '.gemini') then
    Exit('text/gemini; charset=utf-8');
  if Ext = '.txt' then
    Exit('text/plain; charset=utf-8');
  if Ext = '.md' then
    Exit('text/markdown; charset=utf-8');
  if (Ext = '.html') or (Ext = '.htm') then
    Exit('text/html; charset=utf-8');
  if Ext = '.css' then
    Exit('text/css; charset=utf-8');
  if Ext = '.js' then
    Exit('text/javascript; charset=utf-8');
  if Ext = '.json' then
    Exit('application/json');
  if Ext = '.svg' then
    Exit('image/svg+xml');
  if Ext = '.png' then
    Exit('image/png');
  if (Ext = '.jpg') or (Ext = '.jpeg') then
    Exit('image/jpeg');
  if Ext = '.gif' then
    Exit('image/gif');
  if Ext = '.webp' then
    Exit('image/webp');
  if Ext = '.ico' then
    Exit('image/vnd.microsoft.icon');
  if Ext = '.mp3' then
    Exit('audio/mpeg');
  if Ext = '.ogg' then
    Exit('audio/ogg');
  if Ext = '.pdf' then
    Exit('application/pdf');
  Result := 'application/octet-stream';
end;

end.
