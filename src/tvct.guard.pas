{
  tvct.guard.pas - guard-page buffers and fault recovery for the decode path
  (src/c/tvct_guard.c).

  GuardAlloc returns a buffer that ends exactly at a PROT_NONE page, so a write
  past its end faults instead of corrupting the next allocation. GuardRun
  catches that fault and reports it, which turns a decoder bug or a hostile
  stream into a decode error. Recovery is opt-in: the command line enables it,
  a library leaves the host's signal handlers alone.
}
unit tvct.guard;

{$mode objfpc}{$H+}
{$IFDEF TVCT_CHECKED}{$R+}{$Q+}{$ELSE}{$R-}{$Q-}{$ENDIF}


interface

type
  { The callback GuardRun calls; it must not raise. }
  TGuardProc = procedure (Ctx: Pointer); cdecl;

function GuardAlloc(N: SizeInt): Pointer;
procedure GuardFree(P: Pointer; N: SizeInt);
{ Runs Fn(Ctx); returns 0, or -1 when the callback touched a guard page. }
function GuardRun(Fn: TGuardProc; Ctx: Pointer): Int32;
{ Turns fault recovery on or off and returns the previous state. }
function GuardEnable(On: Int32): Int32;
function GuardAvailable: Boolean;
{ Writes one byte past a guarded buffer: 1 when the fault was caught. }
function GuardSelfTest: Boolean;

implementation

function tvct_guard_alloc(N: SizeInt): Pointer; cdecl;
  external name 'tvct_guard_alloc';
procedure tvct_guard_free(P: Pointer; N: SizeInt); cdecl;
  external name 'tvct_guard_free';
function tvct_guard_run(Fn: TGuardProc; Ctx: Pointer): Int32; cdecl;
  external name 'tvct_guard_run';
function tvct_guard_enable(On: Int32): Int32; cdecl;
  external name 'tvct_guard_enable';
function tvct_guard_available: Int32; cdecl;
  external name 'tvct_guard_available';
function tvct_guard_selftest: Int32; cdecl;
  external name 'tvct_guard_selftest';

function GuardAlloc(N: SizeInt): Pointer;
begin
  Result := tvct_guard_alloc(N);
end;

procedure GuardFree(P: Pointer; N: SizeInt);
begin
  tvct_guard_free(P, N);
end;

function GuardRun(Fn: TGuardProc; Ctx: Pointer): Int32;
begin
  Result := tvct_guard_run(Fn, Ctx);
end;

function GuardEnable(On: Int32): Int32;
begin
  Result := tvct_guard_enable(On);
end;

function GuardAvailable: Boolean;
begin
  Result := tvct_guard_available <> 0;
end;

function GuardSelfTest: Boolean;
begin
  Result := tvct_guard_selftest <> 0;
end;

end.
