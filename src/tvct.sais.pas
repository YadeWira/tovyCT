{
  tvct.sais.pas - suffix array construction (SA-IS).

  Linear-time suffix array by Nong, Zhang and Chan, "Two Efficient Algorithms
  for Linear Time Suffix Array Construction" (2009), with the compact
  single-buffer variant from the paper's reference code.

  The implementation is written from the published algorithm. It is not derived
  from libsais, divsufsort or any other implementation.

  The top level works directly on the input bytes: the sentinel is a virtual
  position past the end, so no widened copy of the input is needed. The reduced
  problems of the recursion use Int32 symbols, because their alphabet can exceed
  256.

  SA must have room for N+1 Int32: the algorithm sorts N+1 suffixes (including
  the sentinel) and drops the first one before returning.
}
unit tvct.sais;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

var
  { Tests: ignore an available C backend and use the Pascal one. }
  SaisForcePascal: Boolean = False;

procedure SaisBuildSAPascal(const T: PByte; N: SizeInt; SA: PInt32);
procedure SaisBuildSA(const T: PByte; N: SizeInt; SA: PInt32);

{$IFDEF TVCT_LIBSAIS}
{$LINKLIB libsais}
{$IFDEF UNIX}{$LINKLIB c}{$ENDIF}
{ Vendored libsais 2.10.4, Apache-2.0. See third_party/libsais/README.md. }
function tvct_libsais(T: PByte; SA: PInt32; n: Int32; fs: Int32;
  freq: PInt32): Int32; cdecl; external name 'libsais';
{$ENDIF}

implementation

type
  PInt32Arr = ^Int32;

const
  { bytes map to 1..256; 0 is the sentinel }
  BYTE_ALPHABET = 257;

function IsLMS(const Typ: PByte; i, Sentinel: Int32): Boolean; inline;
begin
  if i <= 0 then
    Exit(False);
  if i = Sentinel then
    Exit(True);
  Result := (Typ[i] <> 0) and (Typ[i - 1] = 0);
end;

{ Recompute bucket boundaries from a saved symbol count. }
procedure BucketsFromCounts(const Cnt, Bkt: PInt32; K: Int32; EndPos: Boolean);
var
  i, Sum: Int32;
begin
  Sum := 0;
  for i := 0 to K - 1 do
  begin
    Sum := Sum + Cnt[i];
    if EndPos then
      Bkt[i] := Sum
    else
      Bkt[i] := Sum - Cnt[i];
  end;
end;

procedure CountBucketsInt(const S: PInt32; Cnt: PInt32; N, K: Int32);
var
  i: Int32;
begin
  for i := 0 to K - 1 do
    Cnt[i] := 0;
  for i := 0 to N - 1 do
    Inc(Cnt[S[i]]);
end;

procedure CountBucketsByte(const T: PByte; Cnt: PInt32; N: Int32);
var
  i: Int32;
begin
  for i := 0 to BYTE_ALPHABET - 1 do
    Cnt[i] := 0;
  Inc(Cnt[0]);                       { the sentinel }
  for i := 0 to N - 1 do
    Inc(Cnt[T[i] + 1]);
end;

{ ---------------------------------------------------------------------------
  Int32 core, used for the reduced problems of the recursion. S[N-1] is the
  unique smallest symbol (0), as the algorithm requires.
  --------------------------------------------------------------------------- }

procedure SaisRec(const S: PInt32; SA: PInt32; N, K: Int32);
var
  Typ: PByte;
  Cnt, Bkt: PInt32;
  n1, i, j, Name, Prev, Pos, d, c: Int32;
  Diff: Boolean;
  SA1, s1: PInt32;
