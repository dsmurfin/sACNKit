# sACN / E1.31 protocol & wire-format facts

Reference for working on packet construction, parsing, and addressing. Values below are the
constants the code actually uses (with source locations); the per-layer `Offset` enums are the
**authoritative** source of truth for byte layout, so consult them rather than hardcoding offsets elsewhere.

## Network / addressing
- **UDP port: `5568`** for all sACN traffic (`Shared/Definitions/NetworkDefinitions.swift`, `SDT.sdtPort`).
- **IPv4 multicast:** `239.255.<universe/256>.<universe%256>` (prefix `239.255.`).
  Universe discovery: **`239.255.250.214`**.
- **IPv6 multicast:** `ff18::83:00:<hiHex>:<loHex>` (prefix `ff18::83:00:`).
  Universe discovery: **`ff18::83:00:fa:d6`**.
- Dual-stack is driven by `sACNIPMode` (`ipv4Only` / `ipv6Only` / `ipv4And6`); IPv6 modes require an
  explicit interface (enforced by `precondition` in the component initializers).

## Numeric ranges & constants
- **Data universes: `1...63999`** (`UInt16.validUniverses`, max in `Source/SourceUniverse.swift`).
- **Universe discovery universe number: `64214`** (`Shared/Universe/Universe.swift`); note this equals
  `239.255.250.214` (250 * 256 + 214).
- **DMX slots per universe: `512`** (`Shared/DMX/DMX.swift`, `DMX.addressCount`).
- **Start codes:** NULL (levels) = `0x00`; **Per-Address Priority (PAP)** = `0xDD` (`DMX.STARTCode`).
- **Priority: `0...200`, default `100`** (`Shared/Universe/Priority.swift`). 201-255 are reserved;
  priority `0` means "not sourcing this slot".

## Packet structure (layered)
Layers live in `Layers/` as value types, each with `static createAsData(...)` (build) and
`static parse(fromData:) throws` (peel), plus a typed `...ValidationError`. Parsing peels each layer and
passes the inner `data` down. **Byte offsets are centralized in each layer's `Offset: Int` enum**, and
that enum is the source of truth. Example (`Layers/RootLayer.swift`, header = 38 bytes):
`preamble 0`, `postAmble 2`, `acnPacketIdentifier 4`, `flagsAndLength 16`, `vector 18`, `cid 22`, `data 38`.

- A full E1.31 **data packet is 638 bytes** (622 counted from octet 16, plus 16). Preamble `0x0010`,
  postamble `0x0000`, ACN packet identifier `ASC-E1.17\0\0\0`.
- Root vectors: `0x04` = data (`DataFraming` + `DMP`), `0x08` = extended (universe discovery).
- **Everything on the wire is big-endian.** Flags+length packing is in
  `Shared/Definitions/FlagsAndLength.swift` and `Data+Extensions.toFlagsAndLength`.

## Hot-path rule: in-place `Data` replacers
Transmit packets are pre-composed to `Data` once and then **mutated in place** at fixed offsets rather
than rebuilt every frame. Each `SourceUniverse` stores two full **pre-composed 638-byte packets**
(`levelsPacket`, `prioritiesPacket` = root + framing + DMP); `Source/SourceUniverse.swift` mutates them
in place via composed-packet writers (`replacingComposed{Sequence,Options,Priority,DMPValues,DMPValue,
Framing}`) whose absolute offset is the root-layer length plus the layer-relative `Offset` (so the layer
`Offset` enums stay the single source of truth). At emit, `buildDataMessages()` stamps sequence/options
into the stored packet and hands it over (a COW-shared `Data`) - **no per-frame concatenation**. The
transport (`NIOComponentSocket.send`) copies once into a `ByteBuffer` at the socket edge; NIO
`ByteBuffer` never enters the codec.

The standalone layer-relative replacers (`replacingSequence`/`replacingOptions`/`replacingPriority`/
`replacingDMPLayerValues` in `Layers/*` + `Shared/Data+Extensions.swift`) remain for building standalone
layers (e.g. test fixtures); **never** call them on a composed packet - their offsets are layer-relative
and would corrupt it. Preserve this pattern; rebuilding 638-byte packets at frame rate times N universes
is the thing it deliberately avoids.

> Behavioral timing (frame rate, keep-alive, source-loss, sampling, PAP wait) lives in
> `.claude/rules/timing.md`. Threading/queue contracts live in `.claude/rules/threading.md`.
