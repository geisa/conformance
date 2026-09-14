<!--
Copyright 2025-2026, Contributors to the Grid Edge Interoperability &
Security Alliance (GEISA), a Series of LF Projects, LLC

Licensed under the Apache License, Version 2.0. See LICENSE.
-->

# GEISA Conformance Map

GEISA Conformance Map will connect requirements in the GEISA specification and
schemas to the conformance tests in this repository.

It is intended to show:

- what a selected GEISA version requires for each conformance pillar
- whether a requirement comes from specification text, protobufs, JSON Schemas,
  or profiles
- which current Cukinia tests cover each requirement
- what is missing or only partially covered
- what changed between a release and current development

LEE and API are the initial focus areas. ADM and VEE are intentionally paused
while coverage and reporting on the first two pillars is improved.

## Approach

The tool builds on existing projects where possible rather than writing a full
specification parser from scratch. The current code uses Docutils to parse RST
specification text and GEISA-specific code to resolve local checkout details
and extract requirement candidates.

Planned integrations include:

- Sphinx and Sphinx-Needs for linked requirement and test views where feasible
- `protoc` descriptor sets for protobuf structure
- Buf for protobuf linting and compatibility checks
- `jsonschema` or `check-jsonschema` for JSON Schema validation

Planned GEISA-specific work includes:

- applying reviewed IDs and decisions
- normalizing contract rules
- scanning Cukinia tests
- suggesting and storing approved mappings
- determining applicability by pillar, profile, and capability
- comparing releases with current development
- generating reports and optional future test scaffolding

## Planned workflow

The planned workflow will:

1. Resolve a release, commit, `latest`, or local workspace to an exact source
   state
2. Extract requirement candidates and contract rules derived from schemas and
   protocol definitions
3. Apply the reviewed decisions under `requirements/`
4. Scan the existing Cukinia tests
5. Suggest mappings and identify gaps where possible
6. Generate reports under `build/conformance-map/`

Reviewed release baselines may be committed under `requirements/baselines/`.

## Current workflow

Implemented today:

1. Extract generated requirement candidates from LEE or API RST sources
2. Write generated output under `build/conformance-map/`, which git ignores
3. Preserve source and structural context for review

Planned review and mapping work:

1. Review candidates and split, merge, reject, or classify them
2. Assign stable requirement IDs to reviewed requirements
3. Discover/review existing conformance tests
4. Propose requirement to test mappings
5. Approve mappings through conformance team review
6. Generate coverage, source-change, stale-test, and unmapped-requirement
   reports (maybe)

Note that a keyword or phrase occurrence is not automatically an independently
testable requirement, and generated candidates are not automatically approved
requirements. One test may cover several requirements, and one requirement
may require several tests.  Proposed mappings should not be assumed to
immediately be approved mappings or coverage until they are reviewed.

## RST requirement extraction

`extract-rst` currently supports the LEE and API pillars. It accepts the path
to a local GEISA specification checkout, recursively scans the selected
pillar's RST files, and records checkout details in the generated output:
resolved path, branch, commit, and dirty state.

The example below assumes the conformance and specification repositories are
checked out as peers under the same GEISA workspace. Use `API` instead of
`LEE` to extract API candidates.

```sh
geisa-conformance-map extract-rst \
  --source ../specification \
  --pillar LEE \
  --output build/conformance-map/candidates/lee.yaml
```

The extractor will output generated candidates. Each record has a repeatable
candidate identifier for the generated source block.

The extractor scans the selected pillar top-level source file when present and
every RST file below `source/lee` or `source/api` recursively. It extracts
paragraph and list-item blocks with explicit `MUST`, `MUST NOT`, `SHALL`, or
`SHALL NOT` keywords. Each match records the normalized requirement keyword,
the spelling found in the source, and whether the source used unusual
capitalization. Totals include every match, including multiple requirement
keywords in the same source block.

Generated candidates retain the source path, section, approximate line,
checkout branch, commit, list context, and standard or custom admonition
context. Immediately following child lists and nested child lists are also
retained.

A list immediately following a block with one requirement keyword is now split
into separate individual candidates. Nested list items are included and inherit
the nearest applicable parent keyword.