begin
  if N = 1 then
  begin
    SA[0] := 0;
    Exit;
  end;

  GetMem(Typ, N);
  GetMem(Cnt, K * SizeOf(Int32));
  GetMem(Bkt, K * SizeOf(Int32));
  try
    Typ[N - 1] := 1;
    Typ[N - 2] := 0;
    for i := N - 3 downto 0 do
      if (S[i] < S[i + 1]) or ((S[i] = S[i + 1]) and (Typ[i + 1] <> 0)) then
        Typ[i] := 1
      else
        Typ[i] := 0;

    CountBucketsInt(S, Cnt, N, K);

    for i := 0 to N - 1 do
      SA[i] := -1;
    BucketsFromCounts(Cnt, Bkt, K, True);
    for i := 1 to N - 1 do
      if IsLMS(Typ, i, N - 1) then
      begin
        Dec(Bkt[S[i]]);
        SA[Bkt[S[i]]] := i;
      end;

    { induce L }
    BucketsFromCounts(Cnt, Bkt, K, False);
    for i := 0 to N - 1 do
    begin
      c := SA[i];
      if (c > 0) and (Typ[c - 1] = 0) then
      begin
        j := S[c - 1];
        SA[Bkt[j]] := c - 1;
        Inc(Bkt[j]);
      end;
    end;
    { induce S }
    BucketsFromCounts(Cnt, Bkt, K, True);
    for i := N - 1 downto 0 do
    begin
      c := SA[i];
      if (c > 0) and (Typ[c - 1] <> 0) then
      begin
        j := S[c - 1];
        Dec(Bkt[j]);
        SA[Bkt[j]] := c - 1;
      end;
    end;

    n1 := 0;
    for i := 0 to N - 1 do
      if IsLMS(Typ, SA[i], N - 1) then
      begin
        SA[n1] := SA[i];
        Inc(n1);
      end;

    for i := n1 to N - 1 do
      SA[i] := -1;
    Name := 0;
    Prev := -1;
    for i := 0 to n1 - 1 do
    begin
      Pos := SA[i];
      Diff := False;
      if Prev < 0 then
        Diff := True
      else
      begin
        d := 0;
        while d < N do
        begin
          if (S[Pos + d] <> S[Prev + d]) or (Typ[Pos + d] <> Typ[Prev + d]) then
          begin
            Diff := True;
            Break;
          end
          else if (d > 0) and (IsLMS(Typ, Pos + d, N - 1) or IsLMS(Typ, Prev + d, N - 1)) then
            Break;
          Inc(d);
        end;
      end;
      if Diff then
      begin
        Inc(Name);
        Prev := Pos;
      end;
      SA[n1 + (Pos shr 1)] := Name - 1;
    end;

    j := N - 1;
    for i := N - 1 downto n1 do
      if SA[i] >= 0 then
      begin
        SA[j] := SA[i];
        Dec(j);
      end;

    SA1 := SA;
    s1 := @SA[N - n1];
    if Name < n1 then
      SaisRec(s1, SA1, n1, Name)
    else
      for i := 0 to n1 - 1 do
        SA1[s1[i]] := i;

    BucketsFromCounts(Cnt, Bkt, K, True);
    j := 0;
    for i := 1 to N - 1 do
      if IsLMS(Typ, i, N - 1) then
      begin
        s1[j] := i;
        Inc(j);
      end;
    for i := 0 to n1 - 1 do
      SA1[i] := s1[SA1[i]];
    for i := n1 to N - 1 do
      SA[i] := -1;
    for i := n1 - 1 downto 0 do
    begin
      j := SA[i];
      SA[i] := -1;
      Dec(Bkt[S[j]]);
      SA[Bkt[S[j]]] := j;
    end;

    BucketsFromCounts(Cnt, Bkt, K, False);
    for i := 0 to N - 1 do
    begin
      c := SA[i];
      if (c > 0) and (Typ[c - 1] = 0) then
      begin
        j := S[c - 1];
        SA[Bkt[j]] := c - 1;
        Inc(Bkt[j]);
      end;
    end;
    BucketsFromCounts(Cnt, Bkt, K, True);
    for i := N - 1 downto 0 do
    begin
      c := SA[i];
      if (c > 0) and (Typ[c - 1] <> 0) then
      begin
        j := S[c - 1];
        Dec(Bkt[j]);
        SA[Bkt[j]] := c - 1;
      end;
    end;
  finally
    FreeMem(Bkt);
    FreeMem(Cnt);
    FreeMem(Typ);
  end;
end;

{ ---------------------------------------------------------------------------
  Byte-level top level. L data bytes, one virtual sentinel at position L.
  --------------------------------------------------------------------------- }

procedure SaisTopByte(const T: PByte; L: Int32; SA: PInt32);
var
  Typ: PByte;
  Cnt, Bkt: PInt32;
  M, n1, i, j, Name, Prev, Pos, d, c: Int32;
  Diff: Boolean;
  SA1, s1: PInt32;
