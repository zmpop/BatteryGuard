#!/usr/bin/env python3
# Battery Guard - 打包 Magisk 模块 zip
# 用法：python build.py
# 说明：必须写入目录条目并保留 Unix 权限位，否则部分 Magisk 版本解压会失败

import os
import stat
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
OUT = os.path.join(HERE, "BatteryGuard-v1.0.zip")

EXECUTABLES = {
    "service.sh",
    "post-fs-data.sh",
    "uninstall.sh",
    "action.sh",
    "customize.sh",
    "common/lib.sh",
    "common/probe.sh",
    "common/supervisor.sh",
    "common/battery-guard-daemon.sh",
    "META-INF/com/google/android/update-binary",
}


def build():
    entries = []
    for root, dirs, files in os.walk(SRC):
        for d in dirs:
            rel = os.path.relpath(os.path.join(root, d), SRC).replace("\\", "/")
            entries.append((rel + "/", None))
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), SRC).replace("\\", "/")
            entries.append((rel, os.path.join(root, f)))
    entries.sort(key=lambda e: e[0])

    now = time.localtime()[:6]
    total = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for name, src in entries:
            info = zipfile.ZipInfo(name, date_time=now)
            info.create_system = 3
            if src is None:
                info.external_attr = (stat.S_IFDIR | 0o755) << 16
                z.writestr(info, b"")
            else:
                perm = 0o755 if name in EXECUTABLES else 0o644
                info.external_attr = (stat.S_IFREG | perm) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(src, "rb") as fh:
                    data = fh.read()
                z.writestr(info, data)
                total += 1
    print("已生成 %s（%d 个文件），权限位已保留" % (OUT, total))


if __name__ == "__main__":
    build()
