#!/bin/zsh

# Show a side-by-side diff between two files
#
# description: Side-by-side diff of two files
# filesOnly: true
# minFiles: 2
# maxFiles: 2
# showOutput: true

diff --minimal -u "$1" "$2"
exit 0
