#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""打包：按原包的权限位与条目形态重打，保证除内容外与上游一致。"""
import os
import sys
import zipfile
from pathlib import Path

sys.stdout.reconfigure(encoding='utf-8')

ROOT = Path(__file__).resolve().parent
CASE = ROOT.parent
ORIG_ZIP = Path(r'D:\Downloads\Compressed\ViPER4Android-RE-AIDL-v2.1.2.zip')
BUILD = ROOT / 'build'
DIST = ROOT / 'dist'
OUT = DIST / 'ViPER4Android-RE-AIDL-v2.1.2-nomount.zip'


def main():
    DIST.mkdir(parents=True, exist_ok=True)
    if OUT.exists():
        OUT.unlink()

    # 原包权限表（含目录条目）
    zo = zipfile.ZipFile(ORIG_ZIP)
    orig_mode = {i.filename: (i.external_attr >> 16) for i in zo.infolist()}
    orig_order = [i.filename for i in zo.infolist()]

    # 收集 build 里的文件/目录，路径统一正斜杠
    present = set()
    for root, dirs, files in os.walk(BUILD):
        for d in dirs:
            present.add(os.path.relpath(os.path.join(root, d), BUILD).replace('\\', '/') + '/')
        for f in files:
            present.add(os.path.relpath(os.path.join(root, f), BUILD).replace('\\', '/'))

    # 已删除的条目（如 skip_mount）自然不在 present 里
    seq = [n for n in orig_order if n in present]
    extra = sorted(n for n in present if n not in orig_order)
    seq += extra  # 新增条目追加到末尾

    with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in seq:
            full = BUILD / name
            zi = zipfile.ZipInfo(name)
            zi.create_system = 3
            zi.compress_type = zipfile.ZIP_DEFLATED
            if name.endswith('/'):
                mode = orig_mode.get(name, 0o40755)
                zi.external_attr = (mode << 16) | 0x10
                z.writestr(zi, b'')
            else:
                mode = orig_mode.get(name, 0o100644)
                zi.external_attr = mode << 16
                zi.date_time = (2026, 11, 19, 0, 0, 0)
                with open(full, 'rb') as fh:
                    z.writestr(zi, fh.read())

    print('打包完成:', OUT)
    print('大小:', OUT.stat().st_size, 'bytes  条目:', len(seq))
    print('新增条目:', extra or '无')
    print('已删除:', sorted(n for n in orig_order if n not in present) or '无')


if __name__ == '__main__':
    main()
