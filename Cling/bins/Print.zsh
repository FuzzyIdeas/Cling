#!/bin/zsh

# Send PDF documents to the default printer
#
# description: Print PDFs on the default printer
# extensions: pdf
# filesOnly: true
# sequential: true

for f in "$@"; do
    lpr "$f"
    echo "Sent to printer: $(basename "$f")"
done
