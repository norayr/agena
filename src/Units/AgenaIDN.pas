unit AgenaIDN;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

{ RFC 3492 Punycode, independent of Indy, Lazarus and external libraries.
  Raw label functions preserve code points, including non-BMP characters.
  Domain functions take/return UTF-8, lowercase with the RTL's Unicode tables,
  validate DNS labels and check ACE round trips. They are not a full IDNA/UTS46
  implementation: supply NFC-normalized names; no contextual or bidi mapping
  is performed. }
function PunycodeEncode(const ALabel: UnicodeString): string;
function PunycodeDecode(const ALabel: string): UnicodeString;
function IDNToASCII(const AHost: string): string;
function IDNToUnicode(const AHost: string): string;

implementation

uses
  SysUtils, Character;

const
  PunyBase = 36;
  PunyTMin = 1;
  PunyTMax = 26;
  PunySkew = 38;
  PunyDamp = 700;
  PunyInitialBias = 72;
  PunyInitialN = 128;

type
  TCodePoints = array of Cardinal;

procedure Invalid(const AReason: string);
begin
  raise EConvertError.Create('invalid IDN/Punycode: ' + AReason);
end;

function CodePoints(const AText: UnicodeString): TCodePoints;
var
  I, Count, Width: Integer;
  C: Cardinal;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  I := 1;
  Count := 0;
  while I <= Length(AText) do
  begin
    C := TCharacter.ConvertToUtf32(AText, I, Width);
    if (C >= $D800) and (C <= $DFFF) then
      Invalid('unpaired surrogate');
    Result[Count] := C;
    Inc(Count);
    Inc(I, Width);
  end;
  SetLength(Result, Count);
end;

function Adapt(ADelta, ACount: Cardinal; AFirst: Boolean): Cardinal;
var
  K: Cardinal;
begin
  if AFirst then
    ADelta := ADelta div PunyDamp
  else
    ADelta := ADelta div 2;
  ADelta := ADelta + ADelta div ACount;
  K := 0;
  while ADelta > ((PunyBase - PunyTMin) * PunyTMax) div 2 do
  begin
    ADelta := ADelta div (PunyBase - PunyTMin);
    Inc(K, PunyBase);
  end;
  Result := K + ((PunyBase - PunyTMin + 1) * ADelta) div
    (ADelta + PunySkew);
end;

function Threshold(AK, ABias: Cardinal): Cardinal;
begin
  if AK <= ABias then
    Result := PunyTMin
  else if AK - ABias >= PunyTMax then
    Result := PunyTMax
  else
    Result := AK - ABias;
end;

function EncodeDigit(ADigit: Cardinal): AnsiChar;
begin
  if ADigit < 26 then
    Result := AnsiChar(Ord('a') + ADigit)
  else
    Result := AnsiChar(Ord('0') + ADigit - 26);
end;

function DecodeDigit(ADigit: AnsiChar): Cardinal;
begin
  case ADigit of
    'a'..'z': Result := Ord(ADigit) - Ord('a');
    'A'..'Z': Result := Ord(ADigit) - Ord('A');
    '0'..'9': Result := Ord(ADigit) - Ord('0') + 26;
  else
    Invalid('bad encoded digit');
    Result := 0;
  end;
end;

function PunycodeEncode(const ALabel: UnicodeString): string;
var
  Points: TCodePoints;
  C, N, M, Delta, Bias, Q, K, T: Cardinal;
  I, Basic, Handled: Integer;
