#!/bin/sh
# po2json.sh — Convert .po files to JSON objects for web UI embedding.
#
# Usage: ./po2json.sh <po_file>
#   Outputs a JSON object with msgid->msgstr pairs (skipping empty msgstr).
#
# Usage: ./po2json.sh --all <i18n_dir>
#   Outputs a full TRANSLATIONS object: {"lang": {"key": "value", ...}, ...}
#
# Only standard POSIX tools are used (awk).

set -e

# Convert a single .po file to a JSON object
po_to_json() {
    awk '
    BEGIN {
        first = 1
        msgid = ""
        msgstr = ""
        in_msgid = 0
        in_msgstr = 0
        printf "{"
    }

    function flush_pair() {
        if (msgid != "" && msgstr != "" && msgid != "\"\"") {
            # Strip surrounding quotes and unescape
            gsub(/^"/, "", msgid)
            gsub(/"$/, "", msgid)
            gsub(/^"/, "", msgstr)
            gsub(/"$/, "", msgstr)
            if (msgid != "" && msgstr != "") {
                if (!first) printf ","
                # Output as JSON key:value — the strings are already escaped in .po format
                printf "\"%s\":\"%s\"", msgid, msgstr
                first = 0
            }
        }
        msgid = ""
        msgstr = ""
        in_msgid = 0
        in_msgstr = 0
    }

    /^#/ { next }
    /^[[:space:]]*$/ {
        flush_pair()
        next
    }

    /^msgid / {
        flush_pair()
        in_msgid = 1
        in_msgstr = 0
        sub(/^msgid /, "")
        # Handle multiline: strip quotes, accumulate
        gsub(/^"/, "", $0)
        gsub(/"[[:space:]]*$/, "", $0)
        msgid = $0
        next
    }

    /^msgstr / {
        in_msgstr = 1
        in_msgid = 0
        sub(/^msgstr /, "")
        gsub(/^"/, "", $0)
        gsub(/"[[:space:]]*$/, "", $0)
        msgstr = $0
        next
    }

    /^"/ {
        gsub(/^"/, "", $0)
        gsub(/"[[:space:]]*$/, "", $0)
        if (in_msgid) {
            msgid = msgid $0
        } else if (in_msgstr) {
            msgstr = msgstr $0
        }
        next
    }

    END {
        flush_pair()
        printf "}"
    }
    ' "$1"
}

# Extract language code from .po file header or filename
get_lang_from_file() {
    basename "$1" .po
}

if [ "$1" = "--all" ]; then
    i18n_dir="${2:-.}"
    printf "{"
    first_lang=1
    for po_file in "$i18n_dir"/*.po; do
        [ -f "$po_file" ] || continue
        lang=$(get_lang_from_file "$po_file")
        if [ "$first_lang" -eq 1 ]; then
            first_lang=0
        else
            printf ","
        fi
        printf "\"%s\":" "$lang"
        po_to_json "$po_file"
    done
    printf "}"
else
    if [ -z "$1" ]; then
        echo "Usage: $0 <po_file>" >&2
        echo "       $0 --all <i18n_dir>" >&2
        exit 1
    fi
    po_to_json "$1"
fi
