# sACNKit Modernization - Phase 5: ETC Correctness Fixes & Key Features

## Context

Phase 4 is complete: every component is a Swift 6 `actor` on the shared event-loop executor, with an
`async` API and `AsyncStream` output. Phase 5 ports ETC's behavioral/correctness fixes and high-value
features onto that foundation, per the `MODERNIZATION.md` appendix (the source-of-truth inventory) and
validated against the ETC reference implementation (ETCLabs/sACN, https://github.com/ETCLabs/sACN, tag
**v4.0.0.6**; `main` is +2 commits: SACN-403 merger fix `3c0834e`, SACN-404 cosmetic). Each ported item ships with a
regression test; the phase merges only with green CI (macOS + Linux) and no characterization regression.

A recon of both trees (sACNKit + ETC) found that **5 of the 9 inventory items are already correct** in
sACNKit and need only lock-in tests, **4 are genuinely pending**, and the ETC releases/main sweep surfaced
only perf/robustness extras that do not translate cleanly onto the NIO/Swift stack.

## Verified findings driving this phase

**Already correct (regression tests only, no logic change):**
- Source sequence numbering is per-universe and correct: `SourceUniverse.sequence` (`&+=` via
  `incrementSequence()`), stamped/incremented per packet in `sACNSource.buildDataMessages()` (a frame
  emitting NULL + PAP consumes two consecutive sequence numbers on that universe).
- Universe discovery: reserved field written as `0x00000000`
  (`UniverseDiscoveryFramingLayer`), the universe list is sorted ascending (`sACNSource.addUniverse` calls
  `.sort()`), and the detector imposes no 40-universe floor (`sACNDiscoveryReceiver` handles short/partial
  final pages).
- No redundant multicast sends: one send per `(socket, IP family)`; "all interfaces" collapses to a single
  `""` socket.
- Sampling / post-sampling flicker / re-sample-only-new-interfaces / no-exclude-at-init are all handled
  (`socketsSampling`, `beginSamplingPeriod`/`endedSamplingPeriod`, `start()` re-seed, `updateInterfaces`
  `sample = sampleTask == nil`). The inverted `samplingEnded` PAP-transfer was fixed in Phase 2.
- Handle wrapping at `0xFFFF` is **N/A**: sources are keyed by `UUID`/CID, not an integer handle allocator,
  so ETC's handle-wrap bug class does not exist. Sequence-wrap is handled (`&+=` / `Int8(bitPattern:)`).

**Pending (the real work): inventory items 5, 6, 8, 9.**

## Locked decisions (maintainer)

1. **Keep-alive (item 8): match ETC.** Separately configurable NULL and PAP keep-alive intervals,
   defaulting to ETC's **800 ms NULL / 1000 ms PAP** (ETCLabs/sACN `include/sacn/source.h:70,72`).
   This is a deliberate on-wire change (NULL keep-alive drops from ~250 ms to 800 ms; both comply with the
   2500 ms loss timeout).
