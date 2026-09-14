#!/usr/bin/env python3
# Copyright 2025-2026, Contributors to the Grid Edge Interoperability &
# Security Alliance (GEISA), a Series of LF Projects, LLC
#
# Licensed under the Apache License, Version 2.0. See LICENSE.

# pylint: disable=invalid-name
"""Generate a standalone HTML review report from candidate YAML."""

from __future__ import annotations

import argparse
import html
import json
from collections import Counter
from pathlib import Path
from typing import Any
from urllib.parse import quote

import yaml


def parse_args() -> argparse.Namespace:
    """Parse generated candidate YAML and HTML output paths."""

    parser = argparse.ArgumentParser(
        description="Generate a standalone HTML review report from candidate YAML",
    )
    parser.add_argument("input", type=Path, help="generated candidate YAML file")
    parser.add_argument("output", type=Path, help="HTML output path")
    return parser.parse_args()


def _compact(value: object) -> str:
    """Collapse whitespace for display and data attributes."""

    return " ".join(str(value).split())


def _escape(value: object) -> str:
    """Escape compact text for safe HTML content or attributes."""

    return html.escape(_compact(value), quote=True)


def _read_input(path: Path) -> dict[str, Any]:
    """Read and validate generated candidate YAML."""

    if not path.is_file():
        raise ValueError(f"input file not found: {path}")

    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise ValueError(f"could not read candidate YAML {path}: {error}") from error

    if not isinstance(data, dict) or not isinstance(data.get("candidates"), list):
        raise ValueError(f"malformed candidate YAML: {path}")
    if not isinstance(data.get("source"), dict) or not data.get("pillar"):
        raise ValueError(f"malformed candidate YAML: {path}")

    for candidate in data["candidates"]:
        if not isinstance(candidate, dict):
            raise ValueError(f"malformed candidate YAML: {path}")
        if not isinstance(candidate.get("source"), dict):
            raise ValueError(f"malformed candidate YAML: {path}")
        if not isinstance(candidate.get("requirement"), dict):
            raise ValueError(f"malformed candidate YAML: {path}")

    return data


def _matches(candidate: dict[str, Any]) -> list[dict[str, Any]]:
    """Return valid keyword matches from a candidate."""

    matches = candidate["requirement"].get("matches", [])
    return matches if isinstance(matches, list) else []


def _filter_levels(candidate: dict[str, Any]) -> list[str]:
    """Return requirement levels used by the filter."""

    inherited_level = candidate["requirement"].get("inherited_level")
    if inherited_level:
        return [_compact(inherited_level)]
    return [_compact(match.get("level", "")) for match in _matches(candidate)]


def _summary_levels(candidate: dict[str, Any]) -> list[str]:
    """Return unique levels for one candidate summary."""

    return list(dict.fromkeys(level for level in _filter_levels(candidate) if level))


def _level_display(candidate: dict[str, Any]) -> str:
    """Return compact requirement-level display text for a candidate."""

    inherited_level = candidate["requirement"].get("inherited_level")
    if inherited_level:
        return f"{_compact(inherited_level)} (from parent)"

    counts = Counter(_filter_levels(candidate))
    return ", ".join(
        level if count == 1 else f"{level} ×{count}" for level, count in counts.items()
    )


def _source_link(source: dict[str, Any], commit: object) -> str | None:
    """Build a GitHub link for the exact recorded source line."""

    path = source.get("path")
    line = source.get("line_start")
    if not commit or not path or not line:
        return None

    quoted_commit = quote(str(commit), safe="")
    quoted_path = quote(str(path), safe="/")
    return (
        "https://github.com/geisa/specification/blob/"
        f"{quoted_commit}/{quoted_path}#L{line}"
    )


def _candidate_hash(candidate: dict[str, Any]) -> str:
    """Return the final generated candidate-ID component for a local anchor."""

    candidate_id = _compact(candidate.get("candidate_id", ""))
    return candidate_id.rsplit(":", maxsplit=1)[-1]


