{
  tvct.sais.pas - suffix array construction (SA-IS).

  Linear-time suffix array by Nong, Zhang and Chan, "Two Efficient Algorithms
  for Linear Time Suffix Array Construction" (2009), with the compact
  single-buffer variant from the paper's reference code.

  The implementation is written from the published algorithm. It is not derived
  from libsais, divsufsort or any other implementation.

  Bytes are mapped to 1..256 and a 0 sentinel is appended, so the alphabet is 257
  symbols and the sentinel is unique and smallest, as the algorithm requires.
  For one 16 MB block that costs a 64 MB work array; the byte-level variant that
  avoids it is a later optimisation.
}
unit tvct.sais;

{$mode objfpc}{$H+}
{$POINTERMATH ON}
{$R-}{$Q-}

interface

{ Builds the suffix array of T[0..N-1] into SA[0..N-1]. T must not be nil when
  N > 0; SA must have room for N+1 Int32, because the sentinel needs one extra
  slot before it is dropped. N = 0 writes nothing. }
procedure SaisBuildSA(const T: PByte; N: SizeInt; SA: PInt32);

implementation

type
  PInt32Arr = ^Int32;

const
  SENTINEL_ALPHABET = 257;   { bytes 1..256 plus the 0 sentinel }

function IsLMS(const t: PByte; i: Int32): Boolean; inline;
begin
  Result := (i > 0) and (t[i] <> 0) and (t[i - 1] = 0);
end;

procedure GetBuckets(const S: PInt32; Bkt: PInt32; N, K: Int32; EndPos: Boolean);
var
  i, Sum: Int32;
begin
  for i := 0 to K - 1 do
    Bkt[i] := 0;
  for i := 0 to N - 1 do
    Inc(Bkt[S[i]]);
  Sum := 0;
  for i := 0 to K - 1 do
  begin
    Sum := Sum + Bkt[i];
    if EndPos then
      Bkt[i] := Sum
    else
      Bkt[i] := Sum - Bkt[i];
  end;
end;

procedure InduceSAl(const t: PByte; SA, S, Bkt: PInt32; N, K: Int32);
var
  i, c, j: Int32;
begin
  GetBuckets(S, Bkt, N, K, False);
  for i := 0 to N - 1 do
  begin
    c := SA[i];
    if (c > 0) and (t[c - 1] = 0) then
    begin
      j := S[c - 1];
      SA[Bkt[j]] := c - 1;
      Inc(Bkt[j]);
    end;
  end;
end;

procedure InduceSAs(const t: PByte; SA, S, Bkt: PInt32; N, K: Int32);
var
  i, c, j: Int32;
begin
  GetBuckets(S, Bkt, N, K, True);
  for i := N - 1 downto 0 do
  begin
    c := SA[i];
    if (c > 0) and (t[c - 1] <> 0) then
    begin
      j := S[c - 1];
      Dec(Bkt[j]);
      SA[Bkt[j]] := c - 1;
    end;
  end;
end;

procedure SaisRec(const S: PInt32; SA: PInt32; N, K: Int32);
var
  t: PByte;
  Bkt: PInt32;
  n1, i, j, Name, Prev, Pos, d: Int32;
  Diff: Boolean;
  SA1, s1: PInt32;
begin
  if N = 1 then
  begin
    SA[0] := 0;
    Exit;
  end;

  GetMem(t, N);
  GetMem(Bkt, K * SizeOf(Int32));
  try
    { 1. Classify L/S. The last character is the sentinel: S-type. }
    t[N - 1] := 1;
    t[N - 2] := 0;
    for i := N - 3 downto 0 do
      if (S[i] < S[i + 1]) or ((S[i] = S[i + 1]) and (t[i + 1] <> 0)) then
        t[i] := 1
      else
        t[i] := 0;

    { 2. Place LMS suffixes at the end of their buckets and induce. }
    for i := 0 to N - 1 do
      SA[i] := -1;
    GetBuckets(S, Bkt, N, K, True);
    for i := 1 to N - 1 do
      if IsLMS(t, i) then
      begin
        Dec(Bkt[S[i]]);
        SA[Bkt[S[i]]] := i;
      end;
    InduceSAl(t, SA, S, Bkt, N, K);
    InduceSAs(t, SA, S, Bkt, N, K);

    { 3. Compact the sorted LMS suffixes into the head of SA. }
    n1 := 0;
    for i := 0 to N - 1 do
      if IsLMS(t, SA[i]) then
      begin
        SA[n1] := SA[i];
        Inc(n1);
      end;

    { 4. Name the sorted LMS substrings. }
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
          if (S[Pos + d] <> S[Prev + d]) or (t[Pos + d] <> t[Prev + d]) then
          begin
            Diff := True;
            Break;
          end
          else if (d > 0) and (IsLMS(t, Pos + d) or IsLMS(t, Prev + d)) then
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

    { 5. Compact the names to the tail of SA: that is s1. }
    j := N - 1;
    for i := N - 1 downto n1 do
      if SA[i] >= 0 then
      begin
        SA[j] := SA[i];
        Dec(j);
      end;

    { 6. Recurse on the reduced string, or sort directly if names are unique. }
    SA1 := SA;
    s1 := @SA[N - n1];
    if Name < n1 then
      SaisRec(s1, SA1, n1, Name)
    else
      for i := 0 to n1 - 1 do
        SA1[s1[i]] := i;

    { 7. Induce the final suffix array from the sorted LMS suffixes. }
    GetBuckets(S, Bkt, N, K, True);
    j := 0;
    for i := 1 to N - 1 do
      if IsLMS(t, i) then
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
    InduceSAl(t, SA, S, Bkt, N, K);
    InduceSAs(t, SA, S, Bkt, N, K);
  finally
    FreeMem(Bkt);
    FreeMem(t);
  end;
end;

procedure SaisBuildSA(const T: PByte; N: SizeInt; SA: PInt32);
var
  S: PInt32;
  i: SizeInt;
begin
  if N <= 0 then
    Exit;
  if N = 1 then
  begin
    SA[0] := 0;
    Exit;
  end;

  GetMem(S, (N + 1) * SizeOf(Int32));
  try
    for i := 0 to N - 1 do
      S[i] := Int32(T[i]) + 1;
    S[N] := 0;
    SaisRec(S, SA, Int32(N + 1), SENTINEL_ALPHABET);
    { Drop the sentinel, which is always the first suffix. }
    for i := 0 to N - 1 do
      SA[i] := SA[i + 1];
  finally
    FreeMem(S);
  end;
end;

end.
