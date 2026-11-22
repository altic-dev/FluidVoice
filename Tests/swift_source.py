"""Helpers for extracting declarations from Swift source in test harnesses."""
import re


def declaration(source: str, marker: str) -> str:
    """Return the braced declaration starting at `marker`.

    A trailing ':' in `marker` is optional, so markers like `struct Foo:` still
    match after SwiftFormat drops a redundant conformance list.
    """
    name = marker.removesuffix(":")
    pattern = re.escape(name) + (r"\b" if marker.endswith(":") else "")
    match = re.search(pattern, source)
    if not match:
        raise ValueError(f"declaration not found: {marker!r}")
    start = match.start()
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]
