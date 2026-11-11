#!/bin/sh
# lib/providers/music.sh
# Music provider — audio-only streaming and downloading
# Always plays at highest audio quality (320kbps opus/m4a via bestaudio)
# No video window — terminal-only with volume, seek, and playback controls
# Sources: YouTube (primary), with MusicBrainz metadata enrichment
# Requires: core.sh, music_api.sh, yt_search.sh

if [ -z "$LIB_DIR" ]; then
  _dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  [ -f "$_dir/../core.sh" ] && LIB_DIR="$_dir/.."
fi
if [ -n "$LIB_DIR" ] && [ -f "$LIB_DIR/core.sh" ]; then
  . "$LIB_DIR/core.sh"
  [ -f "$LIB_DIR/scrapers/music_api.sh" ] && . "$LIB_DIR/scrapers/music_api.sh"
  [ -f "$LIB_DIR/scrapers/yt_search.sh" ] && . "$LIB_DIR/scrapers/yt_search.sh"
fi

# ── Audio player with Terminal UI (Cover Art & Synced Lyrics) ─────────────────
play_audio() {
  local url="$1" title="${2:-Music}" refr="${3:-}"
  local mpv_bin
  mpv_bin=$(_find_mpv)
  mpv_bin="${mpv_bin:-mpv}"

  local music_py=""
  if [ -n "$LIB_DIR" ] && [ -f "$LIB_DIR/music_player.py" ]; then
    music_py="$LIB_DIR/music_player.py"
  elif [ -f "$(dirname "$0")/../music_player.py" ]; then
    music_py="$(dirname "$0")/../music_player.py"
  fi

  local py_cmd=""
  if command -v python >/dev/null 2>&1; then
    py_cmd="python"
  elif command -v python3 >/dev/null 2>&1; then
    py_cmd="python3"
  elif command -v py >/dev/null 2>&1; then
    py_cmd="py"
  fi

  # Launch the Terminal Music UI with TrueColor cover art & synchronized lyrics
  if [ -n "$music_py" ] && [ -n "$py_cmd" ]; then
    if command -v cygpath >/dev/null 2>&1; then
      music_py=$(cygpath -w "$music_py" 2>/dev/null || printf '%s' "$music_py")
    fi
    "$py_cmd" "$music_py" "$url" "$title"
    return $?
  fi

  # Fallback to pure shell player if Python is absent
  render_media_card "$title" "YouTube Audio" "320kbps Max" "1"

  "$mpv_bin" \
    --no-video \
    --term-osd-bar \
    --term-osd-bar-chars="[■■-]" \
    --msg-level=all=no,statusline=status \
    --ytdl-format="bestaudio/best" \
    --ytdl-raw-options="extractor-args=youtube:player_client=android" \
    --demuxer-readahead-secs=30 \
    --demuxer-max-bytes=20M \
    --volume=80 \
    --volume-max=150 \
    --audio-display=no \
    ${refr:+--referrer="$refr"} \
    --title="$title" "$url"

  return $?
}

# ── Audio-only downloader (best audio, MP3 output) ────────────────────────────
download_audio() {
  local url="$1" title="${2:-track}"
  local out_dir="${EVERY_CLI_DOWNLOAD_DIR:-$HOME/Music/every-cli}"
  mkdir -p "$out_dir"

  info "Downloading audio to: $out_dir"
  yt-dlp --no-warnings \
    --extractor-args "youtube:player_client=android" \
    -x --audio-format mp3 --audio-quality 0 \
    --embed-thumbnail \
    --add-metadata \
    -o "$out_dir/%(artist,uploader)s - %(title)s.%(ext)s" \
    "$url"
}

# ── Main music search and play ────────────────────────────────────────────────
music_search_and_play() {
  local query="$1" download_mode="$2"

  if [ -z "$query" ]; then
    printf "\n  ${C_PRI}◆${C_RST} ${C_WHT}${C_BLD}Search Music${C_RST} ${C_MUT}❯${C_RST} "
    read -r query
    [ -z "$query" ] && return
  fi

  local mode_choice
  mode_choice=$(printf '%s\n' \
    "  ♪   Search Song      Direct track playback (audio-only)" \
    "  👤  Search Artist    Browse artist discography & top hits" \
    "  ⚡  Playlist / Mix   Curated albums & continuous mixes" \
    "  📝  Lyrics Video     Watch video with synchronized lyrics" \
    | fzf_prompt "Music Mode — '$query'")
  [ -z "$mode_choice" ] && return

  local search_suffix=""
  case "$mode_choice" in
    *Song*)      search_suffix="audio" ;;
    *Artist*)    search_suffix="songs full album" ;;
    *Playlist*)  search_suffix="playlist mix" ;;
    *Lyrics*)    search_suffix="lyrics" ;;
    *)           search_suffix="audio" ;;
  esac

  local results
  results=$(spin_task "Searching music archives for '$query'..." music_yt_search "$query $search_suffix" 25)
  [ -z "$results" ] && { err "No music results found for: $query"; return 1; }

  local selected
  selected=$(printf '%s\n' "$results" \
    | awk -F'\t' '{print $1}' \
    | fzf_prompt "Select Track")
  [ -z "$selected" ] && return

  local yt_url
  yt_url=$(printf '%s\n' "$results" | awk -F'\t' -v s="$selected" '$1==s{print $2; exit}')
  [ -z "$yt_url" ] && return

  # For lyrics mode, play with video (lyrics are in the video)
  local is_lyrics=0
  case "$mode_choice" in *Lyrics*) is_lyrics=1 ;; esac

  if [ "$download_mode" = "1" ]; then
    download_audio "$yt_url" "$selected"
  elif [ "$is_lyrics" = "1" ]; then
    hist_add "music" "$selected" ""
    EVERY_CLI_QUALITY="best"
    play_url "$yt_url" "$selected"
  else
    hist_add "music" "$selected" ""
    play_audio "$yt_url" "$selected"
  fi

  # Download mode stops after downloading
  [ "$download_mode" = "1" ] && return 0

  # Post-playback menu
  while [ -t 0 ]; do
    local action
    action=$(printf '%s\n' \
      "  ↺   Replay track" \
      "  ⏭   Queue next from search results" \
      "  ⬇   Download as high-bitrate MP3" \
      "  🔍  Search another song" \
      "  ✕   Return to main menu" \
      | fzf_prompt "Track Finished — $selected")

    case "$action" in
      *Replay*)
        if [ "$is_lyrics" = "1" ]; then
          play_url "$yt_url" "$selected"
        else
          play_audio "$yt_url" "$selected"
        fi
        ;;
      *Search*)
        music_search_and_play "" "$download_mode"
        break
        ;;
      *Download*)
        download_audio "$yt_url" "$selected"
        ;;
      *Queue*)
        # Play next unplayed track from the results list
        local next_track next_url
        next_track=$(printf '%s\n' "$results" \
          | awk -F'\t' '{print $1}' \
          | awk -v played="$selected" 'found{print; exit} $0==played{found=1}')
        if [ -z "$next_track" ]; then
          warn "No more tracks in results."
          continue
        fi
        next_url=$(printf '%s\n' "$results" | awk -F'\t' -v s="$next_track" '$1==s{print $2; exit}')
        selected="$next_track"
        yt_url="$next_url"
        hist_add "music" "$selected" ""
        play_audio "$yt_url" "$selected"
        ;;
      *)
        break
        ;;
    esac
  done
}
