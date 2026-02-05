#!/bin/zsh

# Compare two directories using treediff
#
# description: Compare two directory trees
# dirsOnly: true
# minFiles: 2
# maxFiles: 2
# showOutput: true

TREE_BIN="$CLING_TREE" "$CLING_TREEDIFF" "$1" "$2"
