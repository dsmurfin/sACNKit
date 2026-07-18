# ``sACNKit``

A Swift implementation of ANSI E1.31-2018 (sACN) for transporting DMX512 over IP.

## Overview

sACNKit lets you send and receive streaming ACN (sACN / E1.31) lighting data. It provides a
transmitting ``sACNSource``, receivers for merged (``sACNReceiver``, ``sACNReceiverGroup``) and raw
(``sACNReceiverRaw``) data, a universe-discovery receiver (``sACNDiscoveryReceiver``), and a
standalone HTP / per-address-priority merge engine (``sACNMerger``).

Every component is a Swift `actor`: the lifecycle and mutation API is `async`, and data and lifecycle
events are reported on `AsyncStream`s rather than a delegate. The source reports on ``sACNSource/events``;
each receiver exposes `data`, `events`, and `debugLog` streams (the merged ``sACNReceiver/data`` and
``sACNReceiverGroup/data`` carry merged frames, ``sACNReceiverRaw/data`` carries per-source frames); the
discovery receiver reports on ``sACNDiscoveryReceiver/discovery`` and ``sACNDiscoveryReceiver/events``.

Each stream property returns an independent subscription, so multiple consumers can observe one component.
A `data` stream buffers the newest frame (a slow consumer gets the latest, not a backlog); `events` is
best-effort drop-oldest, so a consumer that stalls for long enough can miss an event such as `.sourcesLost`.
Consumers run off-actor, so you may call back into a component (for example `information(for:)`) from within
a `for await` loop. `stop()` is not a delivery barrier - elements already yielded may still be observed after
it returns - and `information(for:)` reflects current state rather than a just-delivered frame's snapshot.

- Note: The library is undergoing a phased modernization (SwiftNIO transport and a Swift Concurrency
  API). See `MODERNIZATION.md` in the repository for the roadmap.

## Topics

### Transmitting

- ``sACNSource``
- ``sACNSourceUniverse``

### Receiving

- ``sACNReceiver``
- ``sACNReceiverGroup``
- ``sACNReceiverRaw``

### Discovery

- ``sACNDiscoveryReceiver``

### Merging

- ``sACNMerger``
