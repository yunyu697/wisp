#!/usr/bin/env python3
"""生成发布用的 update.json（含各平台 sha256），由 CI 在发版时调用。

为什么由 CI 生成而不是手写：
· 摘要只能在构建完成后算，手写必然滞后或写错；
· 客户端的一键更新要求「清单里的 sha256」与「下载到的字节」一致，
  没有摘要就不许自动安装——所以这份文件必须每次都跟着产物走。

`notes` 仍然从仓库根目录的 update.json 里取（那部分是人写的），
版本号与下载地址按当前标签重写。

用法：
    python3 tools/gen_update_manifest.py --version 1.0.20 --dist dist
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

REPO = "yunyu697/wisp"

# 平台 → 产物文件名模板。AppImage 是 Linux 上唯一支持一键更新的形态。
ASSETS = {
    "windows": "wisp-windows-x64-{v}-setup.exe",
    "macos": "wisp-macos-{v}.dmg",
    "linux": "wisp-linux-x64-{v}.AppImage",
    "android": "wisp-android-{v}.apk",
}


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True, help="不带 v 前缀，例如 1.0.20")
    parser.add_argument("--dist", default="dist", help="产物目录")
    parser.add_argument("--repo-file", default="update.json", help="仓库里的清单（取 notes）")
    args = parser.parse_args()

    version = args.version.lstrip("v")
    dist = pathlib.Path(args.dist)
    base = f"https://github.com/{REPO}/releases/download/v{version}/"

    notes = ""
    repo_manifest = pathlib.Path(args.repo_file)
    if repo_manifest.exists():
        try:
            notes = json.loads(repo_manifest.read_text(encoding="utf-8")).get("notes", "")
        except json.JSONDecodeError:
            print(f"警告：{repo_manifest} 不是合法 JSON，notes 留空", file=sys.stderr)

    downloads: dict[str, str] = {}
    hashes: dict[str, str] = {}
    missing: list[str] = []
    for platform, template in ASSETS.items():
        name = template.format(v=version)
        path = dist / name
        if not path.exists():
            missing.append(name)
            continue
        downloads[platform] = base + name
        hashes[platform] = sha256_of(path)

    if missing:
        # 宁可让发布失败，也不要发出一个"没有校验值"的清单——
        # 那会让所有客户端的一键更新直接停摆。
        print("缺少产物，拒绝生成清单：" + ", ".join(missing), file=sys.stderr)
        return 1

    manifest = {
        "version": version,
        "notes": notes,
        "downloadUrl": downloads["windows"],
        "downloads": downloads,
        "sha256": hashes,
    }
    out = dist / "update.json"
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"已生成 {out}")
    for platform, digest in hashes.items():
        print(f"  {platform:8s} {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
