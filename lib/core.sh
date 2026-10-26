#!/bin/sh
# lib/core.sh — shared helpers for every-cli
# Modelled after ani-cli's internal structure

# ── Colours ──────────────────────────────────────────────────────────────────
if [ "${EVERY_CLI_COLOR:-1}" = "1" ] && [ -t 1 ]; then
  C_RED='\033[31m'; C_GRN='\033[32m'; C_YLW='\033[33m'
  C_BLU='\033[34m'; C_MAG='\033[35m'; C_CYN='\033[36m'
  C_BLD='\033[1m';  C_RST='\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''
  C_MAG=''; C_CYN=''; C_BLD=''; C_RST=''
fi

err()  { printf "${C_RED}Error:${C_RST} %s\n" "$*" >&2; }
warn() { printf "${C_YLW}Warning:${C_RST} %s\n" "$*" >&2; }
info() { printf "${C_BLU}::${C_RST} %s\n" "$*"; }
die()  { err "$@"; exit 1; }

spin_pid() {
  local pid=$1
  local msg="$2"
  local chars="/-\|"
  local i=0

  # Hide cursor
  [ -t 2 ] && printf "\033[?25l" >&2

  while kill -0 "$pid" 2>/dev/null; do
    local idx=$(( (i % 4) + 1 ))
    local char=$(printf '%s' "$chars" | cut -c "$idx")
    printf "\r\033[K${C_CYN}[%s]${C_RST} %s" "$char" "$msg" >&2
    i=$((i + 1))
    sleep 0.08
  done
  wait "$pid" 2>/dev/null
  local status=$?

  if [ $status -eq 0 ]; then
    printf "\r\033[K${C_GRN}[+]${C_RST} %s\n" "$msg" >&2
  else
    printf "\r\033[K${C_YLW}[!]${C_RST} %s\n" "$msg" >&2
  fi

  # Restore cursor
  [ -t 2 ] && printf "\033[?25h" >&2
  return $status
}

spin_task() {
  local msg="$1"; shift
  local tmp_out="${TMPDIR:-/tmp}/spin_task_$$"
  ("$@" > "$tmp_out") &
  local pid=$!

  spin_pid "$pid" "$msg"
  local ret=$?

  cat "$tmp_out" 2>/dev/null
  rm -f "$tmp_out" 2>/dev/null
  return $ret
}

