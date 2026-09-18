"""Tests for the scraper.

Run them from the repo root:

    python3 -m unittest discover -s scraper/tests -t .

scraper/ is not a package, so importing `scrape` and its siblings the way the
scraper itself does (and the way contract/validate.py does, which inserts
scraper/ on sys.path before `import scrape`) needs that directory on the path.
Doing it here means every test module can just `import scrape`.
"""

import pathlib
import sys

SCRAPER_DIR = pathlib.Path(__file__).resolve().parent.parent
ROOT = SCRAPER_DIR.parent

for _p in (str(ROOT), str(SCRAPER_DIR)):
    if _p not in sys.path:
        sys.path.insert(0, _p)
