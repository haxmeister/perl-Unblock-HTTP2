# Receive body and lifecycle implementation checkpoint

Updated: 2026-10-17
Repository: haxmeister/perl-Unblock-HTTP2
Branch: feature/unified-receive-lifecycle
Status: implementation checkpoint, not release ready.

The maintainer explicitly authorized changes to HTTP1, HTTP2, HTTP3 and
perl-Unblock-HTTP. Do not modify main, merge, or release. The user confirmed publication of these
feature branches and coordinated CI on 2026-10-17. Publication is authorized.
The agreed contract is in perl-Unblock-HTTP/docs/ENGINE-CONTRACTS.md.

## Implemented

- Bounded buffered reception and per-transaction on_data streaming selection.
- Client request options on_data and on_finish; server registration at headers.
- Exactly-once terminal notification after completion/error callbacks; terminal
  observer exceptions are ignored. Cancellation is distinct from an error.
- The same native engine transaction and Uniform message are retained.
- Buffered data is installed before completion/freeze; failed buffers are freed.
- Bodyless messages already frozen at headers carry an empty body string at
  construction. Public native ABI layouts/discovery paths are unchanged.
- Default receive modes remain H1/H2 stream, H3 buffered; buffer cap is 64 MiB.


## Validation

Full local suite passes: 30 files, 525 top-level tests/subtests.
New tests exercise native/portable multiplexing, mixed receive modes, overflow
isolation, empty buffers, same message/transaction identity, and cancellation.
Local build uses the actual system nghttp2 1.59.0 shared library and matching
upstream headers. A scratch Makefile.PL supplied those build flags directly
because Alien::nghttp2 is unavailable. The repository Makefile.PL is unchanged.

No performance or zero-copy improvement is claimed. Version numbers are
unchanged; this is a coordinated development branch, not a CPAN release.

## Resume

1. Check git status/branch and inspect the diff; main must remain unchanged.
2. Local source/POD review and focused tests are complete; inspect the recorded
   validation limits before continuing with CI.
3. Publish these authorized dependency feature branches and verify remote trees.
4. Run full GitHub CI, fix failures, and record exact commit/run IDs here.
5. Update upper-layer CI pins to the published engine commits and run live
   Unblock::HTTP integration. Upper Server now maps on_headers to engine
   on_request and application on_request to engine on_request_end.
6. Preserve frequent handoff updates. WebSocket, transaction_class, pause/resume,
   and client pooling are later milestones; no changes to Net::QUIC authorized.

