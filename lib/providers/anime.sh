#!/bin/sh
# lib/providers/anime.sh
# Anime provider with interactive Sub/Dub selection, Quality selection,
# and ani-cli style playback loop (Next / Replay / Previous / Select / Quality / Audio / Quit)
# Requires: core.sh, hianime.sh, allanime.sh, yt_search.sh

anime_search_and_play() {
  local query="$1" ep_arg="$2" lang="${EVERY_CLI_LANG:-sub}" download_mode="$3"
  local quality="${EVERY_CLI_QUALITY:-best}"

  if [ -z "$query" ]; then
    printf "${C_CYN}  Search Anime ❯${C_RST} "
    read -r query
    [ -z "$query" ] && return
  fi

  local results
  results=$(spin_task "Searching HiAnime for '$query'..." hianime_search "$query")

  # Level 1: HiAnime (Primary)
  if [ -n "$results" ]; then
    if _anime_play_hianime "$results" "$ep_arg" "$lang" "$quality" "$download_mode"; then
      return 0
    fi
    warn "HiAnime playback failed. Trying AllAnime..."
  else
    warn "HiAnime returned no results. Trying AllAnime..."
  fi

  # Level 2: AllAnime (Secondary fallback)
  local aa_results
  aa_results=$(spin_task "Searching AllAnime for '$query'..." allanime_search "$query")
  if [ -n "$aa_results" ]; then
    if _anime_play_allanime "$aa_results" "$ep_arg" "$lang" "$download_mode"; then
      return 0
    fi
    warn "AllAnime failed. Trying YouTube fallback..."
  else
    warn "AllAnime returned no results. Falling back to YouTube..."
  fi

  # Level 3: Universal YouTube fallback
  _anime_youtube_fallback "$query" "$download_mode"
}

_anime_play_hianime() {
  local results="$1" ep_arg="$2" lang="$3" quality="$4" download_mode="$5"

  local selected_line
  selected_line=$(printf '%s\n' "$results" \
    | awk -F'\t' '{print $2}' \
    | fzf_prompt "Select anime")
  [ -z "$selected_line" ] && return 1

  local anime_slug
  anime_slug=$(printf '%s\n' "$results" \
    | awk -F'\t' -v title="$selected_line" '$2==title{print $1; exit}')
  [ -z "$anime_slug" ] && return 1

  local ep_map
  ep_map=$(spin_task "Loading episodes for $selected_line..." hianime_episodes "$anime_slug")
  if [ -z "$ep_map" ]; then
    warn "Could not fetch episode list from HiAnime."
    return 1
  fi


  local ep_numbers
  ep_numbers=$(printf '%s\n' "$ep_map" | awk -F'\t' '{print $2}')
  local total_eps
  total_eps=$(printf '%s\n' "$ep_numbers" | wc -l | tr -d ' ')

  # Episode selection
  local episode
  if [ -n "$ep_arg" ]; then
    episode="$ep_arg"
  elif [ "$total_eps" -le 1 ]; then
    episode="1"
  else
    episode=$(printf '%s\n' "$ep_numbers" | fzf_prompt "Select episode ($selected_line - $total_eps eps)")
    [ -z "$episode" ] && return 1
  fi

  # Audio (Sub / Dub) selection prompt if not explicitly passed via flag
  if [ "${DUB_GIVEN:-0}" != "1" ] && [ -t 0 ]; then
    local audio_choice
    audio_choice=$(printf "sub (Japanese with subtitles)\ndub (English audio)\n" \
      | fzf_prompt "Select audio language")
    case "$audio_choice" in
      *dub*) lang="dub" ;;
      *)     lang="sub" ;;
    esac
  fi

  # Quality selection prompt if not explicitly passed via flag
  if [ "${QUALITY_GIVEN:-0}" != "1" ] && [ -t 0 ]; then
    local quality_choice
    quality_choice=$(printf "best (1080p / highest)\n1080p\n720p\n480p\n360p\n" \
      | fzf_prompt "Select video quality")
    case "$quality_choice" in
      *1080*) quality="1080" ;;
      *720*)  quality="720" ;;
      *480*)  quality="480" ;;
      *360*)  quality="360" ;;
      *)      quality="best" ;;
    esac
    EVERY_CLI_QUALITY="$quality"
  fi

  # Episode range handling (e.g. 1-12)
  case "$episode" in
    *-*)
      local start_ep end_ep cur_ep
      start_ep=$(printf '%s' "$episode" | cut -d'-' -f1)
      end_ep=$(printf '%s' "$episode" | cut -d'-' -f2)
      info "Processing episode range: $start_ep to $end_ep"
      cur_ep="$start_ep"
      while [ "$cur_ep" -le "$end_ep" ]; do
        _play_single_hianime_ep "$anime_slug" "$selected_line" "$ep_map" "$cur_ep" "$lang" "$quality" "$download_mode"
        cur_ep=$((cur_ep + 1))
      done
      return 0
      ;;
  esac

  # Play single episode
  if ! _play_single_hianime_ep "$anime_slug" "$selected_line" "$ep_map" "$episode" "$lang" "$quality" "$download_mode"; then
    return 1
  fi

  # Download mode stops after playing/downloading
  [ "$download_mode" = "1" ] && return 0

  # Interactive ani-cli playback loop (Next / Replay / Previous / Select / Quality / Audio / Quit)
  while true; do
    local action
    action=$(printf 'next\nreplay\nprevious\nselect episode\nchange quality\nchange audio (sub/dub)\nquit' \
      | fzf_prompt "Episode $episode ($selected_line) — [${lang}] [${quality}]")

    [ -z "$action" ] || [ "$action" = "quit" ] && break

    case "$action" in
      next)
        local next_ep
        next_ep=$(printf '%s\n' "$ep_numbers" | sed -n "/^${episode}$/{n;p;}")
        if [ -z "$next_ep" ]; then
          warn "No next episode found."
          continue
        fi
        episode="$next_ep"
        ;;
      previous)
        local prev_ep
        prev_ep=$(printf '%s\n' "$ep_numbers" | sed -n "/^${episode}$/{g;1!p;};h")
        if [ -z "$prev_ep" ]; then
          warn "No previous episode found."
          continue
        fi
        episode="$prev_ep"
        ;;
      replay)
        # Re-play current episode
        ;;
      "select episode")
        local new_ep
        new_ep=$(printf '%s\n' "$ep_numbers" | fzf_prompt "Select episode ($selected_line)")
        [ -z "$new_ep" ] && continue
        episode="$new_ep"
        ;;
      "change quality")
        local new_q
        new_q=$(printf "best (1080p / highest)\n1080p\n720p\n480p\n360p\n" | fzf_prompt "Select quality")
        case "$new_q" in
          *1080*) quality="1080" ;;
          *720*)  quality="720" ;;
          *480*)  quality="480" ;;
          *360*)  quality="360" ;;
          *)      quality="best" ;;
        esac
        EVERY_CLI_QUALITY="$quality"
        info "Quality set to: $quality"
        continue
        ;;
      "change audio (sub/dub)")
        if [ "$lang" = "sub" ]; then
          lang="dub"
          info "Switched audio to: dub (English audio)"
        else
          lang="sub"
          info "Switched audio to: sub (Japanese with subtitles)"
        fi
        continue
        ;;
    esac

    _play_single_hianime_ep "$anime_slug" "$selected_line" "$ep_map" "$episode" "$lang" "$quality" "$download_mode"
  done

  return 0
}

