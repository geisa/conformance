# Copyright 2025-2026, Contributors to the Grid Edge Interoperability &
# Security Alliance (GEISA), a Series of LF Projects, LLC
#
# Licensed under the Apache License, Version 2.0. See LICENSE.

"""Extract GEISA requirement candidates from RST source files."""

from __future__ import annotations

import hashlib
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml
from docutils import nodes
from docutils.core import publish_doctree

_REQUIREMENT_PATTERN = re.compile(
    r"\b(MUST NOT|SHALL NOT|MUST|SHALL)\b",
    flags=re.IGNORECASE,
)

_PILLAR_PATHS = {
    "API": ("api.rst", "api"),
    "LEE": ("linux-environment.rst", "lee"),
}


@dataclass(frozen=True)
class SourceState:
    """Resolved state of a local specification checkout."""

    path: str
    branch: str | None
    commit: str | None
    dirty: bool


@dataclass(frozen=True)
class CandidateContext:
    """Source context used to build a requirement candidate."""

    relative_path: str
    pillar: str
    document: nodes.document
    paragraph: nodes.paragraph


def _run_git(source: Path, *args: str) -> str | None:
    """Run a read-only Git command and return stripped output."""

    result = subprocess.run(
        ["git", "-C", str(source), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def resolve_source_state(source: Path) -> SourceState:
    """Resolve branch, commit, and dirty state for a local checkout."""

    branch = _run_git(source, "branch", "--show-current")
    commit = _run_git(source, "rev-parse", "HEAD")
    status = _run_git(source, "status", "--short")

    return SourceState(
        path=str(source.resolve()),
        branch=branch or None,
        commit=commit or None,
        dirty=bool(status),
    )


def _source_root(source: Path) -> Path:
    """Return the RST source root for a GEISA specification checkout."""

    candidate = source / "source"
    if candidate.is_dir():
        return candidate
    return source


def pillar_files(source: Path, pillar: str) -> list[Path]:
    """Return RST files belonging to a supported conformance pillar."""

    normalized = pillar.upper()
    if normalized not in _PILLAR_PATHS:
        supported = ", ".join(sorted(_PILLAR_PATHS))
        raise ValueError(f"unsupported pillar {pillar!r}; expected one of {supported}")

    root = _source_root(source)
    top_level, directory = _PILLAR_PATHS[normalized]

    files: list[Path] = []
    top_level_path = root / top_level
    if top_level_path.is_file():
        files.append(top_level_path)

    pillar_dir = root / directory
    if pillar_dir.is_dir():
        files.extend(sorted(pillar_dir.rglob("*.rst")))

    if not files:
        raise FileNotFoundError(f"no RST files found for {normalized} under {root}")

    return files


def _document_title(document: nodes.document) -> str | None:
    """Return the document title when present."""

    for child in document.children:
        if isinstance(child, nodes.title):
            return child.astext()
    return None


def _section_title(node: nodes.Node, document: nodes.document) -> str | None:
    """Return the nearest section title or the document title."""

    current = node.parent
    while current is not None:
        if isinstance(current, nodes.section):
            for child in current.children:
                if isinstance(child, nodes.title):
                    return child.astext()
        current = current.parent

    return _document_title(document)


def _list_path(node: nodes.Node) -> list[str]:
    """Return labels from enclosing list items."""

    labels: list[str] = []
    current = node.parent

    while current is not None:
        if isinstance(current, nodes.list_item):
            first_paragraph = next(
                (
                    child
                    for child in current.children
                    if isinstance(child, nodes.paragraph)
                ),
                None,
            )
            if first_paragraph is not None and first_paragraph is not node:
                label = " ".join(first_paragraph.astext().split())
                if label:
                    labels.append(label)
        current = current.parent

    labels.reverse()
    return labels


def _candidate_id(path: str, line: int | None, source_text: str) -> str:
    """Create a repeatable candidate identifier."""

    value = f"{path}\n{line or 0}\n{source_text}".encode("utf-8")
    digest = hashlib.sha256(value).hexdigest()[:16]
    return f"rst:{path}:{line or 0}:{digest}"


def _canonical_level(value: str) -> str:
    """Return a requirement level in canonical uppercase form."""

    return " ".join(value.upper().split())


def _matches(source_text: str) -> list[dict[str, Any]]:
    """Return requirement keyword matches within one source block."""

    matches: list[dict[str, Any]] = []

    for match in _REQUIREMENT_PATTERN.finditer(source_text):
        source_keyword = match.group(1)
        canonical = _canonical_level(source_keyword)

        matches.append(
            {
                "level": canonical,
                "source_keyword": source_keyword,
                "noncanonical_case": source_keyword != canonical,
                "start": match.start(),
                "end": match.end(),
            }
        )

    return matches


def _serialize_list_item(item: nodes.list_item) -> dict[str, Any]:
    """Serialize one list item and any nested lists."""

    paragraphs = [
        " ".join(child.astext().split())
        for child in item.children
        if isinstance(child, nodes.paragraph)
    ]

    result: dict[str, Any] = {
        "text": " ".join(paragraphs).strip(),
    }

    children: list[dict[str, Any]] = []

    for child in item.children:
        if isinstance(child, (nodes.bullet_list, nodes.enumerated_list)):
            children.extend(
                _serialize_list_item(grandchild)
                for grandchild in child.children
                if isinstance(grandchild, nodes.list_item)
            )

    if children:
        result["children"] = children

    return result


def _following_list_node(
    paragraph: nodes.paragraph,
) -> nodes.bullet_list | nodes.enumerated_list | None:
    """Return the list immediately following the paragraph."""

    parent = paragraph.parent
    if parent is None:
        return None

    try:
        index = parent.children.index(paragraph)
    except ValueError:
        return None

    if index + 1 >= len(parent.children):
        return None

    sibling = parent.children[index + 1]

    if not isinstance(sibling, (nodes.bullet_list, nodes.enumerated_list)):
        return None

    return sibling


def _following_list(paragraph: nodes.paragraph) -> list[dict[str, Any]]:
    """Serialize a list immediately following the paragraph."""

    sibling = _following_list_node(paragraph)
    if sibling is None:
        return []

    return [
        _serialize_list_item(item)
        for item in sibling.children
        if isinstance(item, nodes.list_item)
    ]


def _list_item_paragraph(item: nodes.list_item) -> nodes.paragraph | None:
    """Return the first paragraph in a list item."""

    return next(
        (child for child in item.children if isinstance(child, nodes.paragraph)),
        None,
    )


def _recursive_list_items(
    list_node: nodes.bullet_list | nodes.enumerated_list,
) -> list[nodes.list_item]:
    """Return inherited list items in source order."""

    items: list[nodes.list_item] = []

    for item in list_node.children:
        if not isinstance(item, nodes.list_item):
            continue

        items.append(item)
        paragraph = _list_item_paragraph(item)
        if paragraph is not None and _matches(" ".join(paragraph.astext().split())):
            continue

        for child in item.children:
            if isinstance(child, (nodes.bullet_list, nodes.enumerated_list)):
                items.extend(_recursive_list_items(child))

    return items


def _admonition_context(
    paragraph: nodes.paragraph,
) -> dict[str, Any] | None:
    """Describe the nearest enclosing RST admonition."""

    current = paragraph.parent

    while current is not None:
        if isinstance(current, nodes.Admonition):
            title = next(
                (
                    child.astext()
                    for child in current.children
                    if isinstance(child, nodes.title)
                ),
                None,
            )

            result: dict[str, Any] = {
                "type": current.tagname,
                "title": title,
            }

            classes = list(current.get("classes", []))
            if classes:
                result["classes"] = classes

            return result

        current = current.parent

    return None


def _candidate(
    context: CandidateContext,
    source_text: str,
    matches: list[dict[str, Any]],
    include_children: bool = True,
) -> dict[str, Any]:
    """Build a candidate from one source block."""

    line = context.paragraph.line
    list_path = _list_path(context.paragraph)
    children = _following_list(context.paragraph)
    admonition = _admonition_context(context.paragraph)

    candidate: dict[str, Any] = {
        "type": "requirement-candidate",
        "candidate_id": _candidate_id(
            context.relative_path,
            line,
            source_text,
        ),
        "pillar": context.pillar.upper(),
        "source": {
            "path": context.relative_path,
            "document": _document_title(context.document),
            "section": _section_title(
                context.paragraph,
                context.document,
            ),
            "line_start": line,
            "line_end": line,
        },
        "requirement": {
            "source_text": source_text,
            "matches": matches,
        },
    }

    candidate_context: dict[str, Any] = {}

    if list_path:
        candidate_context["list_path"] = list_path

    if admonition:
        candidate_context["admonition"] = admonition

    if candidate_context:
        candidate["context"] = candidate_context

    if children and include_children:
        candidate["children"] = children

    return candidate


def _list_item_candidate(
    context: CandidateContext,
    item: nodes.list_item,
    parent_candidate: dict[str, Any],
    inherited_match: dict[str, Any],
) -> dict[str, Any] | None:
    """Build a generated candidate for an inherited list item."""

    paragraph = _list_item_paragraph(item)
    if paragraph is None:
        return None

    source_text = " ".join(paragraph.astext().split())
    if not source_text:
        return None
    if _matches(source_text):
        return None

    item_context = CandidateContext(
        relative_path=context.relative_path,
        pillar=context.pillar,
        document=context.document,
        paragraph=paragraph,
    )
    candidate = _candidate(item_context, source_text, [], include_children=False)
    candidate["requirement"].update(
        {
            "inherited_level": inherited_match["level"],
            "inherited_source_keyword": inherited_match["source_keyword"],
        }
    )
    candidate_context = candidate.setdefault("context", {})
    candidate_context.update(
        {
            "list_item": True,
            "parent_candidate_id": parent_candidate["candidate_id"],
        }
    )
    return candidate


def extract_file(  # pylint: disable=too-many-locals
    path: Path,
    root: Path,
    pillar: str,
) -> dict[str, Any]:
    """Extract candidates and audit data from one RST file."""

    text = path.read_text(encoding="utf-8")
    document = publish_doctree(
        source=text,
        source_path=str(path),
        settings_overrides={
            "halt_level": 5,
            "report_level": 5,
            "warning_stream": None,
            "raw_enabled": False,
            "file_insertion_enabled": False,
        },
    )

    relative_path = path.relative_to(root.parent).as_posix()
    candidates: list[dict[str, Any]] = []
    keyword_occurrences = 0
    noncanonical_keywords = 0

    for paragraph in document.findall(nodes.paragraph):
        source_text = " ".join(paragraph.astext().split())
        matches = _matches(source_text)

        if not matches:
            continue

        keyword_occurrences += len(matches)
        noncanonical_keywords += sum(
            1 for match in matches if match["noncanonical_case"]
        )

        context = CandidateContext(
            relative_path=relative_path,
            pillar=pillar,
            document=document,
            paragraph=paragraph,
        )
        following_list = _following_list_node(paragraph)
        should_generate_list_items = len(matches) == 1 and following_list is not None
        candidate = _candidate(
            context,
            source_text,
            matches,
        )
        candidates.append(candidate)

        if should_generate_list_items:
            for item in _recursive_list_items(following_list):
                list_item_candidate = _list_item_candidate(
                    context,
                    item,
                    candidate,
                    matches[0],
                )
                if list_item_candidate is not None:
                    candidates.append(list_item_candidate)

    return {
        "candidates": candidates,
        "audit": {
            "path": relative_path,
            "candidate_blocks": len(candidates),
            "keyword_occurrences": keyword_occurrences,
            "noncanonical_keywords": noncanonical_keywords,
        },
    }


def extract_candidates(source: Path, pillar: str) -> dict[str, Any]:
    """Extract candidate requirements for one pillar."""

    source = source.resolve()
    root = _source_root(source)
    state = resolve_source_state(source)

    candidates: list[dict[str, Any]] = []
    files: list[dict[str, Any]] = []

    for path in pillar_files(source, pillar):
        result = extract_file(path, root, pillar)
        candidates.extend(result["candidates"])
        files.append(result["audit"])

    return {
        "source": {
            "path": state.path,
            "branch": state.branch,
            "commit": state.commit,
            "dirty": state.dirty,
        },
        "pillar": pillar.upper(),
        "candidate_count": len(candidates),
        "keyword_occurrence_count": sum(item["keyword_occurrences"] for item in files),
        "noncanonical_keyword_count": sum(
            item["noncanonical_keywords"] for item in files
        ),
        "audit": {
            "files": files,
        },
        "candidates": candidates,
    }


def write_candidates(data: dict[str, Any], output: Path) -> None:
    """Write extracted candidates as YAML."""

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        yaml.safe_dump(
            data,
            sort_keys=False,
            allow_unicode=True,
        ),
        encoding="utf-8",
    )
