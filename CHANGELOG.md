# Change Log

## [1.3.0] - 2026-09-02

Move to SwiftNASR 4.1.1, which survives the FAA's airport layout effective
2026-09-03. That layout widens the runway record's Pavement Classification field
for the ICAO PCR transition and shifts the trailing filler past the end of the
1532-byte records it describes, which crashed the generator outright — the
scheduled publish for that cycle died with `SIGILL` while parsing airports.

Retry transient download failures. Every FAA and OurAirports download now makes
up to three attempts with exponential backoff, retrying only lost connections,
timeouts, and the server-side and rate-limit statuses that clear on their own. A
cycle is published once every 28 days, and the FAA's hosts flap often enough
that a single 503 previously cost the whole cycle.

Report the full detail of a failure. ArgumentParser prints only an error's
description, which reduced every download problem to "Couldn't download
distribution" and discarded the failure reason naming the actual HTTP response.
Failures now go to standard error with their reason, recovery suggestion, and
underlying case.

## [1.2.0] - 2026-08-18

Move to StreamingLZMA 2.0.0.

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
