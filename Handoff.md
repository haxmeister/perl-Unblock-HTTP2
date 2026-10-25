# ACTIVE H2SPEC CONFORMANCE HANDOFF
Updated: 2026-10-25
Repository: https://github.com/haxmeister/perl-Unblock-HTTP2
Branch: feature/h2spec-conformance
Baseline: 7bc0b6ccd653a74ad1e7399d27aa9d94c941b513 (main, version 0.12)

## Scope and authorization

The user reports 13 h2spec failures and requests autonomous diagnosis and fixes
on a feature branch, with frequent handoff updates. Continue until fixed.
Do not modify main, merge, tag, release, or bump versions. Keep this engine
independent of Linux::Event and the upper Unblock::HTTP library.

## Current checkpoint

- Clean main checkout and remote branches inspected; created feature branch.
- Read previous handoff and architecture/backend requirements.
- Existing CI covers unit tests and nghttp/nghttpd interop, but not h2spec.
- Setting up h2spec 2.6.0 and local dependencies for a standalone reproduction.
- No protocol changes yet. The reported 13 cases have not yet been reproduced.

## Next steps

1. Build the released baseline and run all h2spec suites against a minimal
   standalone IO::Socket server that drains output before closing.
2. Record exact failures and distinguish RFC behavior from harness defects.
3. Add focused regression tests, fix shared engine/native boundary as needed.
4. Run full tests, native/portable paths and h2spec; add permanent CI coverage.
5. Publish feature checkpoints and update this section with commands/results.

The older release notes below are historical. The user reports that 0.12 was
released to GitHub and CPAN; this task is a new conformance repair.

---

# MAIN-BRANCH RELEASE HANDOFF: Unblock::HTTP2 0.12
Updated: 2026-10-21
Repository: https://github.com/haxmeister/perl-Unblock-HTTP2
Current branch: main
Integrated development branch: feature/unified-receive-lifecycle
Fast-forward merge checkpoint: 7a8a59910c9e2d9ad1f5d73d72820ae1f856ce76

## Standalone release-audit checkpoint (2026-10-21)

- Reviewed `Changes`, `Makefile.PL`, `MANIFEST`, `MANIFEST.SKIP`,
  public POD, integration/cookbook documentation, feature scope,
  version test, public NativeABI header, and distribution workflow.
- Reconciled stale 0.11/feature-branch wording in README and
  docs/FEATURE-COMPLETENESS.md with the pending 0.12 release.
- Public package versions are 0.12; NativeABI inherits the parent version
  and is explicitly indexed as 0.12 via Makefile.PL provides.
- The 0.12 source at 7a8a5991 passed full cross-platform CI, distribution
  distcheck/disttest, installed NativeABI external-C compilation, optional
  framework smoke tests, POD checks, and independent nghttp2 interop.
- This checkpoint changes documentation and handoff only, not protocol
  code, Makefile.PL, public native ABI, or test implementation.
- The preceding GitHub release remains v0.11. Do not tag or publish
  v0.12 or upload to CPAN until the maintainer explicitly approves.
- Run/inspect final CI for this documentation commit and confirm the
  release artifact/PAUSE index after the maintainer publishes it.

## Instructions for the next HTTP2-only conversation

The user authorized merging this completed feature to MAIN. The merge
HAS occurred: current source version is already 0.12 throughout the
explicitly indexed packages, and Changes has the pending 0.12 entry.
Previous GitHub version was 0.11. NO 0.12 GitHub tag/release or
PAUSE/CPAN upload has happened. Older entries below saying main cannot
be modified or versions are unchanged are historical, superseded by
this heading. Finish a standalone 0.12 release audit before publishing;
seek user approval for release/tag/upload actions.

## Standalone API and completed work

HTTP2 remains usable independently of upper Unblock::HTTP and any
particular event loop. Its protocol state and multiplexing continue
to be owned by the canonical HTTP2 Connection/Transaction.
The coordinated API changes include:
- Bounded buffered or streamed on_data body delivery, selectable per
  Transaction, with 64 MiB default buffered limit.
- Exactly-once on_finish after complete/error/cancel; invalid,
  truncated, bodyless, oversized and mixed-mode multiplexing cases.
