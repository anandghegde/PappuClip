# Spike N — title

Copy this file to `spike-N-<slug>.md`. A spike report is an M0 exit artefact (implementation plan §3): it has to
let someone who was not there make the same decision from the same evidence.

| | |
|---|---|
| **Question** | Quoted from PRD §12. |
| **Status** | running · answered · answered with a design change |
| **Result files** | `Tests/results/<run id>/…json`, one line per file, with the permission state or setup each describes |
| **Machines** | macOS versions and hardware the runs cover. Say which of macOS 15, 26 and the current beta are missing. |

## Answer

Two or three sentences. What is true, and how sure the evidence makes us.

## What the design assumed, and what we found

| Assumption | Where it comes from | Finding key | Outcome | Evidence |
|---|---|---|---|---|
| | PRD / architecture section | `key` in the result file | confirmed · refuted · inconclusive | the number or observation |

## Measurements

The latency figures that matter, as p50 / p95 / max with the sample count, against the budget they spend from
(PRD §11.1). Paste from `pappu-dev results summarize`.

## What the log cannot know

System prompts that appeared and when, what the operator did, anything that looked wrong on screen.

## Consequences

- **Design changes:** sections of `docs/architecture.md` or the PRD that change, with the change. "None" is an answer.
- **Architecture §19 items this closes:**
- **Budget changes (PRD §11.1):** stages may be redistributed; totals may not rise.
- **Paths disabled rather than weakened:** app and strategy combinations that cannot meet the guarantees.
- **Licence:** did this spike reuse, or show a need to reuse, GPL-3.0 code (PRD §13)?

## Not covered

What this spike did not test, and which spike or milestone will.
