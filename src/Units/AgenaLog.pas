unit AgenaLog;

{$mode delphi}{$H+}

interface

{ Timestamped line to standard output, flushed so it interleaves usefully with
  a supervisor's log. }

procedure LogLine(const Msg: string);

implementation

uses
  SysUtils, Classes;

procedure LogLine(const Msg: string);
begin
  WriteLn(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), ' ', Msg);
  Flush(Output);
end;

end.
