# H2SPEC REPAIR COMPLETE: Unblock::HTTP2
Updated: 2026-10-25
Repository: https://github.com/haxmeister/perl-Unblock-HTTP2
Branch: feature/h2spec-conformance
Tested implementation: aca84baf6f55fad7d6f5aaaaa6f0505b2ff3d165
Main/release baseline: 7bc0b6ccd653a74ad1e7399d27aa9d94c941b513 (0.12)
Status: implementation and verification complete; ready for maintainer review.

## Start here in the morning

The reported h2spec failures are fixed on the published feature branch. All
147 strict cases pass in all 16 configurations, with no skips or exceptions.
No merge, version bump, tag or release has occurred. Main remains unchanged.
This handoff-only commit follows the tested implementation named above.

Read this section and docs/H2SPEC.md before continuing. Do not restart the
architecture work or repeat the diagnosis. Check remote refs and working tree
before editing. The next step is maintainer review and, only when explicitly
authorized, merge/release preparation. There are no outstanding repair tasks.

Other repositories were not modified. Linux::Event::HTTP still needs to select
this feature revision for integration validation, or consume a future release;
installing the existing CPAN Unblock::HTTP2 0.12 will not pick up this repair.
Keep engine behavior framework-neutral. The user authorized the feature branch
and autonomous fixes, not modifications to main or a release.

## Verified results for aca84baf

- Strict h2spec matrix: PASS
  https://github.com/haxmeister/perl-Unblock-HTTP2/actions/runs/40169302829
  Two nghttp2 versions: system 1.59.0 and pinned 1.70.0.
  For EACH version: TCP/TLS x response at headers/full request x Perl/NativeABI
  input = 8 configurations. Every configuration: 147 passed / 0 failed /
  0 skipped / 0 errors. Total 2352 successful case executions.
  Complete JUnit reports and fixture logs are retained in workflow artifacts.
- Full cross-platform test/distribution matrix: PASS
  https://github.com/haxmeister/perl-Unblock-HTTP2/actions/runs/40169302709
  Linux Perl 5.16/latest, macOS latest, Windows Strawberry 5.40 all pass.
  Linux packaging includes distcheck/disttest, installed NativeABI external-C
  compilation, optional AnyEvent/IO::Async examples and POD checks.
- Independent nghttp/nghttpd interoperability: PASS
  https://github.com/haxmeister/perl-Unblock-HTTP2/actions/runs/40169302758
- Final local suite: PASS, 31 files / 536 top-level tests/subtests.
- AddressSanitizer + UndefinedBehaviorSanitizer: PASS for reentrant close,
  NativeABI and final conformance regressions, 3 files / 66 top-level tests.
  Invalid memory/UB configured to abort; leak checking disabled for host Perl.
- Regression assertions fail against the unmodified 0.12 baseline, including
  missing STREAM_CLOSED/PROTOCOL_ERROR responses. They check actual wire codes,
  rather than counting an arbitrary socket close as protocol success.

## Diagnosis and completed changes

The earlier same-run diagnostic in Linux::Event::HTTP (40166951263) reported
13 failures in its standalone TLS driver: ten shared protocol failures plus
three driver-only connection-shutdown failures. Exact cases are documented in
docs/H2SPEC.md. Local 1.59.0 reproduction found seven of the shared cases with
both response timings; the other three depend on input/response scheduling.
The entire suite, including all reported cases, now passes in every CI mode.

nghttp2 discards closed stream state with modern priorities enabled and then
conservatively ignores some invalid late frames. Simply rejecting all lower
stream IDs would break valid trailers racing a locally sent RST_STREAM.
The private h2_receive_guard.h now distinguishes peer-closed streams, local
resets and skipped IDs. Both normal input and NativeABI use the same guard.
Legitimate late DATA/trailers after a local reset remain accepted; HPACK state
is preserved for other streams. A subsequent peer reset ends that exception.

