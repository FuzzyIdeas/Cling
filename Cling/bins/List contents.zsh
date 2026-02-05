#!/bin/zsh

# List the contents of any archive file supported by 7-Zip

# File paths are passed as arguments to the script
# The first file path is $1, the second is $2, and so on
# The number of arguments is stored in $#
# The arguments are stored in $@ as an array
#
# description:  List the contents of archive files

# Allow script to only appear as an option on files with specific extensions
# extensions: 7z bz2 bzip2 tbz2 tbz gz gzip tgz tar wim swm esd xz txz zip zipx jar xpi odt ods docx xlsx epub apfs apm ar a deb lib arj b64 cab chm chw chi chq msi msp doc xls ppt cpio cramfs dmg ext ext2 ext3 ext4 img fat img hfs hfsx hxs hxi hxr hxq hxw lit ihex iso img lzh lha lzma mbr mslz mub nsis ntfs img mbr rar r00 rpm ppmd qcow qcow2 qcow2c 001 squashfs udf iso img scap uefif vdi vhd vhdx vmdk xar pkg z taz zst tzst

# Make Cling show the output of the script after it finishes executing
# showOutput: true

extract_archive_paths() {
    local archive="$1"

    "$CLING_SEVEN_ZIP" l -slt -bso0 "$archive" | awk '
        function emit(p) {
            gsub(/\/+$/, "", p)
            if (p != "") {
                print p
            }
        }

        /^Path = / {
            path = substr($0, 8)
        }

        # Most archive handlers emit Folder = +/- for entries.
        /^Folder = / {
            if (path != "") {
                emit(path)
            }
            path = ""
        }

        # Filesystem-based images (APFS, etc.) emit Mode instead of Folder.
        /^Mode = / {
            if (path != "") {
                emit(path)
            }
            path = ""
        }
    '
}

print_tree() {
    awk '
        {
            if ($0 != "") {
                paths[++n] = $0
            }
        }

        function min(a, b) {
            return a < b ? a : b
        }

        function common_prefix(a, aN, b, bN,   i, m) {
            m = min(aN, bN)
            for (i = 1; i <= m; i++) {
                if (a[i] != b[i]) {
                    return i - 1
                }
            }
            return m
        }

        function same_prefix(a, b, len,   i) {
            for (i = 1; i <= len; i++) {
                if (a[i] != b[i]) {
                    return 0
                }
            }
            return 1
        }

        END {
            if (n == 0) {
                exit
            }

            for (idx = 1; idx <= n; idx++) {
                curN = split(paths[idx], cur, "/")

                if (idx == 1) {
                    prevN = 0
                } else {
                    prevN = split(paths[idx - 1], prev, "/")
                }

                shared = common_prefix(cur, curN, prev, prevN)

                if (idx < n) {
                    nextN = split(paths[idx + 1], nextParts, "/")
                } else {
                    nextN = 0
                }

                for (level = shared + 1; level <= curN; level++) {
                    prefix = ""

                    for (depth = 1; depth < level; depth++) {
                        has_more = (idx < n && depth <= nextN && same_prefix(cur, nextParts, depth))
                        prefix = prefix (has_more ? "|  " : "   ")
                    }

                    has_sibling = (idx < n && same_prefix(cur, nextParts, level - 1) && (level > nextN || cur[level] != nextParts[level]))
                    connector = has_sibling ? "+- " : "\\- "
                    print prefix connector cur[level]
                }
            }
        }
    '
}

for file in "$@"; do
    echo "${file:t}"

    extract_archive_paths "$file" | LC_ALL=C sort -u | print_tree

    echo
done