def _metadata(data: dict[str, Any]) -> str:
    """Render report metadata."""

    source = data["source"]
    fields = [
        ("Pillar", data["pillar"]),
        ("Source path", source.get("path")),
        ("Source branch", source.get("branch")),
        ("Source commit", source.get("commit")),
        ("Source checkout dirty", source.get("dirty")),
        ("Requirement keyword match count", data.get("keyword_occurrence_count", 0)),
        ("Unusual-capitalization count", data.get("noncanonical_keyword_count", 0)),
    ]
    items = "".join(
        f"<dt>{_escape(name)}</dt><dd>{_escape(value)}</dd>" for name, value in fields
    )
    items += (
        "<dt>Candidate count</dt>"
        f"<dd><strong>{_escape(data.get('candidate_count', 0))}</strong></dd>"
    )
    warning = ""
    if source.get("dirty"):
        warning = (
            '<p class="warning">This report contains local source text from a dirty '
            "checkout. Source links point to the recorded commit and may not include "
            "local modifications.</p>"
        )
    return f'<section class="metadata"><dl>{items}</dl>{warning}</section>'


def _context(candidate: dict[str, Any]) -> str:
    """Render available context fields for one candidate."""

    context = candidate.get("context", {})
    values: list[str] = []
    list_path = context.get("list_path", [])
    if list_path:
        values.append(f"<dt>List path</dt><dd>{_escape(' > '.join(list_path))}</dd>")

    admonition = context.get("admonition")
    if admonition:
        title = _compact(admonition.get("title") or "")
        description = _compact(admonition.get("type", "admonition"))
        value = f"{description}: {title}" if title else description
        values.append(f"<dt>Admonition</dt><dd>{_escape(value)}</dd>")

    children = candidate.get("children", [])
    if children:
        values.append(f"<dt>Child items</dt><dd>{len(children)}</dd>")

    return f'<dl class="context">{"".join(values)}</dl>' if values else ""


def _source_details(candidate: dict[str, Any]) -> str:
    """Render source details and child-list data."""

    source = candidate["source"]
    children = candidate.get("children", [])
    context = candidate.get("context", {})
    matches = _matches(candidate)
    children_html = ""
    if children:
        serialized = html.escape(json.dumps(children, indent=2), quote=False)
        children_html = f"<dt>Child-list data</dt><dd><pre>{serialized}</pre></dd>"
    parent_html = ""
    parent_candidate_id = context.get("parent_candidate_id")
    if parent_candidate_id:
        parent_hash = _compact(parent_candidate_id).rsplit(":", maxsplit=1)[-1]
        parent_html = (
            "<dt>Parent candidate</dt>"
            f'<dd><a href="#candidate-{_escape(parent_hash)}">'
            f"{_escape(parent_candidate_id)}</a></dd>"
        )
    list_path_html = ""
    list_path = context.get("list_path", [])
    if list_path:
        list_path_html = f"<dt>List path</dt><dd>{_escape(' > '.join(list_path))}</dd>"
    source_keyword_html = ""
    if len(matches) > 1 or any(
        match.get("level") != match.get("source_keyword") for match in matches
    ):
        source_keywords = ", ".join(
            _compact(match.get("source_keyword", "")) for match in matches
        )
        source_keyword_html = (
            f"<dt>Source spelling</dt><dd>{_escape(source_keywords)}</dd>"
        )
    return (
        '<details class="source-details"><summary>Source details</summary><dl>'
        f"<dt>Generated candidate ID</dt><dd>{_escape(candidate.get('candidate_id', ''))}</dd>"
        f"<dt>Document</dt><dd>{_escape(source.get('document', ''))}</dd>"
        f"<dt>Line</dt><dd>{_escape(source.get('line_start', ''))}</dd>"
        f"{parent_html}{list_path_html}{source_keyword_html}{children_html}</dl></details>"
    )


def _document_section(source: dict[str, Any]) -> str:
    """Render available document and section labels."""

    document = _compact(source.get("document", ""))
    section = _compact(source.get("section", ""))
    if document and document != section:
        return (
            '<p class="section"><strong>Document:</strong> '
            f'<span class="section-value">{_escape(document)}</span> '
            f'<strong>Section:</strong> <span class="section-value">{_escape(section)}</span></p>'
        )
    return (
        '<p class="section"><strong>Section:</strong> '
        f'<span class="section-value">{_escape(section or document)}</span></p>'
    )


