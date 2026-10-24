#!/bin/sh
# lib/scrapers/imdb.sh
# IMDb suggestions API — instant movie & TV series metadata search

IMDB_SUGGEST_URL="https://v3.sg.media-imdb.com/suggestion/x"

imdb_search() {
  local query="$1"
  local slug
  slug=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/_/g' -e 's/__*/_/g' -e 's/^_//' -e 's/_$//')
  [ -z "$slug" ] && return 1

  local json
  json=$(do_curl --connect-timeout 5 --max-time 8 "${IMDB_SUGGEST_URL}/${slug}.json")
  [ -z "$json" ] && return 1

  printf '%s' "$json" | awk '
    BEGIN { RS="\"id\":\"" }
    NR > 1 {
      id = $0; sub(/".*/, "", id)
      title = ""
      if (match($0, /"l":"([^"]*)"/, m)) title = m[1]
      year = ""
      if (match($0, /"y":([0-9]+)/, m)) year = m[1]
      type = ""
      if (match($0, /"q":"([^"]*)"/, m)) type = m[1]
      stars = ""
      if (match($0, /"s":"([^"]*)"/, m)) stars = m[1]

      if (id ~ /^tt/ && title != "") {
        gsub(/\\"/, "\"", title)
        gsub(/\\"/, "\"", stars)
        printf "%s\t%s\t%s\t%s\t%s\n", title, year, id, type, stars
      }
    }
  '
}