random_tip() {
  local count=15
  local rand
  # Mix multiple entropy sources for genuine randomness on every call
  local seed
  seed=$(( ${RANDOM:-0} + $$ + $(date +%s) + ${SRANDOM:-$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ' || echo 0)} ))
  rand=$(( (seed % count) + 1 ))
  # Ensure positive
  [ "$rand" -lt 1 ] && rand=$(( (-rand % count) + 1 ))
  cat <<'EOF' | sed -n "${rand}p"
Use -d to download any stream directly to your drive
Quality is set to maximum by default — always the best available
Pass --dub to default anime to English dubbing
SuperCartoons hosts 1,500+ retro cartoons in direct MP4
Press ESC in any fzf menu to go back or cancel
Resume where you left off anytime with every-cli --continue
Select 'Audio Only' to stream YouTube music & podcasts
MPV GPU hardware acceleration is automatically active
Archive.org features complete cartoon series (Ben 10, Batman)
IPTV browser gives you 8,000+ live international channels
HiAnime provides 1080p stream resolution with dual audio
Type any partial word in fzf for instant fuzzy search
Press 'f' in mpv to toggle fullscreen, '#' to switch audio tracks
Press '[' and ']' in mpv to change playback speed
Use -c anime --dub -q 1080 to skip all menus and go direct
EOF
}


# ── HTTP — EXACTLY as ani-cli does it ────────────────────────────────────────
EVERY_CLI_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'

do_curl() {
  if command -v curl-impersonate-chrome >/dev/null 2>&1; then
    curl-impersonate-chrome -s --compressed --connect-timeout 8 --max-time 15 -A "$EVERY_CLI_UA" "$@"
    return $?
  fi
  local resp
  resp=$(curl -s --compressed --connect-timeout 8 --max-time 15 -A "$EVERY_CLI_UA" "$@")
  local exit_code=$?
  [ $exit_code -ne 0 ] && return $exit_code
  case "$resp" in
    *"Just a moment"*|*"cf-browser-verification"*|*"Enable JavaScript"*)
      warn "Cloudflare detected. Install curl-impersonate-chrome to bypass."
      return 1 ;;
  esac
  printf '%s' "$resp"
}

retry_curl() {
  local attempt=1 max=3 delay=2
  while [ $attempt -le $max ]; do
    result=$(do_curl "$@") && { printf '%s' "$result"; return 0; }
    warn "Attempt $attempt/$max failed, waiting ${delay}s..."
    sleep "$delay"; attempt=$((attempt+1)); delay=$((delay*2))
  done
  err "All $max attempts failed for: $*"
  return 1
}

do_curl_post() {
  local url="$1" data="$2"
  do_curl -H 'Content-Type: application/json' \
          -H 'Accept: application/json' \
          --data "$data" "$url"
}

# ── Caching (1-hour TTL) ─────────────────────────────────────────────────────
CACHE_DIR="${TMPDIR:-/tmp}/every-cli"
mkdir -p "$CACHE_DIR"

_md5() {
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5
  else
    printf '%s' "$1" | cksum | cut -d' ' -f1
  fi
}

cached_get() {
  local url="$1" ttl="${2:-3600}"
  local key="$CACHE_DIR/$(_md5 "$url")"
  local now mod_time age
  now=$(date +%s)
  if [ -f "$key" ]; then
    mod_time=$(stat -c %Y "$key" 2>/dev/null || stat -f %m "$key" 2>/dev/null || echo 0)
    age=$((now - mod_time))
    [ "$age" -lt "$ttl" ] && { cat "$key"; return 0; }
  fi
  retry_curl "$url" | tee "$key"
}

_find_mpv() {
  if command -v mpv >/dev/null 2>&1; then
    printf 'mpv'
  elif [ -f "/c/Program Files/MPV Player/mpv.com" ]; then
    printf '/c/Program Files/MPV Player/mpv.com'
  elif [ -f "/c/Program Files/MPV Player/mpv.exe" ]; then
    printf '/c/Program Files/MPV Player/mpv.exe'
  elif [ -f "/c/Program Files/mpv/mpv.exe" ]; then
    printf '/c/Program Files/mpv/mpv.exe'
  elif [ -f "$HOME/scoop/apps/mpv/current/mpv.exe" ]; then
    printf '%s/scoop/apps/mpv/current/mpv.exe' "$HOME"
  fi
}

_find_fzf() {
  if command -v fzf >/dev/null 2>&1; then
    printf 'fzf'
  else
    local winget_fzf
    winget_fzf=$(find "$LOCALAPPDATA/Microsoft/WinGet/Packages" -name "fzf.exe" 2>/dev/null | head -1)
    if [ -n "$winget_fzf" ]; then
      printf '%s' "$winget_fzf"
    elif [ -f "$HOME/scoop/apps/fzf/current/fzf.exe" ]; then
      printf '%s/scoop/apps/fzf/current/fzf.exe' "$HOME"
    fi
  fi
}

# ── Dependency checking ───────────────────────────────────────────────────────
dep_check() {
  local missing=''
  for dep in "$@"; do
    if [ "$dep" = "mpv" ]; then
      local mpv_found
      mpv_found=$(_find_mpv)
      [ -z "$mpv_found" ] && missing="$missing mpv"
    elif [ "$dep" = "fzf" ]; then
      local fzf_found
      fzf_found=$(_find_fzf)
      [ -z "$fzf_found" ] && missing="$missing fzf"
    else
      command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
    fi
  done
  if [ -n "$missing" ]; then
    err "Missing dependencies:$missing"
    info "Install them and retry. See README for per-OS instructions."
    exit 1
  fi
}

# ── fzf wrapper (clean minimalist terminal styling) ───────────────────────────
fzf_prompt() {
  local prompt_text="${1:-Select}"
  local fzf_bin
  fzf_bin=$(_find_fzf)
  fzf_bin="${fzf_bin:-fzf}"
  "$fzf_bin" \
      --prompt="  $prompt_text > " \
      --pointer=">" \
      --marker="*" \
      --height=60% \
      --layout=reverse \
      --border=rounded \
      --border-label=" every-cli " \
      --border-label-pos=3 \
      --info=inline-right \
      --no-sort \
      --header="[ENTER] Select  |  [ESC] Back" \
      --header-first \
      --color='prompt:bold:cyan,pointer:bold:cyan,border:blue,label:bold:yellow,header:italic:gray,info:yellow,hl:bold:green,hl+:bold:green'
}

fzf_select() {
  local prompt="$1"; shift
  printf '%s\n' "$@" | fzf_prompt "$prompt"
}

# ── Quality prompt helper ─────────────────────────────────────────────────────
prompt_quality() {
  local prompt_label="${1:-Select Video Quality}"
  if [ "${QUALITY_GIVEN:-0}" = "1" ]; then
    printf '%s' "${EVERY_CLI_QUALITY:-best}"
    return 0
  fi
  [ ! -t 0 ] && printf 'best' && return 0

  local chosen
  chosen=$(printf 'Best Available (highest resolution)\n1080p Full HD (1920x1080)\n720p  HD (1280x720)\n480p  SD (854x480)\n360p  Low (640x360)\nAudio Only (Music / Podcast)\n' \
    | fzf_prompt "$prompt_label")
  case "$chosen" in
    *Best*)  printf 'best' ;;
    *1080*)  printf '1080' ;;
    *720*)   printf '720' ;;
    *480*)   printf '480' ;;
    *360*)   printf '360' ;;
    *Audio*) printf 'audio' ;;
    *)       printf 'best' ;;
  esac
}

