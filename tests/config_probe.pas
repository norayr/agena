program config_probe;

{$mode delphi}{$H+}

uses
  AgenaConfig;

var
  Config: TAgenaConfig;
  I: Integer;
begin
  Config := LoadAgenaConfig(ParamStr(1));
  for I := 0 to High(Config.BindAddresses) do
    WriteLn('BIND', #9, Config.BindAddresses[I]);
end.