- Public Client/Server request and response streaming, callbacks
  and attached-host acceptance/backpressure behavior. No extra
  transaction or Uniform::HTTP object is materialized.
- SETTINGS_ENABLE_CONNECT_PROTOCOL and Extended CONNECT semantics
  needed by the unified H2 WebSocket client/server, but WebSocket
  framing itself belongs to the optional external WebSocket library,
  not to this low-level engine.
- Stream-local resets, write/on_drain, flow control and ordinary HTTP
  stream isolation must keep working concurrently.
- NativeABI public header/install/discovery preserved without an
  incompatible native ABI layout change.

## Verified CI and critical packaging correction

This main source includes an important release CI correction:
the .github/workflows/test.yml installed-NativeABI smoke test
formerly hard-coded Unblock-HTTP2-0.11.tar.gz and 0.11 extraction
path, so its Linux packaging check failed after the version bump.
Commit 7a8a5991 replaced those with a source-derived distribution
version; it is NOT a protocol runtime regression.

The exact version-bumped, corrected source 7a8a59910c9e2d9ad1f856ce76
passed both FULL standalone workflows:
- Full test/installed NativeABI/distribution matrix:
  https://github.com/haxmeister/perl-Unblock-HTTP2/actions/runs/39699576879
- Independent HTTP/2 interop workflow:
  https://github.com/haxmeister/perl-Unblock-HTTP2/actions/runs/39699576871
Both PASS. Handoff-only update does not change code.

## Next actions in the HTTP2-specific chat

Read MAIN, Changes, Makefile.PL, MANIFEST, docs/INTEGRATION.md and
docs/COOKBOOK.md, current public headers, and the installed-NativeABI
test workflow. Verify full 0.12 distribution tarball disttest,
installed header, package VERSION indexing (including any dynamic
NativeABI version), prereq metadata and POD/synopsis. Confirm both
native nghttp2 and portable paths with the intended dependency
versions. Do not restart the broad architecture/performance discussion.
After a clean release audit, request approval for GitHub release/tag
and CPAN upload, then verify PAUSE indexing. This engine must be
published before upper Unblock::HTTP 0.02, which requires >=0.12.

## Historical engineering notes (older restrictions now superseded)

## Unblock::HTTP2 0.12 feature-branch release candidate (2026-10-21)

The maintainer approved a coordinated family release with bumped versions.
All explicit Unblock::HTTP2 package versions are updated from 0.11
to 0.12 on feature/unified-receive-lifecycle; NativeABI uses the
parent's version. The changelog records the receive/lifecycle and
streaming contract additions used by unified Unblock::HTTP.
Fresh standalone full CI and distribution metadata/indexer checks
must succeed before any merge, GitHub tag/release or CPAN upload.
Main, public native ABI and external dependencies remain untouched.

# Receive body and lifecycle implementation checkpoint

Updated: 2026-10-17
Repository: haxmeister/perl-Unblock-HTTP2
Branch: feature/unified-receive-lifecycle
Status: receive/lifecycle implementation passes full CI; not a release candidate.

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
3. Feature branch is published, tree verified and full CI passed (see below).
4. Coordinate remaining H3/unified verification using the upper handoff.
5. Update upper-layer CI pins to the published engine commits and run live
   Unblock::HTTP integration. Upper Server now maps on_headers to engine
   on_request and application on_request to engine on_request_end.
6. Preserve frequent handoff updates. WebSocket, transaction_class, pause/resume,
   and client pooling are later milestones; no changes to Net::QUIC authorized.


## Verified feature publication

Source commit: 90639bf52394098296be4115e5485606ba6d7f92
Full CI: https://github.com/haxmeister/perl-Unblock-HTTP2/actions/runs/39058704851
PASS on Linux Perl 5.16/latest, macOS latest, Windows Strawberry 5.40.
Distribution/POD checks passed.
Additional interoperability CI: https://github.com/haxmeister/perl-Unblock-HTTP2/actions/runs/39058704842
PASS. Upper CI pins the tested source commit; subsequent handoff-only updates
do not require changing that pin. Main remains unchanged.

The coordinated ordinary Server milestone is verified. H3 full suite
39059118633 and upper live integration 39059172525 passed. Consult
perl-Unblock-HTTP/Handoff.md for the next design milestone.