begin
  M := L + 1;                        { positions 0..L, sentinel at L }

  GetMem(Typ, M);
  GetMem(Cnt, BYTE_ALPHABET * SizeOf(Int32));
  GetMem(Bkt, BYTE_ALPHABET * SizeOf(Int32));
  try
    Typ[M - 1] := 1;
    Typ[M - 2] := 0;
    for i := M - 3 downto 0 do
      if (T[i] < T[i + 1]) or ((T[i] = T[i + 1]) and (Typ[i + 1] <> 0)) then
        Typ[i] := 1
      else
        Typ[i] := 0;

    CountBucketsByte(T, Cnt, L);

    for i := 0 to M - 1 do
      SA[i] := -1;
    BucketsFromCounts(Cnt, Bkt, BYTE_ALPHABET, True);
    for i := 1 to M - 1 do
      if IsLMS(Typ, i, L) then
        if i = L then
        begin
          Dec(Bkt[0]);
          SA[Bkt[0]] := L;
        end
        else
        begin
          Dec(Bkt[T[i] + 1]);
          SA[Bkt[T[i] + 1]] := i;
        end;

    { induce L }
    BucketsFromCounts(Cnt, Bkt, BYTE_ALPHABET, False);
    for i := 0 to M - 1 do
    begin
      c := SA[i];
      if (c > 0) and (Typ[c - 1] = 0) then
      begin
        j := T[c - 1] + 1;
        SA[Bkt[j]] := c - 1;
        Inc(Bkt[j]);
      end;
    end;
    { induce S }
    BucketsFromCounts(Cnt, Bkt, BYTE_ALPHABET, True);
    for i := M - 1 downto 0 do
    begin
      c := SA[i];
      if (c > 0) and (Typ[c - 1] <> 0) then
      begin
        j := T[c - 1] + 1;
        Dec(Bkt[j]);
        SA[Bkt[j]] := c - 1;
      end;
    end;

    n1 := 0;
    for i := 0 to M - 1 do
      if IsLMS(Typ, SA[i], L) then
      begin
        SA[n1] := SA[i];
        Inc(n1);
      end;

    for i := n1 to M - 1 do
      SA[i] := -1;
    Name := 0;
    Prev := -1;
    for i := 0 to n1 - 1 do
    begin
      Pos := SA[i];
      Diff := False;
      if Prev < 0 then
        Diff := True
      else
      begin
        d := 0;
        while d < M do
        begin
          { the sentinel position is unique and sorts first }
          if (Pos + d = L) or (Prev + d = L) then
          begin
            Diff := True;
            Break;
          end;
          if (T[Pos + d] <> T[Prev + d]) or (Typ[Pos + d] <> Typ[Prev + d]) then
          begin
            Diff := True;
            Break;
          end
          else if (d > 0) and (IsLMS(Typ, Pos + d, L) or IsLMS(Typ, Prev + d, L)) then
            Break;
          Inc(d);
        end;
      end;
      if Diff then
      begin
        Inc(Name);
        Prev := Pos;
      end;
      SA[n1 + (Pos shr 1)] := Name - 1;
    end;

    j := M - 1;
    for i := M - 1 downto n1 do
      if SA[i] >= 0 then
      begin
        SA[j] := SA[i];
        Dec(j);
      end;

    SA1 := SA;
    s1 := @SA[M - n1];
    if Name < n1 then
      SaisRec(s1, SA1, n1, Name)
    else
      for i := 0 to n1 - 1 do
        SA1[s1[i]] := i;

    BucketsFromCounts(Cnt, Bkt, BYTE_ALPHABET, True);
    j := 0;
    for i := 1 to M - 1 do
      if IsLMS(Typ, i, L) then
      begin
        s1[j] := i;
        Inc(j);
      end;
    for i := 0 to n1 - 1 do
      SA1[i] := s1[SA1[i]];
    for i := n1 to M - 1 do
      SA[i] := -1;
    for i := n1 - 1 downto 0 do
    begin
      j := SA[i];
      SA[i] := -1;
      if j = L then
      begin
        Dec(Bkt[0]);
        SA[Bkt[0]] := j;
      end
      else
      begin
        Dec(Bkt[T[j] + 1]);
        SA[Bkt[T[j] + 1]] := j;
      end;
    end;

    { induce once more for the final order }
    BucketsFromCounts(Cnt, Bkt, BYTE_ALPHABET, False);
    for i := 0 to M - 1 do
    begin
      c := SA[i];
      if (c > 0) and (Typ[c - 1] = 0) then
      begin
        j := T[c - 1] + 1;
        SA[Bkt[j]] := c - 1;
        Inc(Bkt[j]);
      end;
    end;
    BucketsFromCounts(Cnt, Bkt, BYTE_ALPHABET, True);
    for i := M - 1 downto 0 do
    begin
      c := SA[i];
      if (c > 0) and (Typ[c - 1] <> 0) then
      begin
        j := T[c - 1] + 1;
        Dec(Bkt[j]);
        SA[Bkt[j]] := c - 1;
      end;
    end;
  finally
    FreeMem(Bkt);
    FreeMem(Cnt);
    FreeMem(Typ);
  end;
end;

procedure SaisBuildSAPascal(const T: PByte; N: SizeInt; SA: PInt32);
begin
  if N <= 0 then
    Exit;
  if N = 1 then
  begin
    SA[0] := 0;
    Exit;
  end;
  SaisTopByte(T, Int32(N), SA);
  { SA[0] is the sentinel (position N); shift the result down. }
  Move(SA[1], SA[0], N * SizeOf(Int32));
end;

procedure SaisBuildSA(const T: PByte; N: SizeInt; SA: PInt32);
begin
  if N <= 0 then
    Exit;
  if N = 1 then
  begin
    SA[0] := 0;
    Exit;
  end;
{$IFDEF TVCT_LIBSAIS}
  if not SaisForcePascal then
    if tvct_libsais(T, SA, Int32(N), 0, nil) >= 0 then
      Exit;
{$ENDIF}
  SaisBuildSAPascal(T, N, SA);
end;

end.
