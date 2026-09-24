# Local pgproto3 v2 security patch

This is the upstream `github.com/jackc/pgproto3/v2` v2.3.3 source from
commit `945c2126f6db8f3bea7eeebe307c01fe92bca007`. The GitHub tag archive
was downloaded from `https://api.github.com/repos/jackc/pgproto3/tarball/v2.3.3`;
its SHA-256 was
`42336178f61d1ac673095ea7e87126e74e6172dfd9bb0b4036698d599e8e942b`.
The upstream LICENSE is included.

The only production source change is a negative `msgSize` guard in
`data_row.go`. It makes `DataRow.Decode` return an invalid message error for
negative field lengths other than the valid `-1` null sentinel, preventing
the slice bounds panic described in CVE-2026-32286 / GHSA-jqcq-xjh3-6g23.
`data_row_security_test.go` covers the regression and the null sentinel.

The v2 module is end of life and has no patched publisher release. Auth's
`go.mod` uses a local `replace` so the Go compiler builds this patched source.
Remove the replacement only after moving Auth to a maintained driver whose
wire protocol decoder has the equivalent bounds check.
