"""One immutable, decided-against observation of the Sanad UI."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any, Mapping, Optional, Tuple

TEXT_FIELD_TYPES = {"TextField", "TextFieldTapRegion"}


def _base_type(raw: Any) -> str:
    if not raw:
        return ""
    return str(raw).split("<", 1)[0].strip()


@dataclass(frozen=True)
class Observation:
    """A snapshot plus the provenance needed to reason about freshness."""

    elements: Tuple[Mapping[str, Any], ...]
    generation: Optional[int] = None
    status: str = "ok"
    settled: Optional[bool] = None
    ref: Optional[str] = None

    @classmethod
    def from_snapshot(
        cls, snapshot: Mapping[str, Any], ref: Optional[str] = None
    ) -> "Observation":
        elements = snapshot.get("elements")
        if not isinstance(elements, list):
            raise ValueError("snapshot has no elements list")
        status = snapshot.get("status")
        return cls(
            elements=tuple(element for element in elements if isinstance(element, Mapping)),
            generation=snapshot.get("generation"),
            status=str(status) if status is not None else "ok",
            settled=snapshot.get("settled"),
            ref=ref,
        )

    def keyed(self, key: str) -> Optional[Mapping[str, Any]]:
        for element in self.elements:
            if element.get("key") == key:
                return element
        return None

    def resolve(self, pattern: str) -> Optional[Tuple[str, Mapping[str, Any]]]:
        """Resolve an exact key, or a ``prefix*`` key pattern, to one element."""
        if pattern.endswith("*"):
            prefix = pattern[:-1]
            for element in self.elements:
                key = element.get("key")
                if isinstance(key, str) and key.startswith(prefix):
                    return key, element
            return None
        element = self.keyed(pattern)
        if element is None:
            return None
        return pattern, element

    def is_filled(self, key: str) -> Optional[bool]:
        element = self.keyed(key)
        if element is None:
            return None
        if _base_type(element.get("type")) not in TEXT_FIELD_TYPES:
            return None
        text = " ".join(str(element.get("text") or "").split())
        return bool(text)

    def key_count(self) -> int:
        return len(self.elements)

    def fingerprint(self) -> str:
        canonical = json.dumps(
            list(self.elements), sort_keys=True, separators=(",", ":"), default=str
        )
        return hashlib.sha256(canonical.encode("utf-8")).hexdigest()

    def reference(self) -> dict:
        return {
            "ref": self.ref,
            "generation": self.generation,
            "status": self.status,
            "settled": self.settled,
            "element_count": len(self.elements),
            "fingerprint": self.fingerprint()[:16],
        }
