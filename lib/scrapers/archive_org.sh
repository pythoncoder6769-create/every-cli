#!/bin/sh
# lib/scrapers/archive_org.sh
# Scraper for Archive.org movies and cartoon series (direct MP4 / H.264 streams)

ARCHIVE_SEARCH_API="https://archive.org/advancedsearch.php"
ARCHIVE_METADATA_API="https://archive.org/metadata"

archive_search() {
  local query="$1"
  local encoded
  encoded=$(printf '%s' "$query" | sed 's/ /+/g')

  local url="${ARCHIVE_SEARCH_API}?q=title:(%22${encoded}%22)+AND+mediatype:(movies)&fl[]=identifier,title,downloads&sort[]=downloads+desc&rows=20&output=json"

  local json
  json=$(do_curl --connect-timeout 6 --max-time 12 "$url")
  [ -z "$json" ] && return 1

  # Parse docs from JSON
  printf '%s' "$json" | awk '
    BEGIN { RS="\"identifier\":\"" }
    NR > 1 {
      id = $0; sub(/".*/, "", id)
      title = ""
      if (match($0, /"title":"([^"]*)"/, m)) {
        title = m[1]
      }
      if (title == "") title = id
      gsub(/\\u0026/, "\\&", title)
      gsub(/\\"/, "\"", title)
      if (id != "") {
        printf "%s\t%s\n", title, id
      }
    }
  '
}

archive_episodes() {
  local identifier="$1"
  local url="${ARCHIVE_METADATA_API}/${identifier}/files"

  local json
  json=$(do_curl --connect-timeout 6 --max-time 12 "$url")
  [ -z "$json" ] && return 1

  printf '%s' "$json" | awk -v id="$identifier" '
    BEGIN { RS="\"name\":\"" }
    NR > 1 {
      file = $0; sub(/".*/, "", file)
      if (file ~ /\.(mp4|mkv|m4v|avi|webm)$/ && file !~ /_sample\./ && file !~ /_trailer\./ && file !~ /_512kb\./) {
        title = file
        sub(/.*\//, "", title)
        sub(/\.[^.]*$/, "", title)
        gsub(/_/, " ", title)
        gsub(/%20/, " ", title)
        gsub(/\./, " ", title)
        gsub(/^[ \t]+|[ \t]+$/, "", title)
        printf "%s\t%s\t%s\n", title, id, file
      }
    }
  ' | sort -u -t$'\t' -k1,1
}

archive_stream() {
  local identifier="$1" filename="$2"
  # URL encode spaces and special characters for the filename
  local encoded_file
  encoded_file=$(printf '%s' "$filename" | sed -e 's/ /%20/g' -e 's/\[/%5B/g' -e 's/\]/%5D/g' -e 's/,/%2C/g')
  printf 'https://archive.org/download/%s/%s' "$identifier" "$encoded_file"
}
