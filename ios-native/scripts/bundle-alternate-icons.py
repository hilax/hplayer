#!/usr/bin/env python3
"""Bundle alternate app icons as loose root PNGs referenced via CFBundleIconFiles.

Using `CFBundleIconName` inside `CFBundleAlternateIcons` forces iOS IconServices to
resolve alternate icons from `Assets.car`, which both bloats `Assets.car` by 12–38 MB
with duplicated 1024x1024 bitmaps and can render a blank blueprint grid on iOS 26 /
re-signed IPA builds.

Instead, keep only the primary `AppIcon` in `Assets.xcassets`, store alternate icon
masters outside the bundle in `ios-native/AlternateIcons/`, and generate compact
`@2x`/`@3x` iPhone and iPad PNGs directly into the `.app` root during build,
declaring them with classic `CFBundleIconFiles` (without `CFBundleIconName`).
"""

import os
import pathlib
import plistlib
import subprocess
import sys

ALTERNATE_ICONS = [
    "AppIconClassic",
    "AppIconPrism",
    "AppIconOcean",
    "AppIconMint",
    "AppIconIris",
    # 珊瑚橙改用全新注册名：iOS 按「备选图标名」缓存桌面渲染结果，旧名 AppIconCoral
    # 在早期 Assets.car 方案下被缓存成空白网格后，覆盖安装、换版本号都不会刷新。
    "HPIconCoral",
]

# 早期构建注册过的旧名 -> 现在的名称。旧名仍写进 Info.plist（指向新名的实体 PNG），
# 保证系统当前仍停在旧名的设备有合法条目；App 内再点一次该样式即迁移到新名。
LEGACY_ALIASES = {
    "AppIconCoral": "HPIconCoral",
}

ICON_RENDITIONS = [
    ("@2x.png", 120),
    ("@3x.png", 180),
    ("@2x~ipad.png", 152),
    ("-83.5@2x~ipad.png", 167),
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


def populate_alternate_icons(plist: dict, root_key: str, icon_files_for_name) -> None:
    icons = plist.setdefault(root_key, {})
    alternates = {}
    for name in ALTERNATE_ICONS:
        # Deliberately omit `CFBundleIconName` so iOS IconServices loads the loose
        # `@2x`/`@3x` root PNGs via `CFBundleIconFiles` rather than `Assets.car`.
        alternates[name] = {
            "CFBundleIconFiles": icon_files_for_name(name),
            "UIPrerenderedIcon": False,
        }
    for legacy, current in LEGACY_ALIASES.items():
        alternates[legacy] = {
            "CFBundleIconFiles": icon_files_for_name(current),
            "UIPrerenderedIcon": False,
        }
    icons["CFBundleAlternateIcons"] = alternates


def main() -> int:
    srcroot = pathlib.Path(os.environ["SRCROOT"])
    build_dir = pathlib.Path(os.environ["TARGET_BUILD_DIR"])
    resources_rel = os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
    infoplist_rel = os.environ["INFOPLIST_PATH"]

    app_dir = build_dir / resources_rel
    infoplist_path = build_dir / infoplist_rel
    masters_dir = srcroot / "AlternateIcons"

    if not infoplist_path.exists():
        print(f"bundle-alternate-icons: Info.plist not found at {infoplist_path}", file=sys.stderr)
        return 1

    for name in ALTERNATE_ICONS:
        src = masters_dir / f"{name}.png"
        if not src.exists():
            print(f"bundle-alternate-icons: missing source icon {src}", file=sys.stderr)
            return 1
        for suffix, pixels in ICON_RENDITIONS:
            render_png(src, app_dir / f"{name}{suffix}", pixels)

    with infoplist_path.open("rb") as f:
        plist = plistlib.load(f)

    populate_alternate_icons(
        plist,
        "CFBundleIcons",
        lambda name: [name],
    )
    populate_alternate_icons(
        plist,
        "CFBundleIcons~ipad",
        lambda name: [name, f"{name}-83.5"],
    )

    with infoplist_path.open("wb") as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)

    print(f"bundle-alternate-icons: packaged {len(ALTERNATE_ICONS)} alternate icon sets into {app_dir.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
