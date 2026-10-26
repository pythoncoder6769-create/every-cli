#!/bin/sh
# lib/providers/cartoons.sh
# Cartoon provider featuring SuperCartoons (1500+ retro cartoons in direct MP4),
# Archive.org complete series, HiAnime 1080p animation, and YouTube HD fallback.

if [ -z "$LIB_DIR" ]; then
  _dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  [ -f "$_dir/../core.sh" ] && LIB_DIR="$_dir/.."
fi
if [ -n "$LIB_DIR" ] && [ -f "$LIB_DIR/core.sh" ]; then
  . "$LIB_DIR/core.sh"
  [ -f "$LIB_DIR/scrapers/supercartoons.sh" ] && . "$LIB_DIR/scrapers/supercartoons.sh"
  [ -f "$LIB_DIR/scrapers/archive_org.sh" ] && . "$LIB_DIR/scrapers/archive_org.sh"
  [ -f "$LIB_DIR/scrapers/hianime.sh" ] && . "$LIB_DIR/scrapers/hianime.sh"
  [ -f "$LIB_DIR/scrapers/yt_search.sh" ] && . "$LIB_DIR/scrapers/yt_search.sh"
fi

cartoons_search_and_play() {
  local query download_mode="$2"

  if [ -n "$1" ]; then
    query="$1"
  else
    printf "${C_CYN}  Search Cartoons ❯${C_RST} "
    read -r query
    [ -z "$query" ] && return
  fi

  # Source 1: SuperCartoons (1500+ classic & retro cartoons)
  local sc_results
  sc_results=$(spin_task "Searching SuperCartoons for '$query'..." supercartoons_search "$query")
  if [ -n "$sc_results" ]; then
    _cartoons_play_supercartoons "$sc_results" "$download_mode" && return 0
  fi

  # Source 2: Archive.org Complete Cartoon Series
  local arc_results
  arc_results=$(spin_task "Searching Archive.org series collections for '$query'..." archive_search "$query")
  if [ -n "$arc_results" ]; then
    _cartoons_play_archive "$arc_results" "$download_mode" "$query" && return 0
  fi

  # Source 3: HiAnime Western & Anime Animation
  local hi_results
  hi_results=$(spin_task "Searching HiAnime animation for '$query'..." hianime_search "$query")
  if [ -n "$hi_results" ]; then
    _cartoons_play_hianime "$hi_results" "$download_mode" && return 0
  fi

  # Source 4: YouTube Full Episode Archive
  _cartoons_youtube_fallback "$query" "$download_mode"
}

_cartoons_play_supercartoons() {
  local results="$1" download_mode="$2"

  local choice
  choice=$(printf '%s\n' "$results" \
    | awk -F'\t' '{printf "%s [%s]\n", $1, $3}' \
    | fzf_prompt "SuperCartoons (1500+ direct MP4s)")
  [ -z "$choice" ] && return 1

  local selected_line
  selected_line=$(printf '%s\n' "$results" | awk -F'\t' -v c="$choice" 'index(c, $1){print; exit}')
  local title url type
  title=$(printf '%s' "$selected_line" | cut -f1)
  url=$(printf '%s' "$selected_line" | cut -f2)
  type=$(printf '%s' "$selected_line" | cut -f3)

  local stream_url="" ep_title="$title"

  if [ "$type" = "series" ]; then
    local episodes
    episodes=$(spin_task "Loading episode list for '$title'..." supercartoons_episodes "$url")
    [ -z "$episodes" ] && return 1

    local ep_choice
    ep_choice=$(printf '%s\n' "$episodes" | awk -F'\t' '{print $1}' | fzf_prompt "Select episode ($title)")
    [ -z "$ep_choice" ] && return 1

    local ep_url
    ep_url=$(printf '%s\n' "$episodes" | awk -F'\t' -v ec="$ep_choice" '$1==ec{print $2; exit}')
    ep_title="$ep_choice"

    stream_url=$(spin_task "Resolving direct MP4 stream for '$ep_title'..." supercartoons_stream "$ep_url")
  else
    stream_url=$(spin_task "Resolving direct MP4 stream for '$title'..." supercartoons_stream "$url")
  fi

  if [ -z "$stream_url" ]; then
    warn "SuperCartoons could not resolve MP4 stream for this title."
    return 1
  fi

  hist_add "cartoons" "$ep_title" ""

  if [ "$download_mode" = "1" ]; then
    download_url "$stream_url" "$ep_title"
  else
    play_url "$stream_url" "$ep_title"

    while [ -t 0 ]; do
      local action
      action=$(printf 'replay\nselect another cartoon\nquit' | fzf_prompt "$ep_title")
      case "$action" in
        replay) play_url "$stream_url" "$ep_title" ;;
        "select another cartoon") _cartoons_play_supercartoons "$results" "$download_mode"; break ;;
        *) break ;;
      esac
    done
  fi
  return 0
}

