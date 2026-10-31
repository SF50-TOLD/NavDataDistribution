# NavDataDistribution

The `nav-data-generator` command-line tool that builds the [SF50 TOLD](https://apps.apple.com/app/sf50-told/id6470008295)
navigation database for a given AIRAC cycle.

This package ports the app's in-process nav-data pipeline into a standalone Swift
executable so it can run headlessly in Linux CI, publishing per-cycle data files
without requiring an Apple platform build.

## What it does

For a requested NASR cycle, the generator:

1. Initializes a timezone lookup database.
2. Downloads and parses FAA NASR airport/runway/ILS data ([SwiftNASR](https://github.com/RISCfuture/SwiftNASR)).
3. Downloads and parses [OurAirports](https://ourairports.com) CSV data for international
   airports ([StreamingCSV](https://github.com/RISCfuture/StreamingCSV)).
4. Downloads and parses FAA CIFP procedure data ([SwiftCIFP](https://github.com/RISCfuture/SwiftCIFP)).
5. Downloads and parses the FAA d-TPP metafile for official procedure names,
   joining it with NASR `STARDP` records so approaches and departures carry
   their published chart titles.
6. Downloads and parses the FAA Digital Obstacle File ([SwiftDOF](https://github.com/RISCfuture/SwiftDOF)).
7. Downloads and parses the supplementary sources for the AIRAC cycle
   ([SwiftAIXM](https://github.com/RISCfuture/SwiftAIXM)): [open flightmaps](https://www.openflightmaps.org)
   aerodromes for Europe and southern Africa, the UK AIP and obstacle data sets
   published by NATS, LFV's threshold points and obstacles for Sweden, and the
   Austro Control and Swiss FOCA obstacle data sets. Each is optional; one that
   fails to load is logged and left out.
8. Resolves every source's records into one record per airport. Records are
   matched by ICAO indicator, national code, or position and shared runway; each
   airport is keyed by its most authoritative identifier (`FAA:<site number>`,
   `ICAO:<indicator>`, `LOC:<country>:<code>`, `OA:<OurAirports id>`, or
   `OFM:<region>:<code>`), with its other identifiers as aliases; and each value
   comes from the highest-priority source that has it (NASR, then national AIP
   data, then open flightmaps, then OurAirports).
9. Writes the result into the shared [`NavData`](https://github.com/SF50-TOLD/NavData)
   schema as a binary property list, then compresses it with
   [StreamingLZMA](https://github.com/RISCfuture/StreamingLZMA)'s XZ container format —
   byte-compatible with the app's `NSData.decompressed(using: .lzma)`.

Why the European official sources stop at these, and what using the others would
take, is in [docs/data-permissions.md](docs/data-permissions.md).

## Usage

```console
swift run nav-data-generator --cycle current --output ./out
```

### Options

| Option          | Description                                                          | Default           |
|-----------------|-----------------------------------------------------------------------|--------------------|
| `--cycle`       | `current`, `next`, or a specific date (`YYYY-MM-DD`)                   | `current`          |
| `--output`      | Directory to write `<cycle>.plist` and `<cycle>.plist.lzma` to         | current directory  |
| `--print-cycle` | Print the resolved cycle identifier and exit, without running the pipeline | (off)          |

`--print-cycle` is intended for CI, so a workflow can cheaply compute the target cycle
identifier before deciding whether to run the (expensive) full pipeline.

## Distribution

This package only builds the generator tool. The compressed data files it produces are
published as GitHub Release assets by CI, not committed here.
