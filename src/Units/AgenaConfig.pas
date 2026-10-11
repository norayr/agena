unit AgenaConfig;

{$mode delphi}{$H+}

interface

uses
  AgenaMime;

type
  TAgenaBindAddresses = array of string;

  TAgenaVirtualHost = record
    Hostname: string;
    DocumentRoot: string;
    IndexFile: string;
    CertFile: string;
    KeyFile: string;
    CGIPrefix: string;
  end;
  TAgenaVirtualHosts = array of TAgenaVirtualHost;

  { Everything agena reads from its INI file. }

  TAgenaConfig = record
    BindAddresses: TAgenaBindAddresses;
    Port: Integer;
    DocumentRoot: string;
    CertFile: string;
    KeyFile: string;
    RequireTLS13: Boolean;
    CGIPrefix: string;
    IndexFile: string;
    VirtualHosts: TAgenaVirtualHosts;
    MimeTypes: TAgenaMimeTypes;
  end;

{ Reads AFileName.  Relative paths inside the file are resolved against the
  directory holding it, so a config can be moved together with its www tree.
  Raises Exception if the file cannot be read. }
function LoadAgenaConfig(const AFileName: string): TAgenaConfig;

implementation

uses
  SysUtils, Classes, IniFiles, Sockets, AgenaLog, AgenaIDN;

procedure LoadBindAddresses(const AValue: string;
  out AAddresses: TAgenaBindAddresses);
var
  I, J, K, Start, Count, N: Integer;
  Address, Canonical: string;
  IPv4: TInAddr;
  IPv6: TIn6Addr;
  IsIPv6, IsWildcard, PreviousWildcard: Boolean;
begin
  Count := 1;
  for I := 1 to Length(AValue) do
    if AValue[I] = ',' then
      Inc(Count);
  SetLength(AAddresses, Count);
  Start := 1;
  N := 0;
  for I := 1 to Length(AValue) + 1 do
    if (I > Length(AValue)) or (AValue[I] = ',') then
    begin
      Address := Trim(Copy(AValue, Start, I - Start));
      if Address = '' then
        raise Exception.Create('server/BindAddress contains an empty address');
      IsIPv6 := Pos(':', Address) > 0;
      if IsIPv6 then
      begin
        if not TryStrToHostAddr6(Address, IPv6) then
          raise Exception.Create('invalid IP address in server/BindAddress: ' + Address);
        { IPv6-only sockets cannot accept IPv4-mapped connections. }
        if (IPv6.u6_addr32[0] = 0) and (IPv6.u6_addr32[1] = 0) and
           (IPv6.u6_addr16[4] = 0) and (IPv6.u6_addr16[5] = htons($FFFF)) then
          raise Exception.Create('IPv4-mapped listener is not supported; use an IPv4 address: ' + Address);
        { An expanded form provides a stable key for duplicate detection. }
        Canonical := '';
        for K := 0 to 7 do
        begin
          if K > 0 then
            Canonical := Canonical + ':';
          Canonical := Canonical + LowerCase(IntToHex(ntohs(IPv6.u6_addr16[K]), 1));
        end;
        if (IPv6.u6_addr32[0] = 0) and (IPv6.u6_addr32[1] = 0) and
           (IPv6.u6_addr32[2] = 0) and (IPv6.u6_addr32[3] = 0) then
          Canonical := '::';
      end
      else
      begin
        if not TryStrToHostAddr(Address, IPv4) then
          raise Exception.Create('invalid IP address in server/BindAddress: ' + Address);
        Canonical := HostAddrToStr(IPv4);
      end;
      IsWildcard := (Canonical = '0.0.0.0') or (Canonical = '::');
      for J := 0 to N - 1 do
      begin
        if AAddresses[J] = Canonical then
          raise Exception.Create('duplicate address in server/BindAddress: ' + Address);
        PreviousWildcard := (AAddresses[J] = '0.0.0.0') or (AAddresses[J] = '::');
        if (IsIPv6 = (Pos(':', AAddresses[J]) > 0)) and
           (IsWildcard or PreviousWildcard) then
          raise Exception.Create('wildcard overlaps another address in server/BindAddress: ' + Address);
      end;
      AAddresses[N] := Canonical;
      Inc(N);
      Start := I + 1;
    end;
end;