_play_single_hianime_ep() {
  local anime_slug="$1" selected_line="$2" ep_map="$3" episode="$4" lang="$5" quality="$6" download_mode="$7"

  local ep_id
  ep_id=$(printf '%s\n' "$ep_map" | awk -F'\t' -v n="$episode" '$2==n{print $1; exit}')
  if [ -z "$ep_id" ]; then
    warn "Episode $episode not found in episode map."
    return 1
  fi

  local stream_info stream refr sub
  stream_info=$(spin_task "Resolving stream for Episode $episode ($lang, ${quality}p)..." hianime_get_stream "$ep_id" "$lang" "$quality")
  stream=$(printf '%s' "$stream_info" | cut -f1)
  refr=$(printf '%s' "$stream_info" | cut -f2)
  sub=$(printf '%s' "$stream_info" | cut -f3)

  if [ -z "$stream" ]; then
    warn "Could not resolve stream for episode $episode ($lang)."
    return 1
  fi


  hist_add "anime" "$selected_line" "$episode"

  if [ "$download_mode" = "1" ]; then
    download_url "$stream" "${selected_line} E${episode} (${lang})" "$refr" "$sub"
  else
    play_url "$stream" "${selected_line} — Episode ${episode} (${lang})" "$refr" "$sub"
  fi
  return 0
}

_anime_play_allanime() {
  local results="$1" ep_arg="$2" lang="$3" download_mode="$4"

  local selected_line
  selected_line=$(printf '%s\n' "$results" \
    | awk -F'|' '{printf "%s [sub:%s dub:%s]\n", $2, $3, $4}' \
    | fzf_prompt "Select anime (AllAnime)")
  [ -z "$selected_line" ] && return 1

  local show_id
  show_id=$(printf '%s\n' "$results" \
    | awk -F'|' -v t="$selected_line" 'index(t,$2){print $1}' | head -1)
  local show_name
  show_name=$(printf '%s' "$selected_line" | sed 's/ \[sub:.*$//')

  local ep_count
  ep_count=$(printf '%s\n' "$results" \
    | awk -F'|' -v id="$show_id" '$1==id{print ($5=="dub")?$4:$3}' | head -1)

  local episode
  if [ -n "$ep_arg" ]; then
    episode="$ep_arg"
  elif [ "${ep_count:-0}" -le 1 ]; then
    episode="1"
  else
    episode=$(seq 1 "${ep_count:-1}" | fzf_prompt "Select episode ($show_name)")
    [ -z "$episode" ] && return 1
  fi

  info "Fetching episode $episode of $show_name ($lang)..."
  local ep_json
  ep_json=$(allanime_episode "$show_id" "$episode" "$lang")

  if [ -z "$ep_json" ] || printf '%s' "$ep_json" | grep -q '"episode":null'; then
    return 1
  fi

  local stream
  stream=$(allanime_get_stream "$ep_json")
  [ -z "$stream" ] && return 1

  hist_add "anime" "$show_name" "$episode"

  if [ "$download_mode" = "1" ]; then
    download_url "$stream" "${show_name} E${episode}"
  else
    play_url "$stream" "${show_name} — Episode ${episode}"
  fi
  return 0
}

_anime_youtube_fallback() {
  local query="$1" download_mode="$2"
  info "YouTube fallback — searching: '$query anime'"
  local yt_results
  yt_results=$(yt_search_list "$query" 15 "anime english sub")

  local selected
  selected=$(printf '%s\n' "$yt_results" \
    | awk -F'\t' '{print $1}' | fzf_prompt "Select from YouTube")
  [ -z "$selected" ] && return

  local yt_url
  yt_url=$(printf '%s\n' "$yt_results" | awk -F'\t' -v s="$selected" '$1==s{print $2; exit}')

  if [ "$download_mode" = "1" ]; then
    yt_download "$yt_url"
  else
    play_url "$yt_url" "$selected"
  fi
}
