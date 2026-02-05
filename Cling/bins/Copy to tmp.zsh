#!/bin/zsh

# Copy selected files to a temporary folder and open it in Finder

# File paths are passed as arguments to the script
# The first file path is $1, the second is $2, and so on
# The number of arguments is stored in $#
# The arguments are stored in $@ as an array
#
# description:  Copy files to a temporary folder and show it in Finder

# Create a temporary directory
dir=$(mktemp -d -t cling)

# Copy the files to the temporary directory using rsync to preserve file metadata
# rsync options used: -a: archive mode, -v: verbose, -z: compress, -P: progress
rsync -avzP "$@" "$dir/"

# Message that will appear in the Cling output panel
echo "Copied to $dir"

# Copy the temporary directory path to the clipboard
echo -n "$dir" | pbcopy

# Open the directory in Finder
open "$dir"