2. **Scope: core only.** Port the inventory's correctness + features. Defer, as future candidates only, the
   ETC extras the sweep surfaced: the 0x00/0xDD start-code send-spacing perf-opt, SACN-385 configurable
   send-timeout (moot under NIO's non-blocking sends), max-slots>512 (spec is 512), priority-extension-off
   guarding, and redundant/individual init (SACN-368).
3. **Richer merge callbacks (item 9): full exposure.** Per-slot priorities + `perAddressPrioritiesActive` +
   winning `universePriority` on the merged payload, per-source priority via `information(for:)`, and a
   public `perAddressPriorityLost` event.

## Staged PR sequence

### PR1 - Merger characterization + correctness (item 6) [FIRST - foundational]
`Merger/sACNMerger.swift`, `Merger/MergerSource.swift`; new `Tests/sACNKitTests/MergerTests.swift`.
The merger has **no test suite today**, so this PR builds the net *then* fixes.
- Characterization suite: single/multi-source HTP level merge; the incremental HTP tie-break
  (`mergeNewPriority` reading current `winners[slot]` - the classic order-sensitivity spot); **order
  independence** (same inputs, different orders -> identical output; ETC 3.0.0); universe-priority-0 =
  unsourced; PAP vs universe-priority interaction.
- **SACN-403** (remove-PAP-then-add-PAP; ETC `3c0834e`): reproduce - `removePAP` refills `addressPriorities`
  across all 512 slots but leaves `source.perAddressPriorityCount` stale, so a later `updatePAPForSource` with
  a shorter count diffs against that stale count and leaves trailing slots wrong. **Shipped fix** (see the
  delivered note below - it evolved across review): derive the trailing-clear extent at the single diffing
  site in `updatePAPForSource` and lead the change-detection guard with `usingUniversePriority`, which closes
  the whole PAP-revert family (SACN-403, the universe-priority-first sibling, and the identical-resume corner)
  in one place; the `removePAP` count-sync is not needed.
- **SACN-364** (`perAddressPrioritiesActive` correct when PAP == universe priority; ETC `2f4496c`): confirmed
  already-correct via a characterization test (no logic change), as the plan anticipated.

**PR1 delivered note (honest history).** The characterization-first discipline paid off across three review
rounds. (1) The initial SACN-403 fix reset `perAddressPriorityCount` inside `removePAP` - but adversarial review found a
**sibling** of the same bug: `updateUniversePriorityForSource` *also* fills all 512 `addressPriorities` while
the count stays 0, so a *short first PAP* after universe priority left the trailing slots wrongly sourced
(wire-reachable: the receiver applies universe priority from data packets before the 1500 ms PAP wait). The
shipped fix moves to the single **diffing site** in `updatePAPForSource` - deriving the clear-extent as
`source.usingUniversePriority ? DMX.addressCount : previousPerAddressPriorityCount` - which covers both fill
paths at one place, and drops the now-redundant `removePAP` count-sync. (2) The obvious one-line version
(deriving `512` for the change-detection guard too) would have **broken SACN-364** - a first PAP equal to the
universe priority would no longer register as a change; the SACN-364 characterization test caught exactly
that, so the fix keeps the real previous count for change detection and derives 512 only for the clear
extent. (3) A third review round found the remaining corner in the change-detection half: a PAP resuming
after `removePAP` with an **unchanged count and values equal to the universe fill** satisfied neither
disjunct and early-outed, leaving the source on universe priority with trailing slots wrongly sourced. The
guard now leads with `source.usingUniversePriority`, stating the true invariant - **a reverted source treats
any per-address priority as news (its arrival is the transition off universe priority); an active source
deduplicates an identical resend**. All three trailing-slot cases, the revert-state transition, and the
SACN-364 preservation are pinned by probe-verified regression tests (each shown to fail with the fix removed).

### PR2 - Receiver data model: sequence / options / sync universe (item 5; ETC SACN-392 `075de10`)
`Receiver/Delegate/sACNReceiverRawSourceData.swift`, `Layers/DataFramingLayer.swift`,
`Receiver/sACNReceiverRaw.swift`.
- Add `sequence: UInt8`, `options: DataFramingLayer.Options`, `syncUniverse: UInt16` to
  `sACNReceiverRawSourceData`. `sequenceNumber` and `options` are already parsed (`DataFramingLayer:152,156`)
  and in scope at the emit site (`sACNReceiverRaw:691-695`) - populate them.
- `syncUniverse` needs a parser addition: the offset exists (`DataFramingLayer:54` `syncAddress = 71`) but
  `parse()` never reads it - add the read + a `syncAddress` field. (Universe sync is not processed; this only
  surfaces the value, matching ETC.)
- Regression tests: the three fields round-trip from a crafted packet.

### PR3 - Richer merge callbacks + per-source priority (item 9, full; ETC 3.0.0 merge_receiver)
`Receiver/sACNReceiver.swift`, `Receiver/Delegate/sACNReceiverMergedData.swift`,
`Receiver/Delegate/sACNReceiverSource.swift`, `Merger/sACNMerger.swift` (internal getters).
- Extend `sACNReceiverMergedData` with per-slot priorities, `perAddressPrioritiesActive`, and the winning
  `universePriority` - surfacing existing private merger state (`sACNMerger:51,61,66`) via new internal
  getters; populate in `sACNReceiver.notifyMerge()`.
- Extend per-source `sACNReceiverSource` (via `information(for:)`) with priority info
  (`usingUniversePriority`/`universePriority`/`addressPriorities` from `MergerSource:43-53`).
- Add a public **`perAddressPriorityLost`** case to `sACNReceiver.Event` (today PAP-loss is a silent
  re-merge at `sACNReceiver:375-384`; the raw receiver already emits it, merged folds it).
- Regression tests for the new payload fields + the PAP-lost event.

**PR3 delivered note (honest history).** Surfacing `perAddressPrioritiesActive`/`universePriority` on the
merged payload required the receiver's mergers to actually *track* those outputs, so PR3 configures them with
`sACNMergerConfig(transmitPerAddressPriorities: false, universePriority: 0, ...)`. That config change enabled
a **dormant, pre-existing guard bug**: `updateUniversePriorityForSource`'s dedupe compared the merger's
tracked *output* `universePriority` against the source's stored value instead of the *incoming* `priority`.
While the output was untracked (`nil`) the guard was always-true (harmless); once tracked, it silently
**dropped a source's priority decrease** whenever the output equalled that source's stored value (e.g. two
sources at 100, one drops to 80 - the lowered source kept winning at its stale 100). This is a genuine
merge-correctness bug, live for any standalone transmit-configured `sACNMerger` (public API), so it is fixed
here: compare the incoming `priority`. Pinned by a probe-verified regression test (two sources at 100, drop
one to 80, assert the other wins). Pattern: this is the **second** time enabling a dormant config path
surfaced a latent guard (PR1's count-sync family was the first) - the remaining config-touching PR (PR4
keep-alive) gets a probe pass over any newly-reachable branch. Candidate for the ETC cross-check: if
upstream's guard shares this shape, upstream drops priority changes too.

### PR4 - Separately configurable keep-alive intervals, ETC-aligned (item 8)
`Source/sACNSource.swift`, `Source/SourceUniverse.swift`; `.claude/rules/timing.md`.
- Replace the hardcoded cadence (`buildDataMessages` `switch universe.transmitCounter` - NULL at 0/11/22/33
  ~250 ms, PAP at counter 0 ~1 s) with **separately configurable NULL and PAP keep-alive intervals**,
  default **800 ms / 1000 ms**, driven per-universe by elapsed time rather than the shared `transmitCounter
  == 0` coincidence.
- Add the two intervals to `sACNSource` config (init parameters); keep the 3-packet change-burst and
  termination model unchanged. Update `.claude/rules/timing.md`.

### PR5 - Regression lock-in for the already-correct items (1,2,3,4,7)
`Tests/sACNKitTests/*`. Targeted tests pinning: per-universe sequence increment (incl. NULL+PAP in one frame
consuming two sequence numbers); discovery reserved field == 0, ascending list, and short/<40-universe final
pages; a single multicast send per `(socket, family)`; the sampling re-seed / re-sample-new-only
transitions; sequence-wrap at 0xFF. Weave any that sit next to a feature PR's code into that PR; this PR
sweeps up the remainder so every inventory item has a regression test (the phase deliverable).

## Verification
- Per PR: `swift test` green under Swift 6 (macOS); `swift-format lint --strict` clean; no warnings; new
  regression tests pass. Merger + keep-alive PRs additionally `swift test --sanitize=thread` clean.
- Gated: `SACNKIT_NETWORK_TESTS=1 swift test` (loopbacks) green; Linux via `swift:6.2-noble` build+test green.
- Cross-check against ETC where feasible: merger output vs ETC `dmx_merger` for the PAP/HTP/SACN-403/364
  cases; keep-alive cadence and discovery packet (sorted list, reserved field) against the ETC behaviour /
  a Wireshark capture.

## Risks
- **Merger correctness without a prior net:** PR1 writes the characterization suite *before* touching
  `removePAP`, so the SACN-403 fix is proven, not assumed. The order-independence / SACN-364 items may prove
  already-correct (tests only) or reveal a real fix.
- **Keep-alive on-wire change:** dropping NULL keep-alive to 800 ms is deliberate and spec-compliant; the
  interval is configurable so integrators can restore a faster cadence.
- **Public API additions:** items 5 and 9 add public fields/events - fine in the pre-1.0 major window, but
  keep the hot-path merged payload lean (store the per-slot priority array once; do not rebuild per frame).

## Key files
- Merger: `Merger/sACNMerger.swift`, `Merger/MergerSource.swift`, new `Tests/sACNKitTests/MergerTests.swift`.
- Receiver model: `Receiver/Delegate/{sACNReceiverRawSourceData,sACNReceiverMergedData,sACNReceiverSource}.swift`,
  `Layers/DataFramingLayer.swift`, `Receiver/{sACNReceiver,sACNReceiverRaw}.swift`.
- Source: `Source/sACNSource.swift`, `Source/SourceUniverse.swift`.
- Docs: `.claude/rules/timing.md`, `MODERNIZATION.md` (mark Phase 5 items done), this file.
- ETC reference (read-only): ETCLabs/sACN (https://github.com/ETCLabs/sACN) - `src/sacn/dmx_merger.c`,
  `source_state.c`, `receiver_state.c`, `include/sacn/{source,receiver}.h`; fix commits SACN-403 `3c0834e`,
  SACN-364 `2f4496c`, SACN-392 `075de10`.
