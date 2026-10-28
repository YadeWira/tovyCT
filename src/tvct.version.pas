{
  tvct.version.pas - release version, shared by the CLI and the C ABI.

  Bump TVCT_VERSION here and in CHANGELOG.md; both the `tvct --version` output
  and tvct_version() in include/tvct.h read it from this unit.
}
unit tvct.version;

{$mode objfpc}{$H+}
{$IFDEF TVCT_CHECKED}{$R+}{$Q+}{$ELSE}{$R-}{$Q-}{$ENDIF}

interface

const
  TVCT_VERSION = '1.1.0';
  TVCT_VERSION_DETAIL = 'tovyCT ' + TVCT_VERSION + ' (format v4/v5)';

implementation

end.