# ── Player ────────────────────────────────────────────────────────────────────
play_url() {
  local url="$1" title="${2:-every-cli}" refr="${3:-}" sub="${4:-}"
  local player="${EVERY_CLI_PLAYER:-mpv}"
  local mpv_bin
  mpv_bin=$(_find_mpv)
  mpv_bin="${mpv_bin:-mpv}"
  local quality="${EVERY_CLI_QUALITY:-best}"
  local ytdl_fmt=""
  local extra_mpv=""
  case "$quality" in
    best)  ytdl_fmt="--ytdl-format=bestvideo+bestaudio/best" ;;
    1080)  ytdl_fmt="--ytdl-format=bestvideo[height<=?1080]+bestaudio/best[height<=?1080]/best" ;;
    720)   ytdl_fmt="--ytdl-format=bestvideo[height<=?720]+bestaudio/best[height<=?720]/best" ;;
    480)   ytdl_fmt="--ytdl-format=bestvideo[height<=?480]+bestaudio/best[height<=?480]/best" ;;
    360)   ytdl_fmt="--ytdl-format=bestvideo[height<=?360]+bestaudio/best[height<=?360]/best" ;;
    audio) extra_mpv="--no-video"; ytdl_fmt="--ytdl-format=bestaudio/best" ;;
    *)     ytdl_fmt="--ytdl-format=bestvideo+bestaudio/best" ;;
  esac

  printf "${C_GRN}[+]${C_RST} Playing: ${C_BLD}%s${C_RST} ${C_YLW}(press 'q' in player to return)${C_RST}\n" "$title"

  case "$player" in
    mpv)
      "$mpv_bin" \
        --force-window=immediate \
        --hwdec=auto \
        --term-osd-bar \
        --msg-level=all=warn,cplayer=info \
        --demuxer-readahead-secs=20 \
        --demuxer-max-bytes=50M \
        ${extra_mpv:+"$extra_mpv"} \
        ${ytdl_fmt:+"$ytdl_fmt"} \
        ${refr:+--referrer="$refr"} \
        ${sub:+--sub-file="$sub"} \
        --title="$title" "$url"
      local exit_code=$?
      if [ $exit_code -ne 0 ]; then
        warn "Playback ended or stream was unavailable (exit code: $exit_code)."
      fi
      return $exit_code ;;

    vlc)
      if command -v vlc >/dev/null 2>&1; then
        vlc --intf dummy --play-and-exit \
          ${refr:+--http-referrer="$refr"} \
          --meta-title="$title" "$url" 2>/dev/null
      else
        "$mpv_bin" --really-quiet --hwdec=auto \
          ${extra_mpv:+"$extra_mpv"} \
          ${ytdl_fmt:+"$ytdl_fmt"} \
          ${refr:+--referrer="$refr"} \
          ${sub:+--sub-file="$sub"} \
          --title="$title" "$url"
      fi ;;
    iina) iina --no-stdin ${refr:+--mpv-referrer="$refr"} "$url" ;;
    *) "$player" "$url" ;;
  esac
}


