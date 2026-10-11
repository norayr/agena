program idn_probe;

{$mode delphi}{$H+}

uses
  SysUtils, Character, AgenaIDN;

function StrictUTF8(const AValue: string): UnicodeString;
begin
  Result := UTF8Decode(AValue);
  if RawByteString(UTF8Encode(Result)) <> RawByteString(AValue) then
    raise EConvertError.Create('invalid UTF-8 in probe input');
end;

function Scalars(const AValue: string): UnicodeString;
var
  I, Start: Integer;
begin
  Result := '';
  Start := 1;
  for I := 1 to Length(AValue) + 1 do
    if (I > Length(AValue)) or (AValue[I] = ',') then
    begin
      Result := Result + TCharacter.ConvertFromUtf32(
        StrToInt('$' + Copy(AValue, Start, I - Start)));
      Start := I + 1;
    end;
end;

var
  Line, Mode, Value, Answer: string;
  Separator: Integer;
begin
  while not EOF(Input) do
  begin
    ReadLn(Line);
    Separator := Pos(#9, Line);
    Mode := Copy(Line, 1, Separator - 1);
    Value := Copy(Line, Separator + 1, Length(Line));
    try
      if Mode = 'ascii' then
        Answer := IDNToASCII(Value)
      else if Mode = 'unicode' then
        Answer := IDNToUnicode(Value)
      else if Mode = 'encode' then
        Answer := PunycodeEncode(StrictUTF8(Value))
      else if Mode = 'encode32' then
        Answer := PunycodeEncode(Scalars(Value))
      else if Mode = 'decode' then
        Answer := string(UTF8Encode(PunycodeDecode(Value)))
      else
        raise Exception.Create('unknown probe mode');
      WriteLn('OK', #9, Answer);
    except
      on E: Exception do
        WriteLn('ERROR', #9, E.Message);
    end;
  end;
end.
