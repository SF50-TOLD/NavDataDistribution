# ``nav_data_generator``

@Metadata {
  @DisplayName("nav-data-generator")
}

Builds the SF50 TOLD navigation database for a given AIRAC cycle.

## Overview

Run the tool with `swift run nav-data-generator --cycle current --output ./out`.
For the requested NASR cycle, the generator downloads and merges FAA NASR,
OurAirports, CIFP, d-TPP, and DOF data using the `NavDataGeneration` library,
then writes the result as a binary property list alongside an XZ/LZMA-compressed
copy for distribution to the app.

Pass `--cycle next` or a specific `YYYY-MM-DD` date to target a cycle other than
the effective one, and `--print-cycle` to print the resolved cycle identifier and
exit without running the pipeline.
