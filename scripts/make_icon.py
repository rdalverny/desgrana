#!/usr/bin/env python3
# Generates every app icon from icon.icon (the single source):
#   - macOS:   Desgrana.iconset/ + Desgrana.xcassets/        (ictool + sips)
#   - Linux:   packaging/linux/icons/hicolor/<size>/apps/desgrana.png
#   - Windows: packaging/win/desgrana.ico
# The Linux/Windows icons derive from the Default rendition, exported flat at
# 1024px, so all platforms share one artwork. Called by `make icon` (macOS only).
#
# Requires Icon Composer (Xcode 16.3+) for ictool, and ImageMagick (magick) for
# the Linux/Windows icons.

import json, os, shutil, subprocess, sys

ICONSET    = "Desgrana.iconset"
XCASSETS   = "Desgrana.xcassets"
APPICONSET = os.path.join(XCASSETS, "AppIcon.appiconset")

ICTOOL = (
    "/Applications/Xcode.app/Contents/Applications/"
    "Icon Composer.app/Contents/Executables/ictool"
)

# Apple HIG: artwork area = canvas - 2 × padding (86px on a 1024px canvas)
HIG_CANVAS  = 1024
HIG_PADDING = 86
HIG_ARTWORK = HIG_CANVAS - 2 * HIG_PADDING   # 852 px

SIZES = [
    (16,  1), (16,  2),
    (32,  1), (32,  2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

# ictool rendition name -> appearance suffix used in filenames / Contents.json
RENDITIONS = {
    "Default":     "",
    "Dark":        "dark",
    "TintedLight": "tinted",
    "TintedDark":  "tinted-dark",
}

APPEARANCE_ENTRIES = {
    "dark":        [{"appearance": "luminosity", "value": "dark"}],
    "tinted":      [{"appearance": "luminosity", "value": "tinted"}],
    "tinted-dark": [{"appearance": "luminosity", "value": "tinted"}],
}


def filename(logical: int, scale: int, appearance: str) -> str:
    suffix = f"~{appearance}" if appearance else ""
    scale_tag = f"@{scale}x" if scale > 1 else ""
    return f"icon_{logical}x{logical}{suffix}{scale_tag}.png"


def export_rendition(icon_path: str, rendition: str, appearance: str) -> list:
    if not os.path.exists(ICTOOL):
        sys.exit(f"Error: ictool not found at\n  {ICTOOL}")

    # probe: skip this rendition if the .icon doesn't contain it
    probe = subprocess.run(
        [ICTOOL, icon_path,
         "--export-image", "--output-file", f"/tmp/_probe_{rendition}.png",
         "--platform", "macOS", "--rendition", rendition,
         "--width", "16", "--height", "16", "--scale", "1"],
        capture_output=True,
    )
    if probe.returncode != 0:
        return []

    written = []
    for logical, scale in SIZES:
        canvas  = logical * scale
        artwork = round(canvas * HIG_ARTWORK / HIG_CANVAS)
        fname   = filename(logical, scale, appearance)
        out     = os.path.join(ICONSET, fname)

        # Export at artwork size (no HIG padding yet)
        r = subprocess.run(
            [ICTOOL, icon_path,
             "--export-image", "--output-file", out,
             "--platform", "macOS", "--rendition", rendition,
             "--width", str(artwork), "--height", str(artwork), "--scale", "1"],
            capture_output=True,
        )
        if r.returncode != 0:
            sys.exit(f"ictool failed ({rendition} {canvas}px):\n{r.stderr.decode()}")

        # Add HIG padding to reach the full canvas size
        subprocess.run(
            ["sips", "--padToHeightWidth", str(canvas), str(canvas), out],
            capture_output=True, check=True,
        )

        written.append(fname)
        print(f"  {fname}  ({rendition})")
    return written


def build_xcassets(written_by_appearance: dict) -> None:
    os.makedirs(APPICONSET, exist_ok=True)
    for fnames in written_by_appearance.values():
        for fname in fnames:
            shutil.copy2(os.path.join(ICONSET, fname),
                         os.path.join(APPICONSET, fname))

    images = []
    for logical, scale in SIZES:
        for appearance, fnames in written_by_appearance.items():
            fname = filename(logical, scale, appearance)
            if fname not in fnames:
                continue
            entry = {
                "idiom":    "mac",
                "scale":    f"{scale}x",
                "size":     f"{logical}x{logical}",
                "filename": fname,
            }
            if appearance in APPEARANCE_ENTRIES:
                entry["appearances"] = APPEARANCE_ENTRIES[appearance]
            images.append(entry)

    with open(os.path.join(XCASSETS, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    with open(os.path.join(APPICONSET, "Contents.json"), "w") as f:
        json.dump({"images": images,
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    print(f"  Contents.json ({len(images)} entries)")


# ── Linux + Windows icons (from the Default rendition) ────────────────────────

FLAT_MASTER     = "/tmp/desgrana-icon-1024.png"
LINUX_ICONS_DIR = "packaging/linux/icons/hicolor"
LINUX_SIZES     = [16, 32, 48, 64, 128, 256, 512]
WIN_ICO         = "packaging/win/desgrana.ico"
WIN_ICO_SIZES   = [16, 32, 48, 64, 128, 256]


def export_flat_master(icon_path: str) -> None:
    if shutil.which("magick") is None:
        sys.exit("Error: ImageMagick ('magick') not found; needed for Linux/Windows icons.")
    r = subprocess.run(
        [ICTOOL, icon_path,
         "--export-image", "--output-file", FLAT_MASTER,
         "--platform", "macOS", "--rendition", "Default",
         "--width", "1024", "--height", "1024", "--scale", "1"],
        capture_output=True,
    )
    if r.returncode != 0:
        sys.exit(f"ictool failed exporting the Default rendition:\n{r.stderr.decode()}")
    print(f"Flat master: {FLAT_MASTER}")


def build_linux_icons() -> None:
    for size in LINUX_SIZES:
        out_dir = os.path.join(LINUX_ICONS_DIR, f"{size}x{size}", "apps")
        os.makedirs(out_dir, exist_ok=True)
        out = os.path.join(out_dir, "desgrana.png")
        subprocess.run(["magick", FLAT_MASTER, "-resize", f"{size}x{size}", out],
                       check=True)
        print(f"  {out}")
    print(f"Linux icons ready: {LINUX_ICONS_DIR}/")


def build_windows_ico() -> None:
    os.makedirs(os.path.dirname(WIN_ICO), exist_ok=True)
    sizes = ",".join(str(s) for s in WIN_ICO_SIZES)
    subprocess.run(["magick", FLAT_MASTER, "-background", "none",
                    "-define", f"icon:auto-resize={sizes}", WIN_ICO],
                   check=True)
    print(f"Windows icon ready: {WIN_ICO}")


# ── main ─────────────────────────────────────────────────────────────────────

icon_path = "icon.icon"
if not os.path.exists(icon_path):
    sys.exit("Error: icon.icon not found. Create it with Icon Composer.")

os.makedirs(ICONSET, exist_ok=True)

written_by_appearance = {}
for rendition, appearance in RENDITIONS.items():
    fnames = export_rendition(icon_path, rendition, appearance)
    if fnames:
        written_by_appearance[appearance] = fnames

print(f"Iconset ready: {ICONSET}/")
build_xcassets(written_by_appearance)
print(f"xcassets ready: {XCASSETS}/")

export_flat_master(icon_path)
build_linux_icons()
build_windows_ico()
