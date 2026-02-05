#!/bin/zsh

# Show disk usage breakdown using dust
#
# description: Visual disk usage breakdown
# dirsOnly: true
# showOutput: true

"$CLING_DUST" --reverse --depth 2 "$@"
