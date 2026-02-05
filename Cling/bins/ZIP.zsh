#!/bin/zsh

# Archive selected files into a single ZIP file and open it in Finder

# File paths are passed as arguments to the script
# The first file path is $1, the second is $2, and so on
# The number of arguments is stored in $#
# The arguments are stored in $@ as an array
#
# description:  Archive files into a single ZIP file and show it in Finder


# Create a temporary directory to store the archive
archive=$(mktemp -d -t cling-archive)

# Combine all the files into a single archive
"$CLING_SEVEN_ZIP" a "$archive/archive.zip" "$@"

# Open the archive in Finder
open "$archive"
