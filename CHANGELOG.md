# Change Log

## [1.1.0] - 2026-07-22

Store official FAA procedure names for approaches and departures. Approaches now
carry their as-charted title from the d-TPP metafile (`ILS RWY 28L`) rather than a
name synthesized from CIFP metadata, and departures — previously unnamed — are
named by bridging CIFP identifiers to NASR `STARDP` computer codes and the chart
title (`SSTIK FIVE (RNAV)`). Roughly 99.8% of approaches and 99.5% of departures
receive an official name; the rest fall back to the prior behavior, so a naming
gap never fails the build. Also fixes `runwayName`, which SwiftCIFP left unset for
airport approaches, by parsing the runway from the CIFP identifier.

Report accurate, monotonic pipeline progress. Phase weights are reweighted from
measured Release-build durations, and every phase now scopes and cancels its
progress poller, so the reported value climbs monotonically from 0 to 100 instead
of oscillating backward.

## [1.0.0] - 2026-07-06

Initial release.

The `nav-data-generator` command-line tool: downloads and merges FAA NASR, OurAirports,
CIFP, and DOF data into the shared `NavData` schema, then writes the result as an
XZ/LZMA-compressed binary property list (`<cycle>.plist.lzma`) for distribution to the
SF50 TOLD app. Ported from the app's in-process nav-data pipeline so it can run
standalone in Linux CI.