begin
  Points := CodePoints(ALabel);
  Result := '';
  for I := 0 to High(Points) do
    if Points[I] < 128 then
      Result := Result + AnsiChar(Points[I]);
  Basic := Length(Result);
  Handled := Basic;
  if Basic > 0 then
    Result := Result + '-';
  N := PunyInitialN;
  Delta := 0;
  Bias := PunyInitialBias;
  while Handled < Length(Points) do
  begin
    M := High(Cardinal);
    for I := 0 to High(Points) do
      if (Points[I] >= N) and (Points[I] < M) then
        M := Points[I];
    if M - N > (High(Cardinal) - Delta) div Cardinal(Handled + 1) then
      Invalid('encoding overflow');
    Delta := Delta + (M - N) * Cardinal(Handled + 1);
    N := M;
    for I := 0 to High(Points) do
    begin
      C := Points[I];
      if C < N then
      begin
        if Delta = High(Cardinal) then
          Invalid('encoding overflow');
        Inc(Delta);
      end;
      if C = N then
      begin
        Q := Delta;
        K := PunyBase;
        while True do
        begin
          T := Threshold(K, Bias);
          if Q < T then
            Break;
          Result := Result + EncodeDigit(T + (Q - T) mod (PunyBase - T));
          Q := (Q - T) div (PunyBase - T);
          Inc(K, PunyBase);
        end;
        Result := Result + EncodeDigit(Q);
        Bias := Adapt(Delta, Handled + 1, Handled = Basic);
        Delta := 0;
        Inc(Handled);
      end;
    end;
    if Delta = High(Cardinal) then
      Invalid('encoding overflow');
    Inc(Delta);
    Inc(N);
  end;
end;

function PunycodeDecode(const ALabel: string): UnicodeString;
var
  Points: TCodePoints;
  N, Index, OldIndex, Weight, Digit, K, T, Bias, Count: Cardinal;
  I, J, Delimiter, Cursor: Integer;
begin
  Points := nil;
  Delimiter := 0;
  for I := 1 to Length(ALabel) do
    if ALabel[I] = '-' then
      Delimiter := I;
  if Delimiter > 0 then
  begin
    SetLength(Points, Delimiter - 1);
    for I := 1 to Delimiter - 1 do
    begin
      if Ord(ALabel[I]) >= 128 then
        Invalid('non-ASCII basic character');
      Points[I - 1] := Ord(ALabel[I]);
    end;
    Cursor := Delimiter + 1;
  end
  else
    Cursor := 1;
  N := PunyInitialN;
  Index := 0;
  Bias := PunyInitialBias;
  while Cursor <= Length(ALabel) do
  begin
    OldIndex := Index;
    Weight := 1;
    K := PunyBase;
    while True do
    begin
      if Cursor > Length(ALabel) then
        Invalid('truncated encoded integer');
      Digit := DecodeDigit(ALabel[Cursor]);
      Inc(Cursor);
      if Digit > (High(Cardinal) - Index) div Weight then
        Invalid('decoding overflow');
      Index := Index + Digit * Weight;
      T := Threshold(K, Bias);
      if Digit < T then
        Break;
      if Weight > High(Cardinal) div (PunyBase - T) then
        Invalid('decoding overflow');
      Weight := Weight * (PunyBase - T);
      Inc(K, PunyBase);
    end;
    Count := Length(Points) + 1;
    Bias := Adapt(Index - OldIndex, Count, OldIndex = 0);
    if Index div Count > $10FFFF - N then
      Invalid('code point out of range');
    N := N + Index div Count;
    if (N >= $D800) and (N <= $DFFF) then
      Invalid('surrogate code point');
    Index := Index mod Count;
    SetLength(Points, Count);
    for J := Integer(Count) - 1 downto Integer(Index) + 1 do
      Points[J] := Points[J - 1];
    Points[Index] := N;
    Inc(Index);
  end;
  Result := '';
  for I := 0 to High(Points) do
    Result := Result + TCharacter.ConvertFromUtf32(Points[I]);
end;

procedure ValidateLabel(const ALabel: UnicodeString);
var
  I, Width: Integer;
  C: Cardinal;
  Category: TUnicodeCategory;
