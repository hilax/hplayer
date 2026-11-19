#!/usr/bin/env python3
"""Ensure every alternate app icon ships both Assets.car entries and root PNG files.

Xcode 26 compiles alternate app icons into Assets.car with only `CFBundleIconName` in
Info.plist and omits root `@2x`/`@3x` PNGs and `CFBundleIconFiles`. On iOS 18/26
(especially after OTA/zsign re-signing or under Dark/Tinted Home Screen modes),
SpringBoard/IconServices can fall back to the blank white blueprint grid when
`CFBundleIconFiles` and root PNGs are missing.

This script runs as an Xcode post-build phase (before CodeSign) to generate standard
`@2x`/`@3x` and iPad PNGs into the `.app` bundle root and populate `CFBundleIconFiles`
alongside `CFBundleIconName` in both `CFBundleIcons` and `CFBundleIcons~ipad`.
"""

import os
import pathlib
import plistlib
import subprocess
import sys

PRIMARY_ICON = "AppIcon"
ALTERNATE_ICONS = [
    "AppIconClassic",
    "AppIconPrism",
    "AppIconOcean",
    "AppIconMint",
    "AppIconIris",
    "AppIconCoral",
]

ICON_RENDITIONS = [
    ("60x60@2x.png", 120),
    ("60x60@3x.png", 180),
    ("76x76@2x~ipad.png", 152),
    ("83.5x83.5@2x~ipad.png", 167),
]


def render_png(source: pathlib.Path, destination: pathlib.Path, pixels: int) -> None:
    if destination.exists() and destination.stat().st_mtime >= source.stat().st_mtime:
        return
    subprocess.run(
        [
            "sips",
            "-s",
            "format",
            "png",
            "-z",
            str(pixels),
            str(pixels),
            str(source),
            "--out",
            str(destination),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def ensure_icon_dict(plist: dict, root_key: str, icon_files_for_name) -> None:
    icons = plist.setdefault(root_key, {})
    primary = icons.setdefault("CFBundlePrimaryIcon", {})
    primary["CFBundleIconName"] = PRIMARY_ICON
    primary["CFBundleIconFiles"] = icon_files_for_name(PRIMARY_ICON)

    alternates = icons.setdefault("CFBundleAlternateIcons", {})
    for name in ALTERNATE_ICONS:
        entry = alternates.setdefault(name, {})
        entry["CFBundleIconName"] = name
        entry["CFBundleIconFiles"] = icon_files_for_name(name)


def main() -> int:
    srcroot = pathlib.Path(os.environ["SRCROOT"])
    build_dir = pathlib.Path(os.environ["TARGET_BUILD_DIR"])
    resources_rel = os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
    infoplist_rel = os.environ["INFOPLIST_PATH"]

    app_dir = build_dir / resources_rel
    infoplist_path = build_dir / infoplist_rel
    assets_dir = srcroot / "HPlayer" / "Assets.xcassets"

    if not infoplist_path.exists():
        print(f"bundle-alternate-icons: Info.plist not found at {infoplist_path}", file=sys.stderr)
        return 1

    all_icons = [PRIMARY_ICON] + ALTERNATE_ICONS
    for name in all_icons:
        src = assets_dir / f"{name}.appiconset" / "AppIcon.png"
        if not src.exists():
            print(f"bundle-alternate-icons: missing source icon {src}", file=sys.stderr)
            return 1
        for suffix, pixels in ICON_RENDITIONS:
            render_png(src, app_dir / f"{name}{suffix}", pixels)

    with infoplist_path.open("rb") as f:
        plist = plistlib.load(f)

    ensure_icon_dict(
        plist,
        "CFBundleIcons",
        lambda name: [f"{name}60x60"],
    )
    ensure_icon_dict(
        plist,
        "CFBundleIcons~ipad",
        lambda name: [f"{name}60x60", f"{name}76x76", f"{name}83.5x83.5"],
    )

    with infoplist_path.open("wb") as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)

    print(f"bundle-alternate-icons: packaged {len(all_icons)} icon sets into {app_dir.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
