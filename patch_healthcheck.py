#!/usr/bin/env python3
"""
Patches LoxBerry's /opt/loxberry/sbin/healthcheck.pl to fix two false
positives seen when running LoxBerry inside a Docker container on a
large disk:

1. check_readonlyrootfs only recognizes "ext4" as a valid read-write
   filesystem type. Docker's root is usually OverlayFS, so this check
   always reports the RootFS as read-only even when it's genuinely
   writable. Fix: match any filesystem type, not just ext4.

2. check_rootfssize only looks at the free-space PERCENTAGE. On very
   large disks (e.g. a 1.8TB volume), 5% free can still mean tens of
   GB of genuinely available space, so this triggers unnecessary
   "please reboot" warnings. Fix: only warn if the percentage AND the
   absolute free space are both low (default floor: 5GB).

Usage:
    python3 patch_healthcheck.py /path/to/healthcheck.pl

A backup is written next to the original file as healthcheck.pl.bak
before any changes are made. Safe to re-run: if the patched text is
already present, that part is left untouched.
"""

import re
import sys
import shutil
from pathlib import Path

ABSOLUTE_MIN_KB = 5 * 1024 * 1024  # 5 GB, in KB (diskspaceinfo() reports KB)


def patch_readonlyrootfs(text: str) -> str:
    old = "system (\"mount | grep -q -i -e 'on / type ext4 (rw'\");"
    new = "system (\"mount | grep -q -i -e 'on / type .* (rw'\");"
    if new in text:
        print("[skip] check_readonlyrootfs already patched")
        return text
    if old not in text:
        print("[warn] check_readonlyrootfs: expected original line not found, skipping")
        return text
    print("[ok]   check_readonlyrootfs: filesystem-type check generalized")
    return text.replace(old, new, 1)


def patch_rootfssize(text: str) -> str:
    marker = "# Check rootfs\nsub check_rootfssize"
    if marker not in text:
        print("[warn] check_rootfssize: sub not found, skipping")
        return text
    # Scope the "already patched" check to this sub's own body, not the
    # whole file - otherwise a match from check_tmpfssize's identical
    # "absolute_min_kb" text causes this function to be skipped wrongly.
    sub_body = text.split(marker, 1)[1]
    if "absolute_min_kb" in sub_body:
        print("[skip] check_rootfssize already patched")
        return text

    pattern = re.compile(
        r"if \( \$folderinfo\{available\}/\$folderinfo\{size\}\*100 > 10 \) \{\n"
        r"\s*\$result\{result\} = \"LoxBerry's RootFS has more than 10% free discspace.*?\n"
        r"\s*\$result\{status\} = '5';\n"
        r"\s*\}\n"
        r"\s*elsif \( \$folderinfo\{available\}/\$folderinfo\{size\}\*100 <= 5 \) \{\n"
        r"\s*\$result\{result\} = \"\$folderinfo\{mountpoint\} is below limit of 5% discspace.*?\n"
        r"\s*\$result\{status\} = '3';\n"
        r"\s*\} else \{\n"
        r"\s*\$result\{result\} = \"\$folderinfo\{mountpoint\} is below limit of 10% discspace.*?\n"
        r"\s*\$result\{status\} = '4';\n"
        r"\s*\}",
        re.DOTALL,
    )

    replacement = (
        "my $absolute_min_kb = " + str(ABSOLUTE_MIN_KB) + "; "
        "# 5 GB - large disks can have <10% free while tens of GB remain\n"
        "\t\tif ( $folderinfo{available}/$folderinfo{size}*100 > 10 "
        "|| $folderinfo{available} > $absolute_min_kb ) {\n"
        "\t\t\t$result{result} = \"LoxBerry's RootFS has more than 10% free discspace, "
        "or more than 5GB absolute free space (AVAL \""
        ".LoxBerry::System::bytes_humanreadable($folderinfo{available}, \"K\")"
        ".\"/SIZE \".LoxBerry::System::bytes_humanreadable($folderinfo{size}, \"K\").\").\";\n"
        "\t\t\t$result{status} = '5';\n"
        "\t\t}\n"
        "\t\telsif ( $folderinfo{available}/$folderinfo{size}*100 <= 5 "
        "&& $folderinfo{available} <= $absolute_min_kb ) {\n"
        "\t\t\t$result{result} = \"$folderinfo{mountpoint} is below limit of 5% discspace "
        "AND below 5GB absolute free space (AVAL \""
        ".LoxBerry::System::bytes_humanreadable($folderinfo{available}, \"K\")"
        ".\"/SIZE \".LoxBerry::System::bytes_humanreadable($folderinfo{size}, \"K\")"
        ".\"). Please reboot your LoxBerry.\";\n"
        "\t\t\t$result{status} = '3';\n"
        "\t\t} else {\n"
        "\t\t\t$result{result} = \"$folderinfo{mountpoint} is below limit of 10% discspace (AVAL \""
        ".LoxBerry::System::bytes_humanreadable($folderinfo{available}, \"K\")"
        ".\"/SIZE \".LoxBerry::System::bytes_humanreadable($folderinfo{size}, \"K\")"
        ".\"). Please reboot your LoxBerry.\";\n"
        "\t\t\t$result{status} = '4';\n"
        "\t\t}"
    )

    new_text, count = pattern.subn(replacement, text)
    if count == 0:
        print("[warn] check_rootfssize: expected if/elsif/else block not found, skipping")
        return text
    print(f"[ok]   check_rootfssize: absolute free-space floor added ({count} block replaced)")
    return new_text


