# Pre-consume script for Paperless-ngx: drop fully blank pages from scanned
# PDFs before they are OCR'd and stored.
#
# This is the script the old (Arch, saver CT 110) install kept at
# /usr/bin/del_empty_pages.sh, ported unchanged apart from `nawk` -> `awk`.
# It is wired up through nixpaperless/paperless.nix, which wraps it in a store
# derivation that provides bash plus file/ghostscript/poppler/qpdf on PATH.
#
# Paperless runs it with the document under $DOCUMENT_WORKING_PATH and rewrites
# the file in place; pages whose printed ink coverage stays under THRESHOLD are
# removed.  Exit 0 without touching the file for anything that is not a PDF.
#set -x -e -o pipefail
set -e -o pipefail
export LC_ALL=C

#IN="$1"
IN="$DOCUMENT_WORKING_PATH"

# Check for PDF format
TYPE=$(file -b "$IN")

if [ "${TYPE%%,*}" != "PDF document" ]; then
  >&2 echo "Skipping $IN - non PDF [$TYPE]."
  exit 0
fi

# PDF file - proceed

#PAGES=$(pdfinfo "$IN" | grep ^Pages: | tr -dc '0-9')
PAGES=$(pdfinfo "$IN" | awk '/Pages:/ {print $2}')

>&2 echo Total pages $PAGES


# Threshold for HP scanners
# THRESHOLD=1
# Threshold for Lexmar MC2425
THRESHOLD=0.9


non_blank() {
  for i in $(seq 1 $PAGES) ; do
    PERCENT=$(gs -o -  -dFirstPage=${i} -dLastPage=${i} -sDEVICE=ink_cov "${IN}" | grep CMYK | awk 'BEGIN { sum=0; } {sum += $1 + $2 + $3 + $4;} END {  printf "%.5f\n", sum } ')
    >&2 echo -n "Color-sum in page $i is $PERCENT: "
    if awk "BEGIN { exit !($PERCENT > $THRESHOLD) }"; then
      echo $i
      >&2 echo "Page added to document"
    else
      >&2 echo "Page removed from document"
    fi
  done
}

NON_BLANK=$(non_blank)

if [ -n "$NON_BLANK" ]; then
  NON_BLANK=$(echo $NON_BLANK  | tr ' ' ",")
  qpdf "$IN" --warning-exit-0 --replace-input --pages . $NON_BLANK --
fi