The guard also validates legacy PRIORITY fields without disabling negotiated
RFC 9218. nghttp2 1.70.0 escalates stream-window overflow to a connection error;
the guard queries nghttp2's actual send window and instead queues the required
FLOW_CONTROL_ERROR stream reset. Unrelated streams continue normally.

Only frame envelopes and small PRIORITY/WINDOW_UPDATE fields are inspected.
nghttp2 still owns framing, HPACK, active stream validation and flow control.
Body windows stay borrowed, with at most 14 bytes buffered across split input.
Retired/skipped ID ranges coalesce: ordinary sequential traffic needs one range.
More than 1024 distinct ranges causes ENHANCE_YOUR_CALM, bounding pathological
history fragmentation without forgetting facts needed to distinguish resets.
This is not a request-count limit. The resource policy is documented.

The standalone test fixture drains final GOAWAY/output, sends write/TLS
shutdown and briefly drains in-flight input before socket close. This avoids
both leaving the socket open after protocol shutdown and losing final output
to TCP RST when unread data remains. It supports simultaneous h2spec probes.
Unexpected child failures fail CI; PERL_DL_NONLAZY=1 prevents lazy-linker errors
from appearing as successful expected connection closes. An 18-byte response
ensures the negative-window case runs instead of being skipped.

Public API, version 0.12, ABI layout and dependency requirements are unchanged.
Makefile.PL only adds the private header's incremental-build dependency.
MANIFEST includes the private header, new regressions and conformance guide.
Changes contains an Unreleased entry. No production framework adapter added.

## Important regression coverage

- Both input paths, whole buffers and 1/7/13-byte fragments, coalesced frames.
- Closed and reset stream reuse; skipped lower IDs; valid active older streams.
- Local reset races, ignored-trailer HPACK reuse, later peer reset and adjacent
  history ranges; client-side response retirement as well as server requests.
- Legacy vs negotiated modern priorities; stream-window overflow isolation.
- Frame-size and interleaved-header-block error precedence.
- 5000 sequential requests and 1600 out-of-order completions; old retired IDs
  still protected, plus explicit history-bound behavior for fragmented IDs.

## Reproduce and inspect

Normal build with the distribution prerequisites installed:

    perl Makefile.PL
    make test
    H2SPEC_BIN=/path/to/h2spec bash .github/scripts/check-h2spec.sh

The script runs all four TCP combinations. Set UNBLOCK_HTTP2_TLS_CERT and
UNBLOCK_HTTP2_TLS_KEY to include all four TLS combinations. It requires pinned
h2spec 2.6.0 source 70ac2294010887f48b18e2d64f5cccd48421fad1 and validates
147 strict cases with no failures, skips or errors. See .github/workflows/h2spec.yml
for dependency setup and pinned nghttp2 1.70.0 source.

Review the implementation diff against 7bc0b6c. The branch checkpoints include
1f459dd (initial repair), 0f1d68c (matrix, reset-history and Windows allocator
context fix), b01fd800 (system OpenSSL certificate configuration), and aca84baf
(final stream-window isolation and transport shutdown, all CI green).

Local workspace at completion:
/workspace/scratch/7b2883b21cb4/perl-Unblock-HTTP2
Local build used system libnghttp2 1.59.0 plus matching upstream headers and
Uniform::HTTP 0.06. Alien was unavailable, so a scratch-only configuration lives
at ../build-tools/http2-local.PL; it does not change distribution prerequisites.
Local baseline checkout is ../http2-baseline, detached at 7bc0b6c. Logs in /tmp
are disposable; durable results are the CI artifacts and this repository.

An exploratory same-host benchmark before the final WINDOW_UPDATE addition
used five alternating 20,000-request runs per input mode. Median portable
baseline 16156.888/s -> repair 16130.722/s (-0.16%); native 15800.409/s ->
15438.580/s (-2.29%). This small in-memory diagnostic is not a claim about
production network throughput or the final revision's performance.

---

## Historical release handoff (superseded by the completed repair above)

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
