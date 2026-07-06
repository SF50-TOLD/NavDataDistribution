# Change Log

## [1.0.0] - 2026-07-06

Initial release.

The `nav-data-generator` command-line tool: downloads and merges FAA NASR, OurAirports,
CIFP, and DOF data into the shared `NavData` schema, then writes the result as an
XZ/LZMA-compressed binary property list (`<cycle>.plist.lzma`) for distribution to the
SF50 TOLD app. Ported from the app's in-process nav-data pipeline so it can run
standalone in Linux CI.
