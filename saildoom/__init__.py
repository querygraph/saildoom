"""SailDoom: SQLDoom's game and database API, on Sail."""

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sqldoom_checkout() -> Path:
    """SQLDoom's checkout: $SAILDOOM_SQLDOOM, else the one scripts/setup.sh
    clones (.build/sqldoom), else ../saildoom-ref/sqldoom beside this one."""
    if os.environ.get("SAILDOOM_SQLDOOM"):
        return Path(os.environ["SAILDOOM_SQLDOOM"])
    for path in (ROOT / ".build/sqldoom", ROOT.parent / "saildoom-ref/sqldoom"):
        if path.is_dir():
            return path
    return ROOT / ".build/sqldoom"
