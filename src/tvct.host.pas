{
  tvct.host.pas - host queries.

  FPC 3.2.2's TThread.ProcessorCount reports 1 on this machine even though the
  process is allowed on all cores, so the count is taken from the OS directly.
}
unit tvct.host;

{$mode objfpc}{$H+}

interface

{ Number of logical CPUs available to the process; at least 1. }
function CpuCount: Int32;

implementation

{$IFDEF LINUX}
uses
  Classes, SysUtils;

function CpuCount: Int32;
var
  Lines: TStringList;
  i: Int32;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile('/proc/cpuinfo');
    except
      Exit(1);
    end;
    for i := 0 to Lines.Count - 1 do
      if Pos('processor', Lines[i]) = 1 then
        Inc(Result);
  finally
    Lines.Free;
  end;
  if Result < 1 then
    Result := 1;
  if Result > 64 then
    Result := 64;
end;
{$ELSE}
{$IFDEF WINDOWS}
function CpuCount: Int32;
type
  TSystemInfo = record
    ProcessorArchitecture: Word;
    Reserved: Word;
    PageSize: LongWord;
    MinimumApplicationAddress: Pointer;
    MaximumApplicationAddress: Pointer;
    ActiveProcessorMask: PtrUInt;
    NumberOfProcessors: LongWord;
    ProcessorType: LongWord;
    AllocationGranularity: LongWord;
    ProcessorLevel: Word;
    ProcessorRevision: Word;
  end;
var
  Info: TSystemInfo;
begin
  GetSystemInfo(Info);
  Result := Int32(Info.NumberOfProcessors);
  if Result < 1 then
    Result := 1;
end;
{$ELSE}
{$IFDEF DARWIN}
function sysctlbyname(Name: PChar; OldP: Pointer; OldLen: PSizeInt;
  NewP: Pointer; NewLen: SizeInt): Int32; cdecl; external name 'sysctlbyname';

function CpuCount: Int32;
var
  N: Int32;
  Len: SizeInt;
begin
  N := 1;
  Len := SizeOf(N);
  if sysctlbyname('hw.logicalcpu', @N, @Len, nil, 0) <> 0 then
    N := 1;
  Result := N;
end;
{$ELSE}
function CpuCount: Int32;
begin
  Result := 1;
end;
{$ENDIF}
{$ENDIF}
{$ENDIF}

end.
