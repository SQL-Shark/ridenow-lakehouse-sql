"""Download NYC TLC yellow taxi trip data and the taxi zone lookup into data/raw/.

    python scripts/download_data.py --months 2024-01
    python scripts/download_data.py --months 2024-01 2024-02 2024-03

Hosts confirmed by reading the link hrefs on
https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page rather than from memory.
Note the zone lookup lives under /misc/, not /trip-data/ - the obvious guess is wrong.
"""

import argparse
import re
import sys
from pathlib import Path

import requests

TRIP_URL = "https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_{month}.parquet"
ZONE_URL = "https://d37ci6vzurychx.cloudfront.net/misc/taxi_zone_lookup.csv"

# scripts/ sits one level below the project root, so data/ is a sibling of scripts/.
# Anchoring to __file__ rather than the cwd means the script works from anywhere.
PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = PROJECT_ROOT / "data" / "raw"

MONTH_RE = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")
CHUNK_SIZE = 1 << 20  # 1 MiB


def download(url: str, dest: Path) -> Path:
    """Stream ``url`` to ``dest``, skipping the download if the file is already there."""
    if dest.exists():
        print(f"cached  {dest.name} ({dest.stat().st_size:,} bytes) - skipping download")
        return dest

    dest.parent.mkdir(parents=True, exist_ok=True)
    # Download to a .part file and rename on success, so an interrupted run cannot leave
    # a truncated file that the cache check above would then treat as complete.
    tmp = dest.with_suffix(dest.suffix + ".part")
    print(f"getting {dest.name} from {url}")

    with requests.get(url, stream=True, timeout=60) as resp:
        resp.raise_for_status()
        with open(tmp, "wb") as fh:
            for chunk in resp.iter_content(chunk_size=CHUNK_SIZE):
                fh.write(chunk)

    tmp.replace(dest)
    print(f"done    {dest.name} ({dest.stat().st_size:,} bytes)")
    return dest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--months",
        nargs="+",
        default=["2024-01"],
        metavar="YYYY-MM",
        help="months of yellow taxi data to download (default: 2024-01)",
    )
    args = parser.parse_args()

    # Validated up front: a malformed month otherwise surfaces as an opaque CloudFront
    # 403 rather than an obvious "you typed the month wrong".
    bad = [m for m in args.months if not MONTH_RE.match(m)]
    if bad:
        parser.error(f"months must look like YYYY-MM, got: {', '.join(bad)}")

    for month in args.months:
        download(TRIP_URL.format(month=month), RAW_DIR / f"yellow_tripdata_{month}.parquet")

    download(ZONE_URL, RAW_DIR / "taxi_zone_lookup.csv")
    return 0


if __name__ == "__main__":
    sys.exit(main())