function ConfigPath(const ABase, APath: string): string;
begin
  if APath = '' then
    raise Exception.Create('configuration path cannot be empty');
  if (APath[1] in ['/', '\']) or (ExtractFileDrive(APath) <> '') then
    Result := ExpandFileName(APath)
  else
    Result := ExpandFileName(ABase + APath);
end;

procedure ValidateIndex(const AIndex: string);
begin
  if (AIndex = '') or (AIndex = '.') or (AIndex = '..') or
     (Pos('/', AIndex) > 0) or (Pos('\', AIndex) > 0) or
     (Pos(':', AIndex) > 0) then
    raise Exception.Create('Index must be a filename, not a path');
end;

procedure LoadMimeTypes(AIni: TIniFile; out ATypes: TAgenaMimeTypes);
var
  Names: TStringList;
  I, J, K, Slash, Semi: Integer;
  Ext, Meta, Media: string;
begin
  ATypes := nil;
  Names := TStringList.Create;
  try
    AIni.ReadSection('types', Names);
    SetLength(ATypes, Names.Count);
    for I := 0 to Names.Count - 1 do
    begin
      Ext := LowerCase(Trim(Names[I]));
      if (Ext <> '') and (Ext[1] = '.') then
        Delete(Ext, 1, 1);
      if Ext = '' then
        raise Exception.Create('empty extension in [types]');
      for J := 1 to Length(Ext) do
        if not (Ext[J] in ['a'..'z', '0'..'9', '_', '-', '+']) then
          raise Exception.Create('invalid extension in [types]: ' + Names[I]);
      for J := 0 to I - 1 do
        if ATypes[J].Extension = Ext then
          raise Exception.Create('duplicate extension in [types]: ' + Ext);

      Meta := Trim(AIni.ReadString('types', Names[I], ''));
      if (Meta = '') or (Length(Meta) > 1024) or (Pos(#13, Meta) > 0) or
         (Pos(#10, Meta) > 0) or (Pos(#0, Meta) > 0) then
        raise Exception.Create('invalid MIME metadata for ' + Ext);
      Semi := Pos(';', Meta);
      if Semi > 0 then
        Media := Trim(Copy(Meta, 1, Semi - 1))
      else
        Media := Meta;
      Slash := Pos('/', Media);
      if (Slash <= 1) or (Slash = Length(Media)) then
        raise Exception.Create('invalid MIME type for ' + Ext + ': ' + Meta);
      for K := 1 to Length(Media) do
        if (K <> Slash) and not (Media[K] in ['a'..'z', 'A'..'Z', '0'..'9',
          '!', '#', '$', '&', '^', '_', '.', '+', '-']) then
          raise Exception.Create('invalid MIME type for ' + Ext + ': ' + Meta);
      ATypes[I].Extension := Ext;
      ATypes[I].Meta := Meta;
    end;
  finally
    Names.Free;
  end;
end;

function LoadAgenaConfig(const AFileName: string): TAgenaConfig;
var
  Ini: TIniFile;
  Base: string;
  Sections: TStringList;
  Section, Name, Root: string;
  I, J, N: Integer;
begin
  Result.BindAddresses := nil;
  Result.VirtualHosts := nil;
  Result.MimeTypes := nil;
  if not FileExists(AFileName) then
    raise Exception.Create('configuration file not found: ' + AFileName);

  Base := IncludeTrailingPathDelimiter(
    ExtractFilePath(ExpandFileName(AFileName)));

  Ini := TIniFile.Create(AFileName);
  try
    LoadBindAddresses(Ini.ReadString('server', 'BindAddress', '0.0.0.0'),
      Result.BindAddresses);
    Result.Port := Ini.ReadInteger('server', 'Port', 1965);
    Result.DocumentRoot := ConfigPath(Base,
      Ini.ReadString('server', 'DocumentRoot', 'www'));
    Result.CertFile := ConfigPath(Base,
      Ini.ReadString('tls', 'CertificateFile', 'cert.pem'));
    Result.KeyFile := ConfigPath(Base,
      Ini.ReadString('tls', 'PrivateKeyFile', 'key.pem'));
    Result.RequireTLS13 := Ini.ReadBool('tls', 'RequireTLS13', False);
    Result.CGIPrefix := Ini.ReadString('cgi', 'PathPrefix', '/cgi-bin/');
    Result.IndexFile := Ini.ReadString('server', 'Index', 'index.gmi');
    ValidateIndex(Result.IndexFile);
    LoadMimeTypes(Ini, Result.MimeTypes);

    Sections := TStringList.Create;
    try
      Ini.ReadSections(Sections);
      for I := 0 to Sections.Count - 1 do
      begin
        Section := Sections[I];
        if not SameText(Copy(Section, 1, 6), 'vhost:') then
          Continue;
        Name := IDNToASCII(Trim(Ini.ReadString(Section, 'Hostname',
          Copy(Section, 7, Length(Section)))));
        for J := 0 to High(Result.VirtualHosts) do
          if Result.VirtualHosts[J].Hostname = Name then
            raise Exception.Create('duplicate virtual host: ' + Name);
        Root := Ini.ReadString(Section, 'DocumentRoot', '');
        if Root = '' then
          raise Exception.Create(Section + '/DocumentRoot is required');
        N := Length(Result.VirtualHosts);
        SetLength(Result.VirtualHosts, N + 1);
        with Result.VirtualHosts[N] do
        begin
          Hostname := Name;
          DocumentRoot := ConfigPath(Base, Root);
          IndexFile := Ini.ReadString(Section, 'Index', Result.IndexFile);
          ValidateIndex(IndexFile);
          CertFile := ConfigPath(Base,
            Ini.ReadString(Section, 'CertificateFile', Result.CertFile));
          KeyFile := ConfigPath(Base,
            Ini.ReadString(Section, 'PrivateKeyFile', Result.KeyFile));
          CGIPrefix := Ini.ReadString(Section, 'CGIPrefix', Result.CGIPrefix);
        end;
      end;
    finally
      Sections.Free;
    end;

    if Result.Port <= 0 then
      raise Exception.Create('server/Port must be a positive number');
    if Result.Port > 65535 then
      raise Exception.Create('server/Port must be below 65536');
  finally
    Ini.Free;
  end;

  LogLine('config      ' + AFileName);
  if Length(Result.VirtualHosts) = 0 then
  begin
    LogLine('document root ' + Result.DocumentRoot);
    LogLine('cgi prefix    ' + Result.CGIPrefix);
  end
  else
    for I := 0 to High(Result.VirtualHosts) do
      LogLine('virtual host  ' + Result.VirtualHosts[I].Hostname + ' -> ' +
        Result.VirtualHosts[I].DocumentRoot);
end;

end.
