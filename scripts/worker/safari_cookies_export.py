#!/usr/bin/env python3
"""Convert Safari binary cookies to Netscape cookies.txt format.

Usage: python3 safari_cookies_export.py <input.binarycookies> <output.txt>

Safari binary cookies 文件受 macOS TCC 保护, Python 无法直接读取原始路径.
需要先用 bash cp 拷贝到 /tmp/, 再用此脚本转换.
"""
import struct
import sys
from datetime import datetime, timezone

# Safari/macOS epoch: 2001-01-01 00:00:00 UTC
SAFARI_EPOCH_OFFSET = 978307200


def parse_safari_cookies(path):
    cookies = []
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic != b"cook":
            raise ValueError(f"Not a Safari binary cookies file (magic: {magic!r})")

        num_pages = struct.unpack(">I", f.read(4))[0]
        page_sizes = [struct.unpack(">I", f.read(4))[0] for _ in range(num_pages)]

        for page_size in page_sizes:
            page = f.read(page_size)
            if page[:4] != b"\x00\x00\x01\x00":
                continue
            num_cookies = struct.unpack("<I", page[4:8])[0]
            offsets = [struct.unpack("<I", page[8 + i * 4 : 12 + i * 4])[0] for i in range(num_cookies)]

            for offset in offsets:
                c = page[offset:]
                if len(c) < 48:
                    continue
                flags = struct.unpack("<I", c[4:8])[0]
                url_off = struct.unpack("<I", c[16:20])[0]
                name_off = struct.unpack("<I", c[20:24])[0]
                path_off = struct.unpack("<I", c[24:28])[0]
                val_off = struct.unpack("<I", c[28:32])[0]
                expiry = struct.unpack("<d", c[40:48])[0]
                expiry_unix = int(expiry + SAFARI_EPOCH_OFFSET) if expiry > 0 else 0

                def s(data, off):
                    end = data.index(b"\x00", off)
                    return data[off:end].decode("utf-8", errors="replace")

                domain = s(c, url_off)
                name = s(c, name_off)
                path = s(c, path_off)
                value = s(c, val_off)
                secure = "TRUE" if flags & 1 else "FALSE"
                subdomain = "TRUE" if domain.startswith(".") else "FALSE"

                cookies.append(f"{domain}\t{subdomain}\t{path}\t{secure}\t{expiry_unix}\t{name}\t{value}")

    return cookies


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.binarycookies> <output.txt>", file=sys.stderr)
        sys.exit(1)

    input_path, output_path = sys.argv[1], sys.argv[2]
    cookies = parse_safari_cookies(input_path)

    with open(output_path, "w") as f:
        f.write("# Netscape HTTP Cookie File\n")
        f.write("# Converted from Safari binary cookies\n")
        for line in cookies:
            f.write(line + "\n")

    yt_cookies = [c for c in cookies if "youtube" in c.lower() or "google" in c.lower()]
    print(f"Exported {len(cookies)} cookies ({len(yt_cookies)} YouTube/Google)", file=sys.stderr)


if __name__ == "__main__":
    main()