The tool currently processes RST specification text only. It does not yet
process protobuf definitions or JSON Schemas, and it does not interpret table
structures. Explicit requirement keywords in paragraph-like table cells may be
extracted, but row, column, header, and other table meaning are not
interpreted. Handling of tables are currently planned future work.

## Repository layout

A typical GEISA development layout is:

```text
~/work/GEISA/
├── conformance/
├── specification/
└── schemas/
```

`specification` is currently required by `extract-rst`. `schemas` is not
required by `extract-rst` today, but later protobuf and JSON Schema extraction
will use it. The repositories do not need to be peers when `--source` names a
valid specification local checkout. The examples use peer checkouts as my
preferred 'normal' GEISA development layout.

- `requirements/` contains reviewed project data and release baselines
- `tools/conformance-map/` contains the implementation and committed docs
- `build/conformance-map/` contains generated output and is ignored by Git

## Local setup

Create the local development environment:

```sh
cd ~/work/GEISA/conformance
tools/conformance-map/setup-venv.sh
source tools/conformance-map/.venv/bin/activate
```

## Running the extractor

Make sure you've run setup-venv.sh and activated it as above.  The examples
assume that `conformance` and `specification` are peer checkouts under
`~/work/GEISA/`. Change `--source` as needed for your respective layout if
needed.

```sh
geisa-conformance-map extract-rst \
  --source ../specification \
  --pillar LEE \
  --output build/conformance-map/candidates/lee.yaml

geisa-conformance-map extract-rst \
  --source ../specification \
  --pillar API \
  --output build/conformance-map/candidates/api.yaml

deactivate
```

LEE output is written to `build/conformance-map/candidates/lee.yaml`. API
output is written to `build/conformance-map/candidates/api.yaml`. The current
specification checkout produces ~25+ LEE candidates and 80+ API candidates
against the 0.9.0 specification, but will change as both the tool and the
specification changes.

`build/conformance-map/` is set to be ignored by Git, and generated YAML files
are not intended to be committed.

Inspect the generated output with:

```sh
python - <<'PY'
from pathlib import Path

import yaml

for pillar in ("lee", "api"):
    path = Path(f"build/conformance-map/candidates/{pillar}.yaml")
    data = yaml.safe_load(path.read_text(encoding="utf-8"))

    print(
        pillar.upper(),
        "candidates:",
        data["candidate_count"],
        "keyword matches:",
        data["keyword_occurrence_count"],
        "unusual capitalization:",
        data["noncanonical_keyword_count"],
    )
PY
```

### Generating review reports

Generate HTML review reports after generating the candidate YAML files:

```sh
python tools/conformance-map/scripts/generate-review-report.py \
  build/conformance-map/candidates/lee.yaml \
  build/conformance-map/candidates/lee-review.html

python tools/conformance-map/scripts/generate-review-report.py \
  build/conformance-map/candidates/api.yaml \
  build/conformance-map/candidates/api-review.html
```

These reports are generated for review. Open them in a browser. Source links
open the recorded specification commit and line in a new tab. A report from a
dirty checkout may include local text that differs from the linked commit.
Reports are ignored and should not be committed. The HTML is not an approved
requirements catalog. Review decisions are not stored in these reports. They
will be stored separately. Generated list-item candidates are marked as list
items in the report.

## Planned commands

The final command names may change as the implementation is extended.

```text
geisa-conformance-map inventory --target tag:v0.9.0
geisa-conformance-map compare --baseline tag:v0.9.0 --target latest
geisa-conformance-map report --target latest
geisa-conformance-map scaffold --pillar LEE
```

## Status

Implemented:

- RST extraction for LEE and API
- Recognition of `MUST`, `MUST NOT`, `SHALL`, and `SHALL NOT`
- Paragraph and list-item candidate extraction
- Multiple keyword matches retained in one source block
- Immediately following child lists and nested child lists retained
- Standard and custom admonition context retained
- Source path, section, approximate line, branch, commit, and dirty state
  retained
- Generated `requirement-candidate` records with repeatable candidate IDs

Not yet implemented:

- Protobuf definitions and descriptor-set extraction
- JSON Schema extraction
- Buf compatibility data
- Handling of tables
- Cukinia test discovery
- Requirement-to-test mappings
- Coverage reports
