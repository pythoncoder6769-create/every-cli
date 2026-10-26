#!/bin/sh
# lib/scrapers/vidsrc.sh
# VidSrc.to / VidSrc.me — free movie + TV embeds resolved via yt-dlp

VIDSRC_BASE="https://vidsrc.to"
VIDSRC_ME="https://vidsrc.me"

vidsrc_search() {
  local query="$1"
  local encoded_query
  encoded_query=$(printf '%s' "$query" | sed 's/ /+/g')

  do_curl \
    -H "Referer: $VIDSRC_BASE/" \
    "$VIDSRC_BASE/search/$encoded_query" \
  | grep -o 'data-id="[^"]*"[^>]*title="[^"]*"[^>]*data-year="[^"]*"[^>]*data-type="[^"]*"' \
  | sed 's/data-id="\([^"]*\)"[^>]*title="\([^"]*\)"[^>]*data-year="\([^"]*\)"[^>]*data-type="\([^"]*\)"/\1|\2|\3|\4/'
}

vidsrc_movie_embed() {
  local imdb_id="$1"
  printf '%s/embed/movie/%s' "$VIDSRC_BASE" "$imdb_id"
}

vidsrc_episode_embed() {
  local imdb_id="$1" season="$2" episode="$3"
  printf '%s/embed/tv/%s/%s-%s' "$VIDSRC_BASE" "$imdb_id" "$season" "$episode"
}

vidsrc_resolve() {
  local embed_url="$1"
  local stream

  stream=$(yt-dlp --no-warnings -g \
    --format "bestvideo+bestaudio/best" \
    --add-header "Referer:$VIDSRC_BASE/" \
    "$embed_url" 2>/dev/null | tr -d '\r')

  [ -n "$stream" ] && printf '%s' "$stream" && return 0
  return 1
}
