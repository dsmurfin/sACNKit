# ``sACNKit``

A Swift implementation of ANSI E1.31-2018 (sACN) for transporting DMX512 over IP.

## Overview

sACNKit lets you send and receive streaming ACN (sACN / E1.31) lighting data. It provides a
transmitting ``sACNSource``, receivers for merged (``sACNReceiver``, ``sACNReceiverGroup``) and raw
(``sACNReceiverRaw``) data, a universe-discovery receiver (``sACNDiscoveryReceiver``), and a
standalone HTP / per-address-priority merge engine (``sACNMerger``).

Delegate callbacks are delivered asynchronously on the delegate queue you provide. Because
delivery is asynchronous, `stop()` and `setDelegate(nil)` are not delivery barriers: callbacks
already enqueued may still arrive after either call returns (`setDelegate(nil)` keeps the previous
delegate alive for those in-flight deliveries), and `information(for:)` reflects current state
rather than a callback payload's snapshot. Tear down resources your delegate uses only after
queued callbacks have drained.

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
