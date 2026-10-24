#!/bin/sh
# lib/scrapers/supercartoons.sh
# Scraper for SuperCartoons.net — 1500+ classic & retro cartoons in direct MP4

SUPERCARTOONS_BASE="https://www.supercartoons.net"

supercartoons_search() {
  local query="$1"
  local encoded
  encoded=$(printf '%s' "$query" | sed 's/ /+/g')

  local html
  html=$(do_curl --connect-timeout 6 --max-time 12 "$SUPERCARTOONS_BASE/?s=$encoded")
  [ -z "$html" ] && return 1

  printf '%s' "$html" | awk '
    /href="https:\/\/www.supercartoons.net\/(cartoon|serie)\/[^"]+"/ {
      match($0, /href="(https:\/\/www.supercartoons.net\/(cartoon|serie)\/[^"]+)"/, m)
      if (m[1] != "") last_url = m[1]
    }
    /<h3 class="title">/ {
      title = $0
      gsub(/.*<h3 class="title">/, "", title)
      gsub(/<.*/, "", title)
      gsub(/&#8217;/, "'\''", title)
      gsub(/&amp;/, "\\&", title)
      gsub(/^[ \t]+|[ \t]+$/, "", title)
      if (last_url != "" && title != "") {
        type = (index(last_url, "/serie/") > 0) ? "series" : "short"
        printf "%s\t%s\t%s\n", title, last_url, type
        last_url = ""
      }
    }
  '
}

supercartoons_episodes() {
  local serie_url="$1"
  local html
  html=$(do_curl --connect-timeout 6 --max-time 12 "$serie_url")
  [ -z "$html" ] && return 1

  printf '%s' "$html" | awk '
    /href="https:\/\/www.supercartoons.net\/cartoon\/[^"]+"/ {
      match($0, /href="(https:\/\/www.supercartoons.net\/cartoon\/[^"]+)"/, m)
      if (m[1] != "") last_url = m[1]
    }
    /<h3 class="title">/ {
      title = $0
      gsub(/.*<h3 class="title">/, "", title)
      gsub(/<.*/, "", title)
      gsub(/&#8217;/, "'\''", title)
      gsub(/&amp;/, "\\&", title)
      gsub(/^[ \t]+|[ \t]+$/, "", title)
      if (last_url != "" && title != "") {
        printf "%s\t%s\n", title, last_url
        last_url = ""
      }
    }
  '
}

supercartoons_stream() {
  local cartoon_url="$1"
  local html
  html=$(do_curl --connect-timeout 6 --max-time 12 "$cartoon_url")
  [ -z "$html" ] && return 1

  local mp4_url
  mp4_url=$(printf '%s' "$html" | grep -oE 'https?://[a-zA-Z0-9.-]+\.supercartoons\.net/[^"'\''<> ]+\.mp4' | head -n 1)

  if [ -n "$mp4_url" ]; then
    printf '%s' "$mp4_url"
    return 0
  fi
  return 1
}
