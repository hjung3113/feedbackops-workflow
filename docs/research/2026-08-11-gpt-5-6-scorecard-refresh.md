# GPT-5.6 scorecard refresh

Date: 2026-08-11
Scope: primary-source check for the three models in `toolkit/model-alloc.json`.

## Decision

Update the API prices, but do not overwrite the three capability columns with
the new evaluation numbers. The current public primary sources do not provide
a newer LiveBench row that is comparable to the configured
`agentic_coding`, `static_coding`, and `reasoning` values.

OpenAI now publishes exact-ID evaluation results for all three models, but the
named evaluations have different meanings from the existing columns. Treating
them as drop-in replacements would silently change the scorecard contract.

## Recommended changes

| Model | Current input/output per 1M | Current first-party input/output per 1M | Capability change |
| --- | ---: | ---: | --- |
| `gpt-5.6-sol` | $5 / $30 | $5 / $30 | none |
| `gpt-5.6-terra` | $2.50 / $15 | $2 / $12 | keep current values pending a versioned metric migration |
| `gpt-5.6-luna` | $1 / $6 | $0.20 / $1.20 | keep current values pending a versioned metric migration |

The current model pages identify the exact aliases and prices: [Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol),
[Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra), and
[Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna). OpenAI's
July 9 launch page records a July 30 price reduction of 20% for Terra and 80%
for Luna, which explains the change from the release prices currently stored
in the repository. [Launch and price update](https://openai.com/index/gpt-5-6/)

## Available exact-model evaluation snapshot

If the repository later renames and versions its capability fields, OpenAI's
July 9 release provides a complete same-table snapshot for the exact three
models:

| Evaluation | Sol | Terra | Luna |
| --- | ---: | ---: | ---: |
| Artificial Analysis Coding Agent Index v1.1 | 80 | 77.4 | 74.6 |
| SWE-Bench Pro | 64.6% | 63.4% | 62.7% |
| DeepSWE v1.1 | 72.7% | 69.6% | 67.2% |
| Terminal-Bench 2.1 | 88.8% | 87.4% | 84.7% |
| Artificial Analysis Intelligence Index v4.1 | 58.9 | 55 | 51.2 |
| GPQA Diamond | 94.6% | 92.9% | 92.3% |

Source: OpenAI's [GPT-5.6 release tables](https://openai.com/index/gpt-5-6/).
The page explicitly describes the Coding Agent Index as agentic work and says
Sol's reported 80 uses `max` reasoning. It does not establish that these rows
are comparable to the repository's LiveBench-derived fields or its configured
per-role effort levels.

## LiveBench provenance check

The public LiveBench repository documents how results must retain the release,
model, question source, and benchmark group, and exposes category output as
`all_groups.csv`. Its public changelog currently ends at 2026-01-08 and does
not document the repository's configured `2026-06-25` release or these three
exact model IDs. Therefore no public LiveBench primary source found in this
check substantiates changing the existing capability numbers in place.
[LiveBench repository and usage contract](https://github.com/LiveBench/LiveBench)

The smallest honest refresh is therefore:

```text
gpt-5.6-sol:   input 5,   output 30
gpt-5.6-terra: input 2,   output 12
gpt-5.6-luna:  input 0.2, output 1.2
```

Keep the nine capability values unchanged until the schema names the exact
benchmark, version, effort, and source for each observation.
