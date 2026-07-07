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
5. Downloads and parses the FAA Digital Obstacle File ([SwiftDOF](https://github.com/RISCfuture/SwiftDOF)).
6. Merges the datasets (NASR takes priority over OurAirports) into the shared
   [`NavData`](https://github.com/RISCfuture/NavData) schema.
7. Writes the result as a binary property list, then compresses it with
   [StreamingLZMA](https://github.com/RISCfuture/StreamingLZMA)'s XZ container format —
   byte-compatible with the app's `NSData.decompressed(using: .lzma)`.

## Usage

```console
$ swift run nav-data-generator --cycle current --output ./out
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
