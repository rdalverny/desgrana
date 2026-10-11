# /// script
# requires-python = ">=3.11"
# dependencies = ["jinja2"]
# ///
"""
    uv run scripts/build_web.py        # or: make web
"""

from __future__ import annotations

import sys
import tomllib
import shutil
from datetime import date
from pathlib import Path

from jinja2 import Environment, FileSystemLoader

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
I18N = WEB / "i18n"
DIST = WEB / "dist"

DIST_EXCLUDE = {"dist", "i18n", "template.html.j2", "NOTES.md", "demo.mov"}

GENERATED_HEADER = (
    "<!-- GENERATED from template.html.j2 + i18n/*.toml — do not edit by hand. "
    "Run `make web` (uv run scripts/build_web.py) to regenerate. -->\n"
)

MONTHS = {
    "en": ["January", "February", "March", "April", "May", "June",
           "July", "August", "September", "October", "November", "December"],
    "fr": ["janvier", "février", "mars", "avril", "mai", "juin",
           "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
}

LOCALES = {
    "en": {
        "lang": "en",
        "out": DIST / "index.html",
        "css_href": "/atelier/atelier.css",
        "asset_prefix": "",
        "canonical": "/desgrana/",
        "switch_label": "FR",
        "switch_href": "/fr/desgrana/",
    },
    "fr": {
        "lang": "fr",
        "out": DIST / "index.fr.html",
        "css_href": "/atelier/atelier.css",
        "asset_prefix": "/desgrana/",
        "canonical": "/fr/desgrana/",
        "switch_label": "EN",
        "switch_href": "/desgrana/",
    },
}


def load_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def format_date(iso: str, lang: str) -> str:
    """'2026-05-28' -> 'May 28, 2026' (en) / '28 mai 2026' (fr)."""
    y, m, d = (int(x) for x in iso.split("-"))
    month = MONTHS[lang][m - 1]
    return f"{month} {d}, {y}" if lang == "en" else f"{d} {month} {y}"


def build_dist_assets() -> None:
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)
    for entry in sorted(WEB.iterdir()):
        if entry.name in DIST_EXCLUDE or entry.name.startswith("."):
            continue
        dest = DIST / entry.name
        if entry.is_dir():
            shutil.copytree(entry, dest)
        else:
            shutil.copy2(entry, dest)


def main() -> int:
    common = load_toml(I18N / "common.toml")
    env = Environment(
        loader=FileSystemLoader(str(WEB)),
        autoescape=False,
        keep_trailing_newline=True,
        trim_blocks=False,
        lstrip_blocks=False,
    )
    template = env.get_template("template.html.j2")

    build_dist_assets()
    base = common["canonical_base"].rstrip("/")

    for name, loc in LOCALES.items():
        strings = load_toml(I18N / f"{name}.toml")
        v = common["version"]
        parts = v.split(".")
        v_display = v[: -(len(parts[-1]) + 1)] if parts[-1] == "0" else v

        ctx = {
            **common,
            **strings,
            "lang": loc["lang"],
            "css_href": loc["css_href"],
            "asset_prefix": loc["asset_prefix"],
            "canonical": base + loc["canonical"],
            "og_url": base + loc["canonical"],
            "switch_label": loc["switch_label"],
            "switch_href": loc["switch_href"],
            "download_date": format_date(common["download_date"], name),
            "build_date": format_date(date.today().isoformat(), name),
            "version_display": v_display,
            # hreflang alternates, identical on every page
            "alt_en": base + LOCALES["en"]["canonical"],
            "alt_fr": base + LOCALES["fr"]["canonical"],
            "alt_default": base + LOCALES["en"]["canonical"],
        }
        html = template.render(**ctx)
        out: Path = loc["out"]
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(GENERATED_HEADER + html, encoding="utf-8")
        print(f"  {name} -> {out.relative_to(ROOT)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
