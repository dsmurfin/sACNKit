# ``sACNKit``

A Swift implementation of ANSI E1.31-2018 (sACN) for transporting DMX512 over IP.

## Overview

sACNKit lets you send and receive streaming ACN (sACN / E1.31) lighting data. It provides a
transmitting ``sACNSource``, receivers for merged (``sACNReceiver``, ``sACNReceiverGroup``) and raw
(``sACNReceiverRaw``) data, a universe-discovery receiver (``sACNDiscoveryReceiver``), and a
standalone HTP / per-address-priority merge engine (``sACNMerger``).

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
