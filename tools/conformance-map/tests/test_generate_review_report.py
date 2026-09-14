# Copyright 2025-2026, Contributors to the Grid Edge Interoperability &
# Security Alliance (GEISA), a Series of LF Projects, LLC
#
# Licensed under the Apache License, Version 2.0. See LICENSE.

"""Tests for generated HTML requirement-candidate review reports."""

import subprocess
import sys
from pathlib import Path

import yaml

from geisa_conformance_map.rst_extract import extract_candidates, write_candidates

FIXTURE = Path(__file__).parent / "fixtures" / "specification"
SCRIPT = Path(__file__).parents[1] / "scripts" / "generate-review-report.py"


def run_generator(
    input_path: Path, output_path: Path
) -> subprocess.CompletedProcess[str]:
    """Run the report generator with the current Python interpreter."""

    return subprocess.run(
        [sys.executable, str(SCRIPT), str(input_path), str(output_path)],
        check=False,
        capture_output=True,
        text=True,
    )


def test_generates_lee_report_with_cards_and_context(tmp_path: Path) -> None:
    """The LEE fixture should produce metadata, cards, and source details."""

    input_path = tmp_path / "lee.yaml"
    output_path = tmp_path / "lee-review.html"
    write_candidates(extract_candidates(FIXTURE, "LEE"), input_path)

    result = run_generator(input_path, output_path)

    assert result.returncode == 0
    report = output_path.read_text(encoding="utf-8")
    assert "# LEE Requirement Candidate Review" not in report
    assert "<h1>LEE Requirement Candidate Review</h1>" in report
    assert "Candidate count</dt><dd><strong>18</strong>" in report
    assert report.count('class="candidate"') == 18
    assert '<div class="requirement-text">' in report
    assert "<table" not in report
    assert "Child items" in report
    assert "Admonition" in report
    assert "Unusual capitalization in source keyword" in report
    assert '<span class="list-item-badge">List item</span>' in report
    assert "MUST (from parent)" in report
    assert "Parent candidate" in report
    assert "List path</dt><dd>a shared base image" in report
    assert report.index("Requirement keyword match count") < report.index(
        "Candidate count"
    )
    assert report.index('class="match-count"') < report.index('class="control-row"')
    assert '<strong id="match-count"></strong><span id="level-summary"' in report
    assert ".control-row + .control-row { margin-top: 1rem; }" in report
    assert "<label><strong>Search</strong>" in report
    assert "<label><strong>Requirement</strong>" in report
    assert "<label><strong>Source file</strong>" in report
    assert "<strong>Section:</strong>" in report
    assert '<p class="source"><strong>Source:</strong>' in report
    assert 'class="source-location"' in report
    assert report.index("Has list items") < report.index("Unusual capitalization")
    assert report.index("Unusual capitalization") < report.index("In notes/admonitions")
    assert report.index("In notes/admonitions") < report.index("Reset filters")
    assert "Has child lists" not in report
    assert "Admonition-backed" not in report


