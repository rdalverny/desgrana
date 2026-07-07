# /// script
# requires-python = ">=3.11"
# dependencies = ["jinja2"]
# ///
"""Render the Desgrana web pages from a Jinja2 template + per-language TOML.

Single source of truth: web/template.html.j2 (structure) + web/i18n/*.toml (data).
Generated files (web/index.html, web/fr/index.html) are committed so deployment
stays a dumb copy of web/.

    uv run scripts/build_web.py        # or: make web

Autoescape is OFF: the TOML content is author-controlled and contains raw HTML
(entities, <p>, <code>, links). Treating it as trusted keeps byte-for-byte
fidelity with the hand-written source.
"""

from __future__ import annotations

import sys
import tomllib
import shutil
from pathlib import Path

from jinja2 import Environment, FileSystemLoader

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
I18N = WEB / "i18n"
DIST = WEB / "dist"   # self-contained, deployable build output (gitignored)

# Source/internal files in web/ that must NOT be copied into the deployable dist.
# Everything else in web/ (demo.mp4, poster, version.json, icon…) is an asset to ship.
DIST_EXCLUDE = {"dist", "i18n", "template.html.j2", "NOTES.md", "demo.mov"}

GENERATED_HEADER = (
    "<!-- GENERATED from template.html.j2 + i18n/*.toml — do not edit by hand. "
    "Run `make web` (uv run scripts/build_web.py) to regenerate. -->\n"
)

# Month names for localized release dates (avoids a Babel dependency).
MONTHS = {
    "en": ["January", "February", "March", "April", "May", "June",
           "July", "August", "September", "October", "November", "December"],
    "fr": ["janvier", "février", "mars", "avril", "mai", "juin",
           "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
}

# Per-locale structural config (paths, URLs, language switcher).
# Not in the TOML: these are layout concerns, derived from the output location.
LOCALES = {
    "en": {
        "lang": "en",
        "out": DIST / "index.html",
        "css_href": "/atelier/atelier.css",   # page at /atelier/desgrana/
        "asset_prefix": "",
        "canonical": "/atelier/desgrana/",
        "switch_label": "FR",
        "switch_href": "/fr/atelier/desgrana/",
    },
    "fr": {
        "lang": "fr",
        "out": DIST / "index.fr.html",
        "css_href": "/atelier/atelier.css",  # page at /fr/atelier/desgrana/
        "asset_prefix": "/atelier/desgrana/",
        "canonical": "/fr/atelier/desgrana/",
        "switch_label": "EN",
        "switch_href": "/atelier/desgrana/",
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
    """Rebuild web/dist from scratch and copy every deployable asset from web/ into it,
    so web/dist is a complete, self-contained tree to upload."""
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
