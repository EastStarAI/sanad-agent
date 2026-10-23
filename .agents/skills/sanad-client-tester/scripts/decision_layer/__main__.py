"""Direct-execution shim so both invocation styles work.

    PYTHONPATH=.agents/skills/sanad-client-tester/scripts python3 -m decision_layer ...
    python3 .agents/skills/sanad-client-tester/scripts/decision_layer ...
"""

from __future__ import annotations

import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from decision_layer.cli import main  # type: ignore[no-redef]
else:
    from .cli import main

if __name__ == "__main__":
    sys.exit(main())
