#!/bin/sh
# lib/scrapers/music_api.sh
# Music search via YouTube (audio-only, best quality) with MusicBrainz metadata enrichment
# Primary: YouTube yt-dlp search (always works, 320kbps opus/m4a via bestaudio)
# Secondary: MusicBrainz metadata lookup for artist/album info

MUSICBRAINZ_BASE="https://musicbrainz.org/ws/2"

# ── YouTube music search (primary engine) ─────────────────────────────────────
music_yt_search() {
  local query="$1" max="${2:-20}"
  local tab
  tab=$(printf '\t')

  yt-dlp \
    --no-warnings \
    --extractor-args "youtube:player_client=android" \
    --flat-playlist \
    --skip-download \
    --print "%(title)s${tab}%(url)s${tab}%(duration_string)s${tab}%(view_count)s${tab}%(channel)s" \
    "ytsearch${max}:${query}" \
    2>/dev/null \
  | tr -d '\r' \
  | awk -F'\t' -v tab="$tab" '{
      views = $4+0
      if (views >= 1000000) views_fmt = sprintf("%.1fM views", views/1000000)
      else if (views >= 1000) views_fmt = sprintf("%.0fK views", views/1000)
      else if (views > 0) views_fmt = views " views"
      else views_fmt = ""
      dur = ($3 != "" && $3 != "NA") ? $3 : "--:--"
      ch = ($5 != "" && $5 != "NA") ? $5 : ""
      gsub(/ - Topic$| VEVO$| Official$| Records$/, "", ch)
      meta = dur
      if (ch != "") meta = meta " • " ch
      if (views_fmt != "") meta = meta ", " views_fmt
      printf "%s [%s]%s%s%s%s%s%s\n", $1, meta, tab, $2, tab, $1, tab, ch
    }'
}

# ── YouTube audio-only download ───────────────────────────────────────────────
music_yt_download() {
  local url="$1"
  local out_dir="${EVERY_CLI_DOWNLOAD_DIR:-$HOME/Music/every-cli}"
  mkdir -p "$out_dir"

  info "Downloading audio to: $out_dir"
  yt-dlp --no-warnings \
    --extractor-args "youtube:player_client=android" \
    -x --audio-format mp3 --audio-quality 0 \
    --embed-thumbnail \
    --add-metadata \
    -o "$out_dir/%(artist)s - %(title)s.%(ext)s" \
    "$url"
}

# ── MusicBrainz metadata search (optional enrichment) ─────────────────────────
musicbrainz_search() {
  local query="$1" limit="${2:-10}"
  local encoded_query
  encoded_query=$(printf '%s' "$query" | sed 's/ /+/g')

  do_curl \
    -H "Accept: application/json" \
    -A "every-cli/1.0 (https://github.com/pythoncoder6769-create/every-cli)" \
    "${MUSICBRAINZ_BASE}/recording?query=${encoded_query}&fmt=json&limit=${limit}" \
  | awk '
    BEGIN { RS=",\"id\":\""; FS="\"" }
    NR > 1 {
      id = $1
      title = ""; artist = ""; length = ""
      for (i=1; i<=NF; i++) {
        if ($i == "title" && $(i+1) == ":") title = $(i+2)
        if ($i == "name" && $(i+1) == ":" && artist == "") artist = $(i+2)
        if ($i == "length" && $(i+1) == ":") length = $(i+2)
      }
      if (title != "" && artist != "") {
        mins = int(length / 60000)
        secs = int((length % 60000) / 1000)
        printf "%s - %s [%d:%02d]\n", artist, title, mins, secs
      }
    }
  ' 2>/dev/null
}
