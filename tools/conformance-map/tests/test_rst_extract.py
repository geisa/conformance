# Copyright 2025-2026, Contributors to the Grid Edge Interoperability &
# Security Alliance (GEISA), a Series of LF Projects, LLC
#
# Licensed under the Apache License, Version 2.0. See LICENSE.

"""Tests for RST requirement extraction."""

from pathlib import Path

import yaml

from geisa_conformance_map.cli import main
from geisa_conformance_map.rst_extract import extract_candidates

FIXTURE = Path(__file__).parent / "fixtures" / "specification"


def test_extracts_reviewable_blocks_with_context() -> None:
    """LEE extraction should retain matches, sections, lists, and case."""

    data = extract_candidates(FIXTURE, "LEE")

    assert data["pillar"] == "LEE"
    assert data["candidate_count"] == 18
    assert data["keyword_occurrence_count"] == 12
    assert data["noncanonical_keyword_count"] == 2

    candidates = data["candidates"]

    nonroot_candidate = next(
        candidate
        for candidate in candidates
        if candidate["requirement"]["source_text"]
        == "Applications SHALL not run as root."
    )
    assert nonroot_candidate["type"] == "requirement-candidate"
    assert nonroot_candidate["source"]["document"] == "Application Isolation"
    assert nonroot_candidate["source"]["section"] == "Application Isolation"
    assert nonroot_candidate["requirement"]["matches"][0] == {
        "level": "SHALL NOT",
        "source_keyword": "SHALL not",
        "noncanonical_case": True,
        "start": 13,
        "end": 22,
    }

    grouped_candidate = next(
        candidate
        for candidate in candidates
        if candidate["requirement"]["source_text"]
        == "Platform implementations MUST provide:"
    )
    assert grouped_candidate["children"] == [
        {
            "text": "a shared base image",
            "children": [{"text": "a hardened base image"}],
        },
        {"text": "application image support"},
    ]

    list_item_candidates = [
        candidate
        for candidate in candidates
        if candidate.get("context", {}).get("list_item")
    ]
    assert [
        candidate["requirement"]["source_text"] for candidate in list_item_candidates
    ] == [
        "a shared base image",
        "a hardened base image",
        "application image support",
        "/tmp",
        "a constrained temporary directory",
        "storage",
        "/tmp",
    ]
    for candidate in list_item_candidates[:3]:
        assert (
            candidate["context"]["parent_candidate_id"]
            == grouped_candidate["candidate_id"]
        )
        assert candidate["requirement"]["inherited_level"] == "MUST"
        assert candidate["requirement"]["inherited_source_keyword"] == "MUST"
        assert candidate["candidate_id"] != grouped_candidate["candidate_id"]
        assert candidate["source"]["line_start"]
    assert list_item_candidates[1]["context"]["list_path"] == ["a shared base image"]

    network_candidate = next(
        candidate
        for candidate in candidates
        if candidate["requirement"]["source_text"]
        == "Applications MUST be denied direct network access by default."
    )
    tmp_list_item = next(
        candidate
        for candidate in list_item_candidates
        if candidate["requirement"]["source_text"] == "/tmp"
    )
    assert tmp_list_item["requirement"]["inherited_level"] == "MUST"
    assert tmp_list_item["requirement"]["inherited_source_keyword"] == "MUST"
    assert (
        tmp_list_item["context"]["parent_candidate_id"]
        == network_candidate["candidate_id"]
    )

    nested_list_items = [
        candidate
        for candidate in list_item_candidates
        if candidate["requirement"]["source_text"]
        == "a constrained temporary directory"
    ]
    assert len(nested_list_items) == 1
    nested_list_item = nested_list_items[0]
    assert nested_list_item["context"]["list_path"] == [
        "/tmp",
        "MUST be limited in size as described in the deployment manifest",
    ]

    aggregate_candidate = next(
        candidate
        for candidate in candidates
        if candidate["requirement"]["source_text"]
        == (
            "Platform implementations MUST retain application state and SHALL NOT "
            "discard it before a requested reset."
        )
    )
    assert [
        match["level"] for match in aggregate_candidate["requirement"]["matches"]
    ] == [
        "MUST",
        "SHALL NOT",
    ]
    assert aggregate_candidate["children"] == [
        {"text": "application data"},
        {"text": "runtime state"},
    ]
    assert not any(
        candidate.get("context", {}).get("parent_candidate_id")
        == aggregate_candidate["candidate_id"]
        for candidate in candidates
    )

    nested_keyword_candidates = [
        candidate
        for candidate in candidates
        if candidate["requirement"]["source_text"]
        == "MUST be limited in size as described in the deployment manifest"
    ]
    assert len(nested_keyword_candidates) == 1
    tmp_candidate = nested_keyword_candidates[0]
    assert tmp_candidate["requirement"]["matches"] == [
        {
            "level": "MUST",
            "source_keyword": "MUST",
            "noncanonical_case": False,
            "start": 0,
            "end": 4,
        }
    ]
    assert "inherited_level" not in tmp_candidate["requirement"]
    assert "inherited_source_keyword" not in tmp_candidate["requirement"]
    assert not tmp_candidate.get("context", {}).get("list_item")
    assert (
        nested_list_item["context"]["parent_candidate_id"]
        == tmp_candidate["candidate_id"]
    )
    assert not any(
        candidate.get("context", {}).get("list_item")
        and candidate["source"]["line_start"] == tmp_candidate["source"]["line_start"]
        and candidate["requirement"]["source_text"]
        == tmp_candidate["requirement"]["source_text"]
        for candidate in candidates
    )
    assert tmp_candidate["context"]["list_path"] == ["/tmp"]

    boundary_parent = next(
        candidate
        for candidate in candidates
        if candidate["requirement"]["source_text"] == "Platform SHALL provide:"
    )
    storage_candidate = next(
        candidate
        for candidate in list_item_candidates
        if candidate["source"]["path"] == "source/lee/list-boundary.rst"
        and candidate["requirement"]["source_text"] == "storage"
    )
    assert storage_candidate["requirement"]["inherited_level"] == "SHALL"
    assert (
        storage_candidate["context"]["parent_candidate_id"]
        == boundary_parent["candidate_id"]
    )

    inner_candidates = [
        candidate
        for candidate in candidates
        if candidate["requirement"]["source_text"] == "Temporary storage MUST include:"
    ]
    assert len(inner_candidates) == 1
    inner_candidate = inner_candidates[0]
    assert [match["level"] for match in inner_candidate["requirement"]["matches"]] == [
        "MUST"
    ]
    assert not inner_candidate.get("context", {}).get("list_item")

    boundary_tmp_candidates = [
        candidate
        for candidate in list_item_candidates
        if candidate["source"]["path"] == "source/lee/list-boundary.rst"
        and candidate["requirement"]["source_text"] == "/tmp"
    ]
    assert len(boundary_tmp_candidates) == 1
    boundary_tmp_candidate = boundary_tmp_candidates[0]
    assert boundary_tmp_candidate["requirement"]["inherited_level"] == "MUST"
    assert boundary_tmp_candidate["requirement"]["inherited_source_keyword"] == "MUST"
    assert (
        boundary_tmp_candidate["context"]["parent_candidate_id"]
        == inner_candidate["candidate_id"]
    )
    assert (
        boundary_tmp_candidate["context"]["parent_candidate_id"]
        != boundary_parent["candidate_id"]
    )

    lowercase_candidate = next(
        candidate
        for candidate in candidates
        if "must bring their own" in candidate["requirement"]["source_text"]
    )
    assert lowercase_candidate["requirement"]["matches"][0]["noncanonical_case"] is True

    nested_candidate = next(
        candidate
        for candidate in candidates
        if candidate["source"]["path"] == "source/lee/nested/storage.rst"
    )
    assert nested_candidate["requirement"]["source_text"] == (
        "Persistent storage MUST survive application restarts."
    )

    note_candidate = next(
        candidate
        for candidate in candidates
        if "infer behavior" in candidate["requirement"]["source_text"]
    )
    assert note_candidate["context"]["admonition"] == {
        "type": "note",
        "title": None,
    }

    reserved_candidate = next(
        candidate
        for candidate in candidates
        if "reject operations" in candidate["requirement"]["source_text"]
    )
    assert reserved_candidate["context"]["admonition"] == {
        "type": "admonition",
        "title": "Status: Reserved for Future Definition",
        "classes": ["tbd-section"],
    }


def test_cli_writes_yaml(tmp_path: Path) -> None:
    """The CLI should write generated candidates as YAML."""

    output = tmp_path / "lee.yaml"

    result = main(
        [
            "extract-rst",
            "--source",
            str(FIXTURE),
            "--pillar",
            "LEE",
            "--output",
            str(output),
        ]
    )

    assert result == 0

    data = yaml.safe_load(output.read_text(encoding="utf-8"))

    assert data["candidate_count"] == 18
    assert data["keyword_occurrence_count"] == 12
    assert data["noncanonical_keyword_count"] == 2
