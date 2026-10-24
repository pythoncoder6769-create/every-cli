#!/bin/sh
# lib/scrapers/yt_search.sh
# YouTube search via yt-dlp — UNIVERSAL FAST SEARCH & FALLBACK

yt_search_list() {
  local query="$1" max="${2:-15}" suffix="${3:-}"
  local full_query="$query $suffix"
  local tab
  tab=$(printf '\t')

  # Using --flat-playlist for 10x faster search without querying each video individually
  yt-dlp \
    --no-warnings \
    --flat-playlist \
    --skip-download \
    --print "%(title)s${tab}%(url)s${tab}%(duration_string)s${tab}%(view_count)s" \
    "ytsearch${max}:${full_query}" \
    2>/dev/null \
  | tr -d '\r' \
  | awk -F'\t' -v tab="$tab" '{
      views = $4+0
      if (views >= 1000000) views_fmt = sprintf("%.1fM views", views/1000000)
      else if (views >= 1000) views_fmt = sprintf("%.0fK views", views/1000)
      else if (views > 0) views_fmt = views " views"
      else views_fmt = ""
      dur = ($3 != "" && $3 != "NA") ? $3 : "--:--"
      if (views_fmt != "") dur = dur ", " views_fmt
      printf "%s [%s]%s%s\n", $1, dur, tab, $2
    }'
}

yt_stream() {
  local url="$1"
  # Return the original YouTube URL so mpv can handle native high-def audio+video merging
  printf '%s' "$url"
}

yt_download() {
  local url="$1"
  local out_dir="${EVERY_CLI_DOWNLOAD_DIR:-$HOME/Videos/every-cli}/youtube"
  mkdir -p "$out_dir"
  local quality="${EVERY_CLI_QUALITY:-best}"
  local fmt
  case "$quality" in
    1080) fmt="bestvideo[height<=1080]+bestaudio/best[height<=1080]/best" ;;
    720)  fmt="bestvideo[height<=720]+bestaudio/best[height<=720]/best" ;;
    480)  fmt="bestvideo[height<=480]+bestaudio/best[height<=480]/best" ;;
    360)  fmt="bestvideo[height<=360]+bestaudio/best[height<=360]/best" ;;
    *)    fmt="bestvideo+bestaudio/best" ;;
  esac

  info "Downloading to: $out_dir"
  yt-dlp --no-warnings \
    -o "$out_dir/%(uploader)s - %(title)s.%(ext)s" \
    --format "$fmt" \
    --merge-output-format mp4 \
    --write-thumbnail \
    --embed-thumbnail \
    "$url"
}
