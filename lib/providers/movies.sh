#!/bin/sh
# lib/providers/movies.sh
# Movie & TV provider with IMDb metadata search, Archive.org feature films,
# direct embed resolution, and HD streaming with 1080p quality selection.

if [ -z "$LIB_DIR" ]; then
  _dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  [ -f "$_dir/../core.sh" ] && LIB_DIR="$_dir/.."
fi
if [ -n "$LIB_DIR" ] && [ -f "$LIB_DIR/core.sh" ]; then
  . "$LIB_DIR/core.sh"
  [ -f "$LIB_DIR/scrapers/imdb.sh" ] && . "$LIB_DIR/scrapers/imdb.sh"
  [ -f "$LIB_DIR/scrapers/archive_org.sh" ] && . "$LIB_DIR/scrapers/archive_org.sh"
  [ -f "$LIB_DIR/scrapers/vidsrc.sh" ] && . "$LIB_DIR/scrapers/vidsrc.sh"
  [ -f "$LIB_DIR/scrapers/yt_search.sh" ] && . "$LIB_DIR/scrapers/yt_search.sh"
fi

movies_search_and_play() {
  local query="$1" content_type="${2:-movie}" download_mode="$3"

  if [ -z "$query" ]; then
    local cat_label
    cat_label=$([ "$content_type" = "tv" ] && echo "TV Shows" || echo "Movies")
    printf "${C_CYN}  Search %s ❯${C_RST} " "$cat_label"
    read -r query
    [ -z "$query" ] && return
  fi

  local imdb_results
  imdb_results=$(spin_task "Searching IMDb metadata for '$query'..." imdb_search "$query")

  local title="" year="" imdb_id="" media_type="" stars=""

  if [ -n "$imdb_results" ]; then
    local selected_item
    selected_item=$(printf '%s\n' "$imdb_results" \
      | awk -F'\t' '{
          y = ($2 != "") ? " (" $2 ")" : ""
          t = ($4 != "") ? " [" $4 "]" : ""
          s = ($5 != "") ? " • " $5 : ""
          printf "%s%s%s%s\n", $1, y, t, s
        }' \
      | fzf_prompt "Select $content_type")

    if [ -n "$selected_item" ]; then
      local line
      line=$(printf '%s\n' "$imdb_results" | awk -F'\t' -v s="$selected_item" 'index(s, $1){print; exit}')
      title=$(printf '%s' "$line" | cut -f1)
      year=$(printf '%s' "$line" | cut -f2)
      imdb_id=$(printf '%s' "$line" | cut -f3)
      media_type=$(printf '%s' "$line" | cut -f4)
      stars=$(printf '%s' "$line" | cut -f5)
    fi
  fi

  # Fallback title if IMDb had no match or user skipped
  [ -z "$title" ] && title="$query"

  local season="" episode=""
  if [ "$content_type" = "tv" ] || [ "$media_type" = "TV series" ]; then
    printf "${C_CYN}  Season number (default 1) ❯${C_RST} "; read -r season
    season="${season:-1}"
    printf "${C_CYN}  Episode number (default 1) ❯${C_RST} "; read -r episode
    episode="${episode:-1}"
  fi

  local yt_suffix
  if [ -n "$season" ]; then
    yt_suffix="season $season episode $episode full episode HD"
  else
    yt_suffix=$([ -n "$year" ] && echo "$year full movie HD" || echo "full movie HD")
  fi

  local src_choice
  src_choice=$(printf "HD Stream (1080p / 4K / Best)\nArchive.org Cinema Vault (Classic & Public Domain)\n" \
    | fzf_prompt "Select Source for '$title'")

  case "$src_choice" in
    *Archive*)
      local arc_results
      arc_results=$(spin_task "Searching cinema archives for '$title'..." archive_search "$title")
      if [ -n "$arc_results" ]; then
        _movies_try_archive "$arc_results" "$download_mode" "$title" && return 0
      else
        warn "No cinema archive entries found. Switching to HD stream..."
      fi
      ;;
  esac

  _media_youtube_fallback "$title" "$download_mode" "$yt_suffix" "$content_type" "$year"
}

_movies_try_archive() {
  local results="$1" download_mode="$2" title="$3"

  while true; do
    local choice
    choice=$(printf '%s\n' "$results" | awk -F'\t' '{print $1}' | fzf_prompt "Archive.org Cinema (or ESC to skip to HD streams)")
    [ -z "$choice" ] && return 1

    local id
    id=$(printf '%s\n' "$results" | awk -F'\t' -v c="$choice" '$1==c{print $2; exit}')
    [ -z "$id" ] && return 1

    local episodes
    episodes=$(spin_task "Loading video tracks for $choice..." archive_episodes "$id")
    if [ -z "$episodes" ]; then
      warn "No playable video tracks found in this collection. Please select another or press ESC."
      continue
    fi

    local ep_file
    if [ $(printf '%s\n' "$episodes" | wc -l) -gt 1 ]; then
      local ep_choice
      ep_choice=$(printf '%s\n' "$episodes" | awk -F'\t' '{print $1}' | fzf_prompt "Select track ($choice)")
      [ -z "$ep_choice" ] && continue
      ep_file=$(printf '%s\n' "$episodes" | awk -F'\t' -v ec="$ep_choice" '$1==ec{print $3; exit}')
    else
      ep_file=$(printf '%s\n' "$episodes" | head -n 1 | cut -f3)
    fi
    [ -z "$ep_file" ] && continue

    local stream_url
    stream_url=$(archive_stream "$id" "$ep_file")

    hist_add "movies" "$choice" ""

    if [ "$download_mode" = "1" ]; then
      download_url "$stream_url" "$choice"
    else
      play_url "$stream_url" "$choice"
    fi
    return 0
  done
}


_media_youtube_fallback() {
  local query="$1" download_mode="$2" suffix="${3:-full movie HD}" content_type="${4:-movie}" year="${5:-}"
  local yt_results
  yt_results=$(spin_task "Searching high-definition streaming sources..." yt_search_list "$query" 25 "$suffix")
  [ -z "$yt_results" ] && yt_results=$(spin_task "Searching streaming archives..." yt_search_list "$query" 25)
  [ -z "$yt_results" ] && { err "No streams found for: $query"; return 1; }

  local selected
  selected=$(printf '%s\n' "$yt_results" \
    | awk -F'\t' '{print $1}' | fzf_prompt "Select $content_type stream")
  [ -z "$selected" ] && return

  local yt_url
  yt_url=$(printf '%s\n' "$yt_results" | awk -F'\t' -v s="$selected" '$1==s{print $2; exit}')
  [ -z "$yt_url" ] && return

  local quality
  quality=$(prompt_quality "Select Stream Quality")
  EVERY_CLI_QUALITY="$quality"

  if [ "$download_mode" = "1" ]; then
    yt_download "$yt_url"
  else
    hist_add "$content_type" "$selected" ""
    play_url "$yt_url" "$selected"


    # Post-playback menu
    while [ -t 0 ]; do
      local action
      action=$(printf 'replay\nsearch again\nchange quality\nquit' \
        | fzf_prompt "Stream — $selected")
      case "$action" in
        replay)
          play_url "$yt_url" "$selected"
          ;;
        "search again")
          movies_search_and_play "" "$content_type" "$download_mode"
          break
          ;;
        "change quality")
          quality=$(prompt_quality "Select Stream Quality")
          EVERY_CLI_QUALITY="$quality"
          play_url "$yt_url" "$selected"
          ;;
        *)
          break
          ;;
      esac
    done
  fi
}