def _candidate_card(  # pylint: disable=too-many-locals
    candidate: dict[str, Any],
    commit: object,
) -> str:
    """Render one candidate card."""

    source = candidate["source"]
    requirement = candidate["requirement"]
    context = candidate.get("context", {})
    is_list_item = bool(context.get("list_item"))
    matches = _matches(candidate)
    levels = _level_display(candidate)
    filter_levels = ", ".join(_filter_levels(candidate))
    summary_levels = ", ".join(_summary_levels(candidate))
    source_link = _source_link(source, commit)
    link_html = ""
    if source_link:
        link_html = (
            f'<a href="{_escape(source_link)}" target="_blank" '
            'rel="noopener noreferrer">Open source</a>'
        )
    source_label = f"{_compact(source.get('path', ''))}:{source.get('line_start', '')}"
    warning = ""
    if any(match.get("noncanonical_case") for match in matches):
        warning = '<p class="case-warning">Unusual capitalization in source keyword</p>'
    search_text = " ".join(
        [
            _compact(source.get("path", "")),
            _compact(source.get("section", "")),
            _compact(requirement.get("source_text", "")),
        ]
    ).lower()
    candidate_hash = _candidate_hash(candidate)
    list_item_badge = (
        '<span class="list-item-badge">List item</span>' if is_list_item else ""
    )
    return (
        f'<article id="candidate-{_escape(candidate_hash)}" class="candidate" '
        f'data-candidate-id="{_escape(candidate.get("candidate_id", ""))}" '
        f'data-keywords="{_escape(filter_levels)}" '
        f'data-levels="{_escape(summary_levels)}" '
        f'data-source="{_escape(source.get("path", ""))}" '
        f'data-search="{_escape(search_text)}" '
        f'data-unusual="{str(bool(warning)).lower()}" '
        f'data-admonition="{str(bool(context.get("admonition"))).lower()}" '
        f'data-children="{str(bool(candidate.get("children"))).lower()}">'
        f'<header><p class="keywords">{_escape(levels)} {list_item_badge}</p>'
        f"{_document_section(source)}</header>"
        f"<div class=\"requirement-text\">{_escape(requirement.get('source_text', ''))}</div>"
        '<p class="source"><strong>Source:</strong> '
        f'<span class="source-location">{_escape(source_label)}</span> {link_html}</p>'
        f"{warning}{_context(candidate)}{_source_details(candidate)}"
        "</article>"
    )


def _controls(data: dict[str, Any]) -> str:
    """Render search and filter controls from report candidates."""

    candidates = data["candidates"]
    keywords = sorted(
        {level for candidate in candidates for level in _filter_levels(candidate)}
    )
    sources = sorted(
        {_compact(candidate["source"].get("path", "")) for candidate in candidates}
    )
    keyword_options = "".join(
        f'<option value="{_escape(keyword)}">{_escape(keyword)}</option>'
        for keyword in keywords
    )
    source_options = "".join(
        f'<option value="{_escape(source)}">{_escape(source)}</option>'
        for source in sources
    )
    return (
        '<section class="controls"><p class="match-count"><strong '
        'id="match-count"></strong><span id="level-summary" '
        'class="level-summary"></span></p><div class="control-row">'
        '<label><strong>Search</strong> <input id="search" type="search" '
        'placeholder="Source, section, or requirement text"></label>'
        '<label><strong>Requirement</strong> <select id="keyword"><option value="">All</option>'
        f"{keyword_options}</select></label>"
        '<label><strong>Source file</strong> <select id="source"><option value="">All</option>'
        f'{source_options}</select></label></div><div class="control-row secondary-control-row">'
        '<label><input id="children" type="checkbox"> Has list items</label>'
        '<label><input id="unusual" type="checkbox"> Unusual capitalization</label>'
        '<label><input id="admonition" type="checkbox"> In notes/admonitions</label>'
        '<button id="reset" type="button">Reset filters</button></div></section>'
    )


def render_report(data: dict[str, Any]) -> str:
    """Render a self-contained HTML report."""

    source = data["source"]
    cards = "".join(
        _candidate_card(candidate, source.get("commit"))
        for candidate in data["candidates"]
    )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{_escape(data['pillar'])} Requirement Candidate Review</title>