# ── yt-dlp stream resolver ────────────────────────────────────────────────────
resolve_stream() {
  local url="$1"
  local quality="${EVERY_CLI_QUALITY:-best}"
  local fmt
  case "$quality" in
    best)  fmt="bestvideo+bestaudio/best" ;;
    1080)  fmt="bestvideo[height<=1080]+bestaudio/best[height<=1080]/best" ;;
    720)   fmt="bestvideo[height<=720]+bestaudio/best[height<=720]/best" ;;
    480)   fmt="bestvideo[height<=480]+bestaudio/best[height<=480]/best" ;;
    360)   fmt="bestvideo[height<=360]+bestaudio/best[height<=360]/best" ;;
    *)     fmt="bestvideo+bestaudio/best" ;;
  esac
  # Return all stream URLs (video + audio) so mpv can merge them
  yt-dlp --no-warnings -g --format "$fmt" "$url" 2>/dev/null | tr -d '\r'
}

# ── Download ──────────────────────────────────────────────────────────────────
download_url() {
  local url="$1" title="${2:-video}" refr="${3:-}" sub="${4:-}"
  local out_dir="${EVERY_CLI_DOWNLOAD_DIR:-$HOME/Videos/every-cli}"
  local quality="${EVERY_CLI_QUALITY:-best}"
  local fmt
  case "$quality" in
    best)  fmt="bestvideo+bestaudio/best" ;;
    1080)  fmt="bestvideo[height<=1080]+bestaudio/best[height<=1080]/best" ;;
    720)   fmt="bestvideo[height<=720]+bestaudio/best[height<=720]/best" ;;
    480)   fmt="bestvideo[height<=480]+bestaudio/best[height<=480]/best" ;;
    360)   fmt="bestvideo[height<=360]+bestaudio/best[height<=360]/best" ;;
    *)     fmt="bestvideo+bestaudio/best" ;;
  esac
  mkdir -p "$out_dir"
  info "Downloading to: $out_dir (quality: $quality)"
  yt-dlp --no-warnings \
         ${refr:+--referer "$refr"} \
         -o "$out_dir/%(title)s.%(ext)s" \
         --format "$fmt" \
         --merge-output-format mp4 \
         "$url"
}

# ── Self-update ───────────────────────────────────────────────────────────────
self_update() {
  info "Checking for updates..."
  local tmp
  tmp=$(mktemp)
  local repo_url="${EVERY_CLI_REPO_URL:-https://raw.githubusercontent.com/pythoncoder6769-create/every-cli/main/every-cli}"
  if do_curl \
    "$repo_url" \
    -o "$tmp"; then
    chmod +x "$tmp"
    cp "$tmp" "$0"
    rm -f "$tmp"
    info "Updated successfully."
  else
    err "Update failed."
    rm -f "$tmp"
  fi
}

# ── History ───────────────────────────────────────────────────────────────────
HIST_DIR="${EVERY_CLI_HIST_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/every-cli}"
HIST_FILE="$HIST_DIR/history"
mkdir -p "$HIST_DIR"

hist_add() {
  local entry="$(date +%s)\t$1\t$2\t${3:-}"
  printf '%b\n' "$entry" >> "$HIST_FILE"
}

hist_show() {
  [ -f "$HIST_FILE" ] || { info "No history yet."; return; }
  (tac "$HIST_FILE" 2>/dev/null || tail -r "$HIST_FILE" 2>/dev/null || sed '1!G;h;$!d' "$HIST_FILE" 2>/dev/null || cat "$HIST_FILE") \
    | awk -F'\t' '{printf "[%s] %s — ep%s\n", $2, $3, $4}' \
    | fzf_prompt "Resume from history"
}
