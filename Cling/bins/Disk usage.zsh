#!/bin/zsh

# Show disk usage breakdown using dust
#
# description: Visual disk usage breakdown
# key: u
# dirsOnly: true
# showOutput: true

"$CLING_DUST" --reverse --depth 2 "$@"
