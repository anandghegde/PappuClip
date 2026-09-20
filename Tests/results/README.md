# Harness results

One JSON file per run and machine, written by SpikeLab (M0) and later by the app-matrix runner:

    Tests/results/<run id>/<UTC timestamp>-macOS<version>-<arch>.json

The format is `RunResult` in `Packages/PappuKit/Sources/PappuHarness`. Files are never overwritten, so the
per-release comparison in M6 has history. Print a digest with:

    swift run --package-path Packages/PappuKit pappu-dev results summarize Tests/results/<run id>/*.json

Results are committed. They record the OS, hardware model, signing identity and permission state, and
nothing that identifies a person: no host name, user name or home path. Keep it that way in `notes`.

A run started from a shell describes the *terminal's* permissions, not the app's. Use `Scripts/run-spike.sh`
or the SpikeLab window for anything that is going into a spike report.
