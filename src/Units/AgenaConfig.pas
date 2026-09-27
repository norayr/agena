unit AgenaConfig;

{$mode delphi}{$H+}

interface

type
  { Everything agena reads from its INI file. }

  TAgenaConfig = record
    BindAddress: string;
    Port: Integer;
    DocumentRoot: string;
    CertFile: string;
    KeyFile: string;
    RequireTLS13: Boolean;
    CGIPrefix: string;
  end;

{ Reads AFileName.  Relative paths inside the file are resolved against the
  directory holding it, so a config can be moved together with its www tree.
  Raises Exception if the file cannot be read. }
function LoadAgenaConfig(const AFileName: string): TAgenaConfig;

implementation

uses
  SysUtils, Classes, IniFiles, AgenaLog;

function LoadAgenaConfig(const AFileName: string): TAgenaConfig;
var
  Ini: TIniFile;
  Base: string;
begin
  if not FileExists(AFileName) then
    raise Exception.Create('configuration file not found: ' + AFileName);

  Base := IncludeTrailingPathDelimiter(
    ExtractFilePath(ExpandFileName(AFileName)));

  Ini := TIniFile.Create(AFileName);
  try
    Result.BindAddress := Ini.ReadString('server', 'BindAddress', '0.0.0.0');
    Result.Port := Ini.ReadInteger('server', 'Port', 1965);
    Result.DocumentRoot := ExpandFileName(
      Ini.ReadString('server', 'DocumentRoot', Base + 'www'));
    Result.CertFile := ExpandFileName(
      Ini.ReadString('tls', 'CertificateFile', Base + 'cert.pem'));
    Result.KeyFile := ExpandFileName(
      Ini.ReadString('tls', 'PrivateKeyFile', Base + 'key.pem'));
    Result.RequireTLS13 := Ini.ReadBool('tls', 'RequireTLS13', False);
    Result.CGIPrefix := Ini.ReadString('cgi', 'PathPrefix', '/cgi-bin/');

    if Result.Port <= 0 then
      raise Exception.Create('server/Port must be a positive number');
    if Result.Port > 65535 then
      raise Exception.Create('server/Port must be below 65536');
  finally
    Ini.Free;
  end;

  LogLine('config      ' + AFileName);
  LogLine('document root ' + Result.DocumentRoot);
  LogLine('cgi prefix    ' + Result.CGIPrefix);
end;

end.