def patch_tmpfssize(text: str) -> str:
    marker = "sub check_tmpfssize"
    if marker not in text:
        print("[warn] check_tmpfssize: sub not found, skipping")
        return text
    if "absolute_min_kb" in text.split(marker, 1)[1].split("sub check_rootfssize")[0]:
        print("[skip] check_tmpfssize already patched")
        return text

    pattern = re.compile(
        r"foreach my \$disk \(\@pathtc\) \{\n"
        r"\s*my %folderinfo = LoxBerry::System::diskspaceinfo\(\$disk\);\n"
        r"\s*next if\( \$folderinfo\{size\} eq \"0\" or "
        r"\(\$folderinfo\{available\}/\$folderinfo\{size\}\*100\) > 25 \);\n"
        r"\s*if \( \$folderinfo\{available\}/\$folderinfo\{size\}\*100 > 5 \) \{\n"
        r"\s*\$result\{result\} = \"\$folderinfo\{mountpoint\} is below limit of 25% discspace.*?\n"
        r"\s*\$result\{status\} = '4';\n"
        r"\s*\} else \{\n"
        r"\s*\$result\{result\} = \"\$folderinfo\{mountpoint\} is below limit of 5% discspace.*?\n"
        r"\s*\$result\{status\} = '3';\n"
        r"\s*\}\n"
        r"\s*\}",
        re.DOTALL,
    )

    replacement = (
        "foreach my $disk (@pathtc) {\n"
        "\t\t\tmy %folderinfo = LoxBerry::System::diskspaceinfo($disk);\n"
        "\t\t\tmy $absolute_min_kb = " + str(ABSOLUTE_MIN_KB) + "; "
        "# 5 GB - same floor as check_rootfssize\n"
        "\t\t\tnext if( $folderinfo{size} eq \"0\" "
        "or ($folderinfo{available}/$folderinfo{size}*100) > 25 "
        "or $folderinfo{available} > $absolute_min_kb );\n"
        "\t\t\tif ( $folderinfo{available}/$folderinfo{size}*100 > 5 ) {\n"
        "\t\t\t\t$result{result} = \"$folderinfo{mountpoint} is below limit of 25% discspace "
        "AND below 5GB absolute free space (AVAL \""
        ".LoxBerry::System::bytes_humanreadable($folderinfo{available}, \"K\")"
        ".\"/SIZE \".LoxBerry::System::bytes_humanreadable($folderinfo{size}, \"K\")"
        ".\"). Please reboot your LoxBerry.\";\n"
        "\t\t\t\t$result{status} = '4';\n"
        "\t\t\t} else {\n"
        "\t\t\t\t$result{result} = \"$folderinfo{mountpoint} is below limit of 5% discspace "
        "AND below 5GB absolute free space (AVAL \""
        ".LoxBerry::System::bytes_humanreadable($folderinfo{available}, \"K\")"
        ".\"/SIZE \".LoxBerry::System::bytes_humanreadable($folderinfo{size}, \"K\")"
        ".\"). Please reboot your LoxBerry.\";\n"
        "\t\t\t\t$result{status} = '3';\n"
        "\t\t\t}\n"
        "\t\t}"
    )

    new_text, count = pattern.subn(replacement, text)
    if count == 0:
        print("[warn] check_tmpfssize: expected foreach block not found, skipping")
        return text
    print(f"[ok]   check_tmpfssize: absolute free-space floor added ({count} block replaced)")
    return new_text


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/healthcheck.pl")
        sys.exit(1)

    target = Path(sys.argv[1])
    if not target.is_file():
        print(f"File not found: {target}")
        sys.exit(1)

    backup = target.with_suffix(target.suffix + ".bak")
    if not backup.exists():
        shutil.copy2(target, backup)
        print(f"[ok]   backup written to {backup}")
    else:
        print(f"[skip] backup already exists at {backup}, not overwriting")

    text = target.read_text()
    text = patch_readonlyrootfs(text)
    text = patch_tmpfssize(text)
    text = patch_rootfssize(text)
    target.write_text(text)
    print(f"[done] {target} patched")


if __name__ == "__main__":
    main()
