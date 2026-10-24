#!/bin/sh
# lib/scrapers/hianime.sh
# HiAnime scraper matching ani-cli v5.1.6 architecture (GPL-3.0)

HIANIME_BASE="https://hianime.at"
HIANIME_SEARCH="${HIANIME_BASE}/search?keyword=%s"
HIANIME_EPISODES="${HIANIME_BASE}/api/theme/episode/list/%s"
HIANIME_SERVERS="${HIANIME_BASE}/api/theme/episode/servers?episodeId=%s"

# Cross-platform base64 decoding (GNU, BSD, Windows Git Bash, openssl)
b64_decode() {
  printf '%s\n' "$1" | base64 -d 2>/dev/null || \
  printf '%s\n' "$1" | base64 -D 2>/dev/null || \
  printf '%s\n' "$1" | openssl base64 -d -A 2>/dev/null
}

# The embed page ships its config as base64(json XOR "otaku-embed-v1")
# Runs in a subshell so positional parameters can rotate XOR key bytes
deobfuscate_blob() (
  _bytes="$(b64_decode "$1" | od -v -An -tu1)"
  set -- 111 116 97 107 117 45 101 109 98 101 100 45 118 49
  _output=""
  for _byte in $_bytes; do
    _char=$((_byte ^ $1))
    _output="${_output}\\0$((_char / 64))$(((_char / 8) % 8))$((_char % 8))"
    set -- "$@" "$1"
    shift
  done
  printf "%b" "$_output"
)

# Search HiAnime and output: anime_slug \t title
hianime_search() {
  local query="$1"
  local encoded_query
  encoded_query=$(printf '%s' "$query" | sed 's/ /+/g')

  local page
  page=$(do_curl -L --max-time 10 "${HIANIME_BASE}/search?keyword=${encoded_query}")
  [ -z "$page" ] && return 1

  # Cut off sidebar before flattening page into items
  printf '%s' "$page" \
    | sed '/id="main-sidebar"/,$d' \
    | tr '\n' ' ' \
    | sed 's|<div class="film-detail">|\n<div class="film-detail">|g' \
    | sed -nE 's|.*<h3 class="film-name">[[:space:]]*<a href="[^"]*/([^"/]*)"[[:space:]]*title="([^"]*)".*|\1\t\2|p' \
    | sed -e "s|&#039;|'|g" -e 's|&quot;|"|g' -e "s|&amp;|\&|g"
}

# Get episode list for an anime: ep_id \t ep_number
hianime_episodes() {
  local anime_slug="$1"
  local numeric_id="${anime_slug##*-}"

  local page
  page=$(do_curl -L --max-time 10 "${HIANIME_BASE}/api/theme/episode/list/${numeric_id}")
  [ -z "$page" ] && return 1

  printf '%s' "$page" \
    | sed 's|\\||g; s|ep-item|\nep-item|g' \
    | sed -nE "s|.*data-number=\"([^\"]*)\".*data-id=\"([0-9]+)\".*/watch/${anime_slug}[?]ep=.*|\\2\t\\1|p"
}

# Resolve stream URL, referer, and subtitles: outputs "stream_url \t referer \t subtitle_url"
hianime_get_stream() {
  local ep_id="$1" lang="${2:-sub}" quality="${3:-best}"

  local servers_html
  servers_html=$(do_curl -L --max-time 10 "${HIANIME_BASE}/api/theme/episode/servers?episodeId=${ep_id}" \
    | sed 's|\\"|"|g; s|server-item|\nserver-item|g')
  [ -z "$servers_html" ] && return 1

  # Extract ZokoAnime server hash for the requested mode (sub/dub)
  local hash
  hash=$(printf '%s\n' "$servers_html" \
    | sed -nE 's|.*data-type="'"$lang"'".*data-server-name="ZokoAnime".*data-hash="([^"]*)".*|\1|p' \
    | head -n 1)

  # Fallback to sub if dub is unavailable
  if [ -z "$hash" ] && [ "$lang" = "dub" ]; then
    hash=$(printf '%s\n' "$servers_html" \
      | sed -nE 's|.*data-type="sub".*data-server-name="ZokoAnime".*data-hash="([^"]*)".*|\1|p' \
      | head -n 1)
  fi

  [ -z "$hash" ] && return 1

  local embed_url
  embed_url=$(b64_decode "$hash")
  [ -z "$embed_url" ] && return 1

  local refr
  refr="$(printf '%s' "$embed_url" | sed -E 's|^(https?://[^/]*).*|\1/|')"

  local embed_page
  embed_page=$(do_curl -L --max-time 10 "$embed_url")
  [ -z "$embed_page" ] && return 1

  local blob
  blob=$(printf '%s' "$embed_page" | sed -nE 's|.*window\.__P="([^"]*)".*|\1|p')
  [ -z "$blob" ] && return 1

  local json
  json=$(deobfuscate_blob "$blob")
  [ -z "$json" ] && return 1

  local master_m3u8
  master_m3u8=$(printf '%s' "$json" | sed -nE 's|.*"src":"([^"]*\.m3u8[^"]*)".*|\1|p')
  [ -z "$master_m3u8" ] && return 1

  local sub_url
  sub_url=$(printf '%s' "$json" \
    | sed 's|.*"subtitles":\[||; s|}\].*||; s|},{|\n{|g' \
    | grep -m 1 '"default":true' \
    | sed -nE 's|.*"src":"([^"]*)".*|\1|p')

  # Parse quality playlist if available
  local chosen_stream="$master_m3u8"
  local playlist
  playlist=$(do_curl -L -e "$refr" --max-time 10 "$master_m3u8" 2>/dev/null)

  if [ -n "$playlist" ] && printf '%s\n' "$playlist" | grep -q 'EXT-X-STREAM'; then
    local links
    links=$(printf '%s\n' "$playlist" \
      | sed 's|^#EXT-X-STREAM.*x||g; s|,.*|p|g; /^#/d; $!N; s|\n| >|;/EXT-X-I-FRAME/d' \
      | sed "\|>https*://|!s|>|>${master_m3u8%/*}/|" \
      | sort -g -r -s)

    local picked=""
    case "$quality" in
      best)  picked=$(printf '%s\n' "$links" | head -n 1) ;;
      worst) picked=$(printf '%s\n' "$links" | grep -E '^[0-9]{3,4}' | tail -n 1) ;;
      1080|720|480|360)
        picked=$(printf '%s\n' "$links" | grep -m 1 "${quality}p")
        [ -z "$picked" ] && picked=$(printf '%s\n' "$links" | head -n 1)
        ;;
      *) picked=$(printf '%s\n' "$links" | head -n 1) ;;
    esac

    if [ -n "$picked" ]; then
      local extracted_url
      extracted_url=$(printf '%s' "$picked" | cut -d'>' -f2)
      [ -n "$extracted_url" ] && chosen_stream="$extracted_url"
    fi
  fi

  printf '%s\t%s\t%s\n' "$chosen_stream" "$refr" "$sub_url"
}
