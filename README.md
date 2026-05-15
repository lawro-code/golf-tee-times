# Golf Tee Time Finder

Personal site that aggregates publicly available tee times from Sydney public golf courses (within ~1h of Bondi). Refreshes twice daily via GitHub Actions; frontend served from GitHub Pages.

Live site: `https://<username>.github.io/golf-tee-times/`

## How it works

1. `scraper/scrape.py` hits each course's MiClub public timesheet for the next 5 days, parses available slots, writes `data/teetimes.json`.
2. GitHub Actions runs the scraper at 8am and 8pm Sydney time, commits the updated JSON.
3. `docs/index.html` fetches that JSON and renders it with filters.

## Adding a new course

1. Find the club's MiClub subdomain (e.g. `woollahra.miclub.com.au`).
2. Run `python3 scraper/discover.py <subdomain>` to find its `feeGroupId`.
3. Add an entry to `courses.json`.
4. Re-run `python3 scraper/scrape.py` to verify.

## Local dev

```bash
pip3 install -r scraper/requirements.txt
python3 scraper/scrape.py
open docs/index.html
```

## Manual refresh in production

GitHub repo → Actions → "Scrape tee times" → Run workflow.