begin
  if (ALabel = '') or (ALabel[1] = '-') or
     (ALabel[Length(ALabel)] = '-') then
    Invalid('empty label or leading/trailing hyphen');
  if (Length(ALabel) >= 4) and (ALabel[3] = '-') and (ALabel[4] = '-') then
    Invalid('reserved hyphens in Unicode label');
  I := 1;
  while I <= Length(ALabel) do
  begin
    C := TCharacter.ConvertToUtf32(ALabel, I, Width);
    if C < 128 then
    begin
      if not (AnsiChar(C) in ['a'..'z', '0'..'9', '-']) then
        Invalid('non-DNS character');
    end
    else
    begin
      Category := TCharacter.GetUnicodeCategory(ALabel, I);
      if not (Category in [TUnicodeCategory.ucUppercaseLetter,
        TUnicodeCategory.ucLowercaseLetter, TUnicodeCategory.ucTitlecaseLetter,
        TUnicodeCategory.ucModifierLetter, TUnicodeCategory.ucOtherLetter,
        TUnicodeCategory.ucDecimalNumber, TUnicodeCategory.ucNonSpacingMark,
        TUnicodeCategory.ucCombiningMark]) then
        Invalid('disallowed Unicode character');
      if (I = 1) and (Category in [TUnicodeCategory.ucNonSpacingMark,
        TUnicodeCategory.ucCombiningMark]) then
        Invalid('leading combining mark');
    end;
    Inc(I, Width);
  end;
end;

function IDNToASCII(const AHost: string): string;
var
  Host, LabelText, Decoded: UnicodeString;
  LabelASCII: string;
  Start, I, J: Integer;
  NonASCII: Boolean;
begin
  if (AHost = '') or (Length(AHost) > 1024) then
    Invalid('empty or overlong hostname');
  Host := UTF8Decode(AHost);
  if RawByteString(UTF8Encode(Host)) <> RawByteString(AHost) then
    Invalid('malformed UTF-8');
  Host := TCharacter.ToLower(Host);
  if (Host <> '') and (Host[Length(Host)] = '.') then
    Delete(Host, Length(Host), 1);
  Result := '';
  Start := 1;
  for I := 1 to Length(Host) + 1 do
    if (I > Length(Host)) or (Host[I] = '.') then
    begin
      LabelText := Copy(Host, Start, I - Start);
      NonASCII := False;
      for J := 1 to Length(LabelText) do
        if Ord(LabelText[J]) >= 128 then
          NonASCII := True;
      if NonASCII then
      begin
        ValidateLabel(LabelText);
        LabelASCII := 'xn--' + PunycodeEncode(LabelText);
      end
      else
      begin
        LabelASCII := string(UTF8Encode(LabelText));
        if Copy(LabelASCII, 1, 4) = 'xn--' then
        begin
          Decoded := PunycodeDecode(Copy(LabelASCII, 5, Length(LabelASCII)));
          ValidateLabel(Decoded);
          NonASCII := False;
          for J := 1 to Length(Decoded) do
            if Ord(Decoded[J]) >= 128 then
              NonASCII := True;
          if not NonASCII or (TCharacter.ToLower(Decoded) <> Decoded) or
             ('xn--' + PunycodeEncode(Decoded) <> LabelASCII) then
            Invalid('non-canonical ACE label');
        end
        else
          ValidateLabel(LabelText);
      end;
      if Length(LabelASCII) > 63 then
        Invalid('label exceeds 63 bytes');
      if Result <> '' then
        Result := Result + '.';
      Result := Result + LabelASCII;
      Start := I + 1;
    end;
  if (Result = '') or (Length(Result) > 253) then
    Invalid('hostname exceeds 253 bytes');
end;

function IDNToUnicode(const AHost: string): string;
var
  Host, LabelASCII: string;
  I, Start: Integer;
begin
  Host := IDNToASCII(AHost);
  Result := '';
  Start := 1;
  for I := 1 to Length(Host) + 1 do
    if (I > Length(Host)) or (Host[I] = '.') then
    begin
      LabelASCII := Copy(Host, Start, I - Start);
      if Result <> '' then
        Result := Result + '.';
      if Copy(LabelASCII, 1, 4) = 'xn--' then
        Result := Result + string(UTF8Encode(PunycodeDecode(
          Copy(LabelASCII, 5, Length(LabelASCII)))))
      else
        Result := Result + LabelASCII;
      Start := I + 1;
    end;
end;

end.