def test_preserves_source_links_and_candidate_references(tmp_path: Path) -> None:
    """Cards should use commit-pinned links and generated candidate IDs."""

    input_path = tmp_path / "source.yaml"
    output_path = tmp_path / "report.html"
    input_path.write_text(
        yaml.safe_dump(
            {
                "source": {
                    "path": "/tmp/specification",
                    "branch": "main",
                    "commit": "abc123",
                    "dirty": True,
                },
                "pillar": "API",
                "candidate_count": 3,
                "keyword_occurrence_count": 6,
                "noncanonical_keyword_count": 1,
                "candidates": [
                    {
                        "candidate_id": "rst:source/api/example.rst:42:c24ccadabf21f957",
                        "source": {
                            "path": "source/api/example.rst",
                            "section": "Example | <Section>",
                            "line_start": 42,
                            "document": "Example",
                        },
                        "requirement": {
                            "source_text": "A MUST | keep\n <safe> SHALL not change.",
                            "matches": [
                                {"level": "MUST", "source_keyword": "MUST"},
                                {"level": "MUST", "source_keyword": "MUST"},
                                {
                                    "level": "SHALL NOT",
                                    "source_keyword": "SHALL not",
                                    "noncanonical_case": True,
                                },
                            ],
                        },
                        "context": {
                            "list_path": ["parent | item"],
                            "admonition": {"type": "note", "title": "Keep <this>"},
                        },
                        "children": [{"text": "child"}],
                    },
                    {
                        "candidate_id": "rst:source/api/example.rst:43:d24ccadabf21f957",
                        "source": {
                            "path": "source/api/example.rst",
                            "section": "Example | <Section>",
                            "line_start": 43,
                            "document": "Example",
                        },
                        "requirement": {
                            "source_text": "a generated child item",
                            "matches": [],
                            "inherited_level": "MUST",
                            "inherited_source_keyword": "MUST",
                        },
                        "context": {
                            "list_item": True,
                            "parent_candidate_id": "rst:source/api/example.rst:42:c24ccadabf21f957",
                        },
                    },
                    {
                        "candidate_id": "rst:source/api/example.rst:44:e24ccadabf21f957",
                        "source": {
                            "path": "source/api/example.rst",
                            "section": "Example | <Section>",
                            "line_start": 44,
                            "document": "Example",
                        },
                        "requirement": {
                            "source_text": "Three MUST clauses apply.",
                            "matches": [
                                {"level": "MUST", "source_keyword": "MUST"},
                                {"level": "MUST", "source_keyword": "MUST"},
                                {"level": "MUST", "source_keyword": "MUST"},
                            ],
                        },
                    },
                ],
            },
            sort_keys=False,
        ),
        encoding="utf-8",
    )

    result = run_generator(input_path, output_path)

    assert result.returncode == 0
    report = output_path.read_text(encoding="utf-8")
    assert "This report contains local source text from a dirty checkout" in report
    assert (
        "https://github.com/geisa/specification/blob/abc123/source/api/example.rst#L42"
        in report
    )
    assert 'target="_blank"' in report
    assert 'rel="noopener noreferrer"' in report
    assert ">Open source</a>" in report
    assert 'id="candidate-c24ccadabf21f957"' in report
    assert (
        'data-candidate-id="rst:source/api/example.rst:42:c24ccadabf21f957"' in report
    )
    assert (
        "Generated candidate ID</dt><dd>rst:source/api/example.rst:42:c24ccadabf21f957"
        in report
    )
    assert "MUST ×1" not in report
    assert "MUST ×2, SHALL NOT" in report
    assert "MUST ×3" in report
    assert "parent | item" in report
    assert "note: Keep &lt;this&gt;" in report
    assert "A MUST | keep &lt;safe&gt; SHALL not change." in report
    assert "Example | &lt;Section&gt;" in report
    assert (
        '<strong>Document:</strong> <span class="section-value">Example</span>'
        in report
    )
    assert (
        "<strong>Section:</strong> "
        '<span class="section-value">Example | &lt;Section&gt;</span>' in report
    )
    assert 'id="candidate-d24ccadabf21f957"' in report
    assert "MUST (from parent)" in report
    assert '<span class="list-item-badge">List item</span>' in report
    assert 'Parent candidate</dt><dd><a href="#candidate-c24ccadabf21f957"' in report
    assert (
        "https://github.com/geisa/specification/blob/abc123/source/api/example.rst#L43"
        in report
    )
    assert 'data-keywords="MUST"' in report
    assert 'data-levels="MUST, SHALL NOT"' in report
    assert report.count('data-levels="MUST"') == 2
    assert "const levelSummary = document.querySelector('#level-summary');" in report
    assert "const levelCounts = new Map();" in report
    assert "card.dataset.levels.split(', ').filter(Boolean)" in report
    assert "levelCounts.set(level, (levelCounts.get(level) || 0) + 1);" in report


def test_reports_missing_and_malformed_input(tmp_path: Path) -> None:
    """Missing and malformed generated YAML should produce clear errors."""

    missing = run_generator(tmp_path / "missing.yaml", tmp_path / "missing.html")
    malformed_path = tmp_path / "malformed.yaml"
    malformed_path.write_text("candidates:\n- invalid\n", encoding="utf-8")
    malformed = run_generator(malformed_path, tmp_path / "malformed.html")

    assert missing.returncode != 0
    assert "error: input file not found:" in missing.stderr
    assert malformed.returncode != 0
    assert "error: malformed candidate YAML:" in malformed.stderr