<style>
:root {{ color-scheme: light dark; font-family: system-ui, sans-serif; }}
body {{ background: Canvas; color: CanvasText; margin: 0; }}
main {{ max-width: 70rem; margin: 0 auto; padding: 2rem 1rem 4rem; }}
h1 {{ margin-bottom: .25rem; }}
.metadata, .controls, .candidate {{
  border: 1px solid color-mix(in srgb, CanvasText 22%, Canvas);
  border-radius: .5rem; padding: 1rem; margin: 1rem 0;
}}
.metadata dl, .context {{
  display: grid; grid-template-columns: max-content 1fr;
  gap: .35rem .8rem; margin: 0;
}}
.metadata dt, .context dt, .source-keywords {{
  color: color-mix(in srgb, CanvasText 70%, Canvas);
}}
.metadata dd, .context dd {{ margin: 0; }}
.warning, .case-warning {{ border-left: .3rem solid #b45309; padding-left: .7rem; }}
.controls {{ display: block; }}
.match-count {{ margin: 0 0 .7rem; }}
.level-summary {{ margin-left: .25rem; }}
.control-row {{ display: flex; flex-wrap: wrap; gap: .7rem 1rem; align-items: center; }}
.control-row + .control-row {{ margin-top: 1rem; }}
.controls label {{ display: flex; gap: .35rem; align-items: center; }}
.candidate header {{ display: flex; gap: 1rem; align-items: baseline; flex-wrap: wrap; }}
.keywords {{ font-weight: 700; margin: 0; }}
.list-item-badge {{
  background: color-mix(in srgb, CanvasText 12%, Canvas);
  border-radius: 1rem; font-size: .8rem; font-weight: 500;
  padding: .15rem .45rem; white-space: nowrap;
}}
.section {{ margin: 0; }}
.section-value, .source {{ color: color-mix(in srgb, CanvasText 70%, Canvas); }}
.requirement-text {{
  font-size: 1.1rem; line-height: 1.55;
  white-space: normal; overflow-wrap: anywhere;
}}
.source {{ font-size: .9rem; }}
.source strong {{ color: CanvasText; }}
.source-location {{ font-family: ui-monospace, monospace; }}
.source a {{ margin-left: .5rem; font-family: system-ui, sans-serif; }}
details {{ margin-top: .8rem; }}
pre {{ white-space: pre-wrap; overflow-wrap: anywhere; }}
@media print {{
  .controls {{ display: none; }}
  main {{ max-width: none; padding: 0; }}
  .candidate {{ break-inside: avoid; }}
}}
</style>
</head>
<body><main>
<h1>{_escape(data['pillar'])} Requirement Candidate Review</h1>
{_metadata(data)}
{_controls(data)}
<section id="candidates">{cards}</section>
</main>
<script>
const cards = [...document.querySelectorAll('.candidate')];
const search = document.querySelector('#search');
const keyword = document.querySelector('#keyword');
const source = document.querySelector('#source');
const unusual = document.querySelector('#unusual');
const admonition = document.querySelector('#admonition');
const children = document.querySelector('#children');
const count = document.querySelector('#match-count');
const levelSummary = document.querySelector('#level-summary');
function filterCards() {{
  let matches = 0;
  const levelCounts = new Map();
  for (const card of cards) {{
    const visible = (!search.value || card.dataset.search.includes(search.value.toLowerCase()))
      && (!keyword.value || card.dataset.keywords.split(', ').includes(keyword.value))
      && (!source.value || card.dataset.source === source.value)
      && (!unusual.checked || card.dataset.unusual === 'true')
      && (!admonition.checked || card.dataset.admonition === 'true')
      && (!children.checked || card.dataset.children === 'true');
    card.hidden = !visible;
    matches += visible ? 1 : 0;
    if (visible) {{
      for (const level of card.dataset.levels.split(', ').filter(Boolean)) {{
        levelCounts.set(level, (levelCounts.get(level) || 0) + 1);
      }}
    }}
  }}
  count.textContent = `${{matches}} matching candidate${{matches === 1 ? '' : 's'}}`;
  levelSummary.textContent = [...levelCounts.entries()]
    .map(([level, total]) => ` · ${{level}} ${{total}}`)
    .join('');
}}
for (const control of [search, keyword, source, unusual, admonition, children]) {{
  control.addEventListener('input', filterCards);
  control.addEventListener('change', filterCards);
}}
document.querySelector('#reset').addEventListener('click', () => {{
  search.value = ''; keyword.value = ''; source.value = '';
  unusual.checked = false; admonition.checked = false; children.checked = false;
  filterCards();
}});
filterCards();
</script>
</body>
</html>
"""


def main() -> int:
    """Generate a report from command-line arguments."""

    args = parse_args()
    try:
        data = _read_input(args.input)
    except ValueError as error:
        raise SystemExit(f"error: {error}") from error

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render_report(data), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
