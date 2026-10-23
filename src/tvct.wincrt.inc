{
  tvct.wincrt.inc - C runtime entry points for the vendored C code, Windows only.

  Included by each program after its uses clause. Aliases declared inside a unit
  are dropped by the smart linker; at program level they are kept.
}
{$IFDEF WINDOWS}
{$LINKLIB kernel32}
{$LINKLIB advapi32}
{ Both x86 targets need Intel syntax for the ___chkstk_ms probe below; FPC
  defaults to AT&T on x86-64. }
{$IFDEF CPUX86}{$ASMMODE INTEL}{$ENDIF}
{$IFDEF CPUX86_64}{$ASMMODE INTEL}{$ENDIF}

function wc_malloc(Size: PtrUInt): Pointer; cdecl; alias: {$IFDEF CPUX86_64}'malloc'{$ELSE}'_malloc'{$ENDIF};
begin
  Result := GetMem(Size);
end;

function wc_calloc(N, Size: PtrUInt): Pointer; cdecl; alias: {$IFDEF CPUX86_64}'calloc'{$ELSE}'_calloc'{$ENDIF};
var
  Total: PtrUInt;
begin
  Total := N * Size;
  Result := GetMem(Total);
  if Result <> nil then
    FillChar(Result^, Total, 0);
end;

procedure wc_free(P: Pointer); cdecl; alias: {$IFDEF CPUX86_64}'free'{$ELSE}'_free'{$ENDIF};
begin
  if P <> nil then
    FreeMem(P);
end;

function wc_memcpy(Dst, Src: Pointer; N: PtrUInt): Pointer; cdecl; alias: {$IFDEF CPUX86_64}'memcpy'{$ELSE}'_memcpy'{$ENDIF};
begin
  if N > 0 then
    Move(Src^, Dst^, N);
  Result := Dst;
end;

function wc_memmove(Dst, Src: Pointer; N: PtrUInt): Pointer; cdecl; alias: {$IFDEF CPUX86_64}'memmove'{$ELSE}'_memmove'{$ENDIF};
begin
  if N > 0 then
    Move(Src^, Dst^, N);
  Result := Dst;
end;

function wc_memset(Dst: Pointer; C: LongInt; N: PtrUInt): Pointer; cdecl; alias: {$IFDEF CPUX86_64}'memset'{$ELSE}'_memset'{$ENDIF};
begin
  if N > 0 then
    FillChar(Dst^, N, Byte(C));
  Result := Dst;
end;

procedure wc_chkstk; assembler; nostackframe; alias: '___chkstk_ms';
asm
{$IFDEF CPUX86_64}
  push rcx
  push rax
  cmp rax, $1000
  lea rcx, [rsp + $18]
  jb @done
@probe:
  sub rcx, $1000
  or qword ptr [rcx], 0
  sub rax, $1000
  cmp rax, $1000
  ja @probe
@done:
  sub rcx, rax
  or qword ptr [rcx], 0
  pop rax
  pop rcx
  ret
{$ELSE}
  push ecx
  push eax
  cmp eax, $1000
  lea ecx, [esp + $0C]
  jb @done
@probe:
  sub ecx, $1000
  or dword ptr [ecx], 0
  sub eax, $1000
  cmp eax, $1000
  ja @probe
@done:
  sub ecx, eax
  or dword ptr [ecx], 0
  pop eax
  pop ecx
  ret
{$ENDIF}
end;

{$ENDIF}