_cartoons_play_archive() {
  local results="$1" download_mode="$2" query="$3"

  local choice
  choice=$(printf '%s\n' "$results" | awk -F'\t' '{print $1}' | fzf_prompt "Archive.org Cartoon Series")
  [ -z "$choice" ] && return 1

  local id
  id=$(printf '%s\n' "$results" | awk -F'\t' -v c="$choice" '$1==c{print $2; exit}')
  [ -z "$id" ] && return 1

  local episodes
  episodes=$(spin_task "Loading episodes from collection..." archive_episodes "$id")
  if [ -z "$episodes" ]; then
    warn "No playable video episodes found in this collection."
    return 1
  fi


  local ep_choice
  ep_choice=$(printf '%s\n' "$episodes" | awk -F'\t' '{print $1}' | fzf_prompt "Select episode ($choice)")
  [ -z "$ep_choice" ] && return 1

  local ep_file
  ep_file=$(printf '%s\n' "$episodes" | awk -F'\t' -v ec="$ep_choice" '$1==ec{print $3; exit}')
  [ -z "$ep_file" ] && return 1

  local stream_url
  stream_url=$(archive_stream "$id" "$ep_file")

  hist_add "cartoons" "$ep_choice" ""

  if [ "$download_mode" = "1" ]; then
    download_url "$stream_url" "$ep_choice"
  else
    info "Streaming: $ep_choice [Archive.org Direct MP4]"
    play_url "$stream_url" "$ep_choice"

    while [ -t 0 ]; do
      local action
      action=$(printf 'replay\nselect another episode\nsearch again\nquit' | fzf_prompt "$ep_choice")
      case "$action" in
        replay)
          play_url "$stream_url" "$ep_choice"
          ;;
        "select another episode")
          ep_choice=$(printf '%s\n' "$episodes" | awk -F'\t' '{print $1}' | fzf_prompt "Select episode ($choice)")
          [ -z "$ep_choice" ] && break
          ep_file=$(printf '%s\n' "$episodes" | awk -F'\t' -v ec="$ep_choice" '$1==ec{print $3; exit}')
          stream_url=$(archive_stream "$id" "$ep_file")
          info "Streaming: $ep_choice [Archive.org Direct MP4]"
          play_url "$stream_url" "$ep_choice"
          ;;
        "search again")
          cartoons_search_and_play "" "$download_mode"
          break
          ;;
        *) break ;;
      esac
    done
  fi
  return 0
}

_cartoons_play_hianime() {
  local results="$1" download_mode="$2"

  local choice
  choice=$(printf '%s\n' "$results" | awk -F'\t' '{print $2}' | fzf_prompt "HiAnime Animation (1080p)")
  [ -z "$choice" ] && return 1

  local show_id
  show_id=$(printf '%s\n' "$results" | awk -F'\t' -v c="$choice" '$2==c{print $1; exit}')
  [ -z "$show_id" ] && return 1

  info "Fetching episode list for $choice..."
  local episodes
  episodes=$(hianime_episodes "$show_id")
  [ -z "$episodes" ] && return 1

  local ep_line
  ep_line=$(printf '%s\n' "$episodes" | awk -F'\t' '{printf "Episode %s: %s\n", $2, $3}' | fzf_prompt "Select episode ($choice)")
  [ -z "$ep_line" ] && return 1

  local ep_num ep_id
  ep_num=$(printf '%s' "$ep_line" | sed -n 's/^Episode \([0-9]*\):.*/\1/p')
  ep_id=$(printf '%s\n' "$episodes" | awk -F'\t' -v n="$ep_num" '$2==n{print $1; exit}')

  local lang="${EVERY_CLI_LANG:-sub}"
  local quality
  quality=$(prompt_quality "Select Animation Quality")
  EVERY_CLI_QUALITY="$quality"

  info "Fetching episode $ep_num of $choice ($lang, $quality)..."
  local stream_info stream refr sub
  stream_info=$(hianime_get_stream "$ep_id" "$lang" "$quality")
  stream=$(printf '%s' "$stream_info" | cut -f1)
  refr=$(printf '%s' "$stream_info" | cut -f2)
  sub=$(printf '%s' "$stream_info" | cut -f3)

  if [ -z "$stream" ]; then
    warn "Could not resolve stream on HiAnime."
    return 1
  fi

  hist_add "cartoons" "$choice" "$ep_num"

  if [ "$download_mode" = "1" ]; then
    download_url "$stream" "${choice} E${ep_num}" "$refr" "$sub"
  else
    play_url "$stream" "${choice} — Episode ${ep_num}" "$refr" "$sub"
  fi
  return 0
}

_cartoons_youtube_fallback() {
  local query="$1" download_mode="$2"

  local yt_results
  yt_results=$(spin_task "Searching cartoon archives for '$query'..." yt_search_list "$query" 25 "cartoon full episode")
  [ -z "$yt_results" ] && yt_results=$(spin_task "Searching streaming sources..." yt_search_list "$query" 25)
  [ -z "$yt_results" ] && { err "No cartoon episodes found for: $query"; return 1; }

  local selected
  selected=$(printf '%s\n' "$yt_results" \
    | awk -F'\t' '{print $1}' \
    | fzf_prompt "Select cartoon episode")
  [ -z "$selected" ] && return 1

  local yt_url
  yt_url=$(printf '%s\n' "$yt_results" | awk -F'\t' -v s="$selected" '$1==s{print $2; exit}')
  [ -z "$yt_url" ] && return 1

  local quality
  quality=$(prompt_quality "Select Cartoon Quality")
  EVERY_CLI_QUALITY="$quality"

  if [ "$download_mode" = "1" ]; then
    yt_download "$yt_url"
  else
    hist_add "cartoons" "$selected" ""
    play_url "$yt_url" "$selected"


    while [ -t 0 ]; do
      local action
      action=$(printf 'replay\nsearch again\nchange quality\nquit' \
        | fzf_prompt "Cartoon — $selected")
      case "$action" in
        replay)
          play_url "$yt_url" "$selected"
          ;;
        "search again")
          cartoons_search_and_play "" "$download_mode"
          break
          ;;
        "change quality")
          quality=$(prompt_quality "Select Cartoon Quality")
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
