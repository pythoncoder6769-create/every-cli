#!/usr/bin/env python3
"""
lib/music_player.py — Native Terminal Music Player for every-cli

Features:
- Responsive TUI dynamically adapting to terminal width & height
- High-resolution TrueColor (24-bit) halfblock album cover art (▀)
- Real-time synchronized lyrics via LRCLIB (scrolling karaoke highlight)
- Dual lyrics fallback (LRCLIB synced/plain + lyrics.ovh)
- Full interactive controls: Space (play/pause), 9/0 (volume), Left/Right (seek), q (return)
- MPV IPC control over named pipes (Windows) / Unix domain sockets (Linux/macOS)
- Bulletproof ANSI visible-width calculation preventing ghost borders and alignment bugs
"""

import os
import sys
import time
import json
import re
import urllib.request
import urllib.parse
import io
import subprocess
import threading
import shutil

# ── Terminal Key Handling ─────────────────────────────────────────────────────
IS_WIN = sys.platform == 'win32'
if IS_WIN:
    import msvcrt
else:
    import select
    import termios
    import tty
    import signal

winch_resized = [False]
if not IS_WIN and hasattr(signal, 'SIGWINCH'):
    def _sigwinch_handler(signum, frame):
        winch_resized[0] = True
    try:
        signal.signal(signal.SIGWINCH, _sigwinch_handler)
    except:
        pass

def get_key():
    if IS_WIN:
        if msvcrt.kbhit():
            ch = msvcrt.getch()
            if ch in (b'\x00', b'\xe0'):
                ch2 = msvcrt.getch()
                if ch2 == b'K': return 'left'
                elif ch2 == b'M': return 'right'
                elif ch2 == b'H': return 'up'
                elif ch2 == b'P': return 'down'
            else:
                try:
                    return ch.decode('utf-8', errors='ignore').lower()
                except:
                    return None
        return None
    else:
        dr, _, _ = select.select([sys.stdin], [], [], 0)
        if dr:
            ch = sys.stdin.read(1)
            if ch == '\x1b':
                dr2, _, _ = select.select([sys.stdin], [], [], 0.05)
                if dr2:
                    seq = sys.stdin.read(2)
                    if seq == '[D': return 'left'
                    elif seq == '[C': return 'right'
                    elif seq == '[A': return 'up'
                    elif seq == '[B': return 'down'
                return 'esc'
            return ch.lower()
        return None

# ── Helper to find MPV ────────────────────────────────────────────────────────
def find_mpv():
    p = shutil.which('mpv')
    if p: return p
    candidates = [
        r'C:\Program Files\MPV Player\mpv.com',
        r'C:\Program Files\MPV Player\mpv.exe',
        r'C:\Program Files\mpv\mpv.exe',
        r'C:\Program Files (x86)\MPV Player\mpv.exe',
        os.path.expanduser(r'~\scoop\apps\mpv\current\mpv.exe'),
        '/usr/bin/mpv',
        '/usr/local/bin/mpv',
        '/opt/homebrew/bin/mpv',
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return 'mpv'

# ── Extract Video ID and Clean Metadata ───────────────────────────────────────
def extract_video_id(url):
    m = re.search(r'(?:v=|\/|be\/)([a-zA-Z0-9_-]{11})', url)
    return m.group(1) if m else None

def smart_parse(raw_title, raw_artist=None):
    """Accurately extracts clean track title and artist name."""
    artist = raw_artist.strip() if (raw_artist and raw_artist.strip() and raw_artist != 'Unknown Artist') else ''

    # Check for [duration • Artist, views] or similar bracketed metadata
    meta_m = re.search(r'\[(?:[0-9:]+\s*•\s*)?([^,\]]+)(?:,\s*[0-9.]+[KMBkmb]?\s*views)?\]', raw_title)
    if meta_m and not artist:
        candidate = meta_m.group(1).strip()
        candidate = re.sub(r' - Topic$|VEVO$| Official$| Records$', '', candidate, flags=re.I).strip()
        if candidate and candidate not in ('YouTube', 'Audio', 'Music'):
            artist = candidate

    # Strip bracket metadata from title: [3:57 • ...] or [Official Video]
    cleaned = re.sub(r'\[.*?\]', '', raw_title)
    # Strip common parenthetical tags
    cleaned = re.sub(r'\((?:Official|Lyrics?|HD|4K|Audio|Video|Music Video|Visualizer|Lyric Video|Remastered|Live)[^\)]*\)', '', cleaned, flags=re.I)
    cleaned = re.sub(r'[\(\[]\s*[\)\]]', '', cleaned)
    cleaned = re.sub(r'\s+', ' ', cleaned).strip()

    # Look for Artist - Title separators
    title = cleaned
    for sep in (' - ', ' – ', ' — ', ': '):
        if sep in cleaned:
            parts = cleaned.split(sep, 1)
            artist = parts[0].strip()
            title = parts[1].strip()
            break

    # Strip surrounding quotes
    title = title.strip('\"\'')
    artist = artist.strip('\"\'')

    # Build clean title for search (removing ft./feat. notes)
    clean_search = re.sub(r'\s*\(.*?\)', '', title)
    clean_search = re.sub(r'\s*\[.*?\]', '', clean_search)
    clean_search = re.sub(r'\s*(?:ft\.?|feat\.?)\s+.*$', '', clean_search, flags=re.I)
    clean_search = clean_search.strip(' \"\'')

    return title, artist, clean_search

# ── ANSI String Width Helpers ─────────────────────────────────────────────────
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]')

def visible_len(s):
    """Returns the true printable column width of an ANSI string."""
    return len(ANSI_RE.sub('', s))

def pad_visible(s, target_width, align='left'):
    """Pads or truncates an ANSI string to exact printable column width."""
    vlen = visible_len(s)
    if vlen >= target_width:
        if vlen == target_width:
            return s
        plain = ANSI_RE.sub('', s)
        truncated = plain[:max(0, target_width - 1)] + '…'
        return truncated + '\033[0m'
    diff = target_width - vlen
    if align == 'center':
        left = diff // 2
        right = diff - left
        return (' ' * left) + s + (' ' * right)
    elif align == 'right':
        return (' ' * diff) + s
    else: # left
        return s + (' ' * diff)

# ── Thumbnail / Cover Art Engine ──────────────────────────────────────────────
class CoverArtManager:
    def __init__(self, video_id):
        self.video_id = video_id
        self.pil_image = None
        self.loaded = False
        self.error = False
        self._load_image()

    def _load_image(self):
        try:
            from PIL import Image
        except ImportError:
            self.loaded = True
            return

        if not self.video_id:
            self.loaded = True
            return

        cache_dir = os.path.join(os.environ.get('TMPDIR', os.environ.get('TEMP', '/tmp')), 'every-cli', 'covers')
        os.makedirs(cache_dir, exist_ok=True)
        cache_file = os.path.join(cache_dir, f"{self.video_id}.jpg")

        img_data = None
        if os.path.exists(cache_file):
            try:
                with open(cache_file, 'rb') as f:
                    img_data = f.read()
            except:
                img_data = None

        if not img_data:
            for thumb_url in (f"https://i.ytimg.com/vi/{self.video_id}/maxresdefault.jpg",
                              f"https://i.ytimg.com/vi/{self.video_id}/hqdefault.jpg"):
                try:
                    req = urllib.request.Request(thumb_url, headers={'User-Agent': 'Mozilla/5.0'})
                    with urllib.request.urlopen(req, timeout=4) as resp:
                        if resp.status == 200:
                            img_data = resp.read()
                            with open(cache_file, 'wb') as f:
                                f.write(img_data)
                            break
                except:
                    continue

        if img_data:
            try:
                from PIL import Image
                img = Image.open(io.BytesIO(img_data)).convert('RGB')
                w, h = img.size
                # Center-crop to square
                min_dim = min(w, h)
                left = (w - min_dim) // 2
                top = (h - min_dim) // 2
                self.pil_image = img.crop((left, top, left + min_dim, top + min_dim))
            except:
                self.error = True

        self.loaded = True

    def render(self, cols, rows):
        """Renders the square cover art to exact (cols, rows) using TrueColor halfblocks."""
        if self.pil_image:
            try:
                from PIL import Image
                # Each terminal cell is 1 col wide and 2 vertical halfblock pixels high
                resized = self.pil_image.resize((cols, rows * 2), Image.Resampling.BILINEAR)
                lines = []
                for y in range(0, rows * 2, 2):
                    line_chars = []
                    for x in range(cols):
                        r1, g1, b1 = resized.getpixel((x, y))
                        r2, g2, b2 = resized.getpixel((x, y + 1))
                        line_chars.append(f'\033[38;2;{r1};{g1};{b1}m\033[48;2;{r2};{g2};{b2}m▀\033[0m')
                    lines.append(''.join(line_chars))
                return lines
            except:
                pass

        # Stylized ASCII Vinyl Record Fallback
        lines = []
        for r in range(rows):
            if r == 0 or r == rows - 1:
                lines.append(pad_visible("  ╭────────────────────────╮", cols, align='center'))
            elif r == rows // 2:
                lines.append(pad_visible("  │   ●   every-cli   ●   │", cols, align='center'))
            elif r == (rows // 2) - 1 or r == (rows // 2) + 1:
                lines.append(pad_visible("  │      ▄▄▄▄▄▄▄▄▄▄       │", cols, align='center'))
            else:
                lines.append(pad_visible("  │     ▀▀▀        ▀▀▀    │", cols, align='center'))
        return lines

# ── Lyrics Engine (LRCLIB + OVH) ──────────────────────────────────────────────
def parse_lrc_lines(lrc_text):
    """Parses timestamped [mm:ss.xx] LRC lyrics into sorted [(seconds, text)]."""
    lines = []
    for raw in lrc_text.splitlines():
        raw = raw.strip()
        matches = list(re.finditer(r'\[(\d+):(\d+\.?\d*)\]', raw))
        if matches:
            text = re.sub(r'\[\d+:\d+\.?\d*\]', '', raw).strip()
            for m in matches:
                mins = int(m.group(1))
                secs = float(m.group(2))
                lines.append((mins * 60.0 + secs, text))
    lines.sort(key=lambda x: x[0])
    return lines

def fetch_lyrics(title, artist, search_title):
    """Queries LRCLIB and fallback APIs for synchronized and plain lyrics."""
    lyrics_data = {'synced': False, 'lines': [], 'source': None}
    queries = []

    # Priority 1: Exact track + artist query
    if artist and search_title:
        queries.append(f"https://lrclib.net/api/get?track_name={urllib.parse.quote(search_title)}&artist_name={urllib.parse.quote(artist)}")
        queries.append(f"https://lrclib.net/api/search?track_name={urllib.parse.quote(search_title)}&artist_name={urllib.parse.quote(artist)}")
    # Priority 2: General queries with combined artist and title
    if artist and search_title:
        queries.append(f"https://lrclib.net/api/search?q={urllib.parse.quote(artist + ' ' + search_title)}")
    if search_title:
        queries.append(f"https://lrclib.net/api/search?q={urllib.parse.quote(search_title)}")
    if title and title != search_title:
        queries.append(f"https://lrclib.net/api/search?q={urllib.parse.quote(title)}")

    for url in queries:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'every-cli/1.0'})
            with urllib.request.urlopen(req, timeout=3.5) as res:
                payload = json.loads(res.read().decode('utf-8'))
                if isinstance(payload, list) and payload:
                    item = next((x for x in payload if x.get('syncedLyrics')), None)
                    if not item:
                        item = next((x for x in payload if x.get('plainLyrics')), None)
                elif isinstance(payload, dict):
                    item = payload if (payload.get('syncedLyrics') or payload.get('plainLyrics')) else None
                else:
                    item = None

                if item:
                    if item.get('syncedLyrics'):
                        parsed = parse_lrc_lines(item['syncedLyrics'])
                        if parsed:
                            lyrics_data['synced'] = True
                            lyrics_data['lines'] = parsed
                            lyrics_data['source'] = 'LRCLIB (Synced)'
                            return lyrics_data
                    elif item.get('plainLyrics'):
                        plain = [l.strip() for l in item['plainLyrics'].splitlines() if l.strip()]
                        if plain:
                            lyrics_data['synced'] = False
                            lyrics_data['lines'] = plain
                            lyrics_data['source'] = 'LRCLIB (Plain)'
                            return lyrics_data
        except:
            continue

    # Priority 3: Fallback to lyrics.ovh for plain lyrics
    if artist and search_title:
        try:
            ovh_url = f"https://api.lyrics.ovh/v1/{urllib.parse.quote(artist)}/{urllib.parse.quote(search_title)}"
            req = urllib.request.Request(ovh_url, headers={'User-Agent': 'every-cli/1.0'})
            with urllib.request.urlopen(req, timeout=3.0) as res:
                ovh_data = json.loads(res.read().decode('utf-8'))
                raw = ovh_data.get('lyrics')
                if raw:
                    plain = [l.strip() for l in raw.splitlines() if l.strip()]
                    if plain:
                        lyrics_data['synced'] = False
                        lyrics_data['lines'] = plain
                        lyrics_data['source'] = 'lyrics.ovh'
                        return lyrics_data
        except:
            pass

    return lyrics_data

# ── Format Time ───────────────────────────────────────────────────────────────
def fmt_time(seconds):
    if seconds is None or seconds < 0:
        return "00:00"
    m = int(seconds) // 60
    s = int(seconds) % 60
    return f"{m:02d}:{s:02d}"

# ── Main Terminal Music Player ────────────────────────────────────────────────
def main():
    if len(sys.argv) < 2:
        print("Usage: music_player.py <URL> [TITLE] [ARTIST]")
        sys.exit(1)

    url = sys.argv[1]
    raw_title = sys.argv[2] if len(sys.argv) > 2 else "Music Track"
    raw_artist = sys.argv[3] if len(sys.argv) > 3 else None

    video_id = extract_video_id(url)
    title, artist, search_title = smart_parse(raw_title, raw_artist)

    # Initialize Cover Art Manager & Lyrics Loader
    cover_mgr = CoverArtManager(video_id)
    lyrics_holder = {'data': None, 'loading': True}

    def load_lyrics_bg():
        res = fetch_lyrics(title, artist, search_title)
        lyrics_holder['data'] = res
        lyrics_holder['loading'] = False

    t_lyrics = threading.Thread(target=load_lyrics_bg, daemon=True)
    t_lyrics.start()

    # Setup MPV IPC
    pid = os.getpid()
    if IS_WIN:
        pipe_path = rf'\\.\pipe\mpv_music_{pid}'
    else:
        pipe_path = f'/tmp/mpv_music_{pid}.sock'

    mpv_bin = find_mpv()
    mpv_cmd = [
        mpv_bin,
        '--no-video',
        '--idle=yes',
        f'--input-ipc-server={pipe_path}',
        '--ytdl-format=bestaudio/best',
        '--ytdl-raw-options=extractor-args=youtube:player_client=android',
        '--msg-level=all=no',
        '--volume=80',
    ]

    proc = subprocess.Popen(mpv_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.35)

    pipe = None
    max_retries = 30
    for _ in range(max_retries):
        try:
            if IS_WIN:
                pipe = open(pipe_path, 'r+b', buffering=0)
            else:
                import socket
                pipe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                pipe.connect(pipe_path)
            break
        except:
            time.sleep(0.1)

    if not pipe:
        # Fallback to direct MPV execution if pipe failed
        proc.terminate()
        os.execvp(mpv_bin, [mpv_bin, '--no-video', '--ytdl-format=bestaudio/best', url])
        return

    ipc_lock = threading.Lock()
    req_id = [1]

    def ipc_cmd(command):
        with ipc_lock:
            rid = req_id[0]
            req_id[0] += 1
            payload = json.dumps({'command': command, 'request_id': rid}) + '\n'
            try:
                if IS_WIN:
                    pipe.write(payload.encode('utf-8'))
                    while True:
                        line = pipe.readline().decode('utf-8', errors='ignore').strip()
                        if not line: return None
                        try:
                            msg = json.loads(line)
                            if msg.get('request_id') == rid:
                                return msg
                        except: pass
                else:
                    pipe.sendall(payload.encode('utf-8'))
                    buf = ''
                    while True:
                        chunk = pipe.recv(1024).decode('utf-8', errors='ignore')
                        if not chunk: return None
                        buf += chunk
                        if '\n' in buf:
                            lines = buf.split('\n')
                            for l in lines[:-1]:
                                try:
                                    msg = json.loads(l)
                                    if msg.get('request_id') == rid:
                                        return msg
                                except: pass
                            buf = lines[-1]
            except:
                return None

    # Start playback in MPV
    ipc_cmd(['loadfile', url])

    # Save original terminal settings on Unix
    orig_settings = None
    if not IS_WIN and sys.stdin.isatty():
        orig_settings = termios.tcgetattr(sys.stdin)
        tty.setcbreak(sys.stdin.fileno())

    # Enter Alternate Screen Buffer & hide cursor
    if sys.stdout.isatty():
        sys.stdout.write('\033[?1049h\033[?25l\033[2J\033[H')
        sys.stdout.flush()

    try:
        cur_pos = 0.0
        duration = None
        volume = 80
        paused = False
        plain_scroll_idx = 0
        last_sec = -1
        last_term_size = (0, 0)

        while proc.poll() is None:
            # Poll MPV status
            pos_resp = ipc_cmd(['get_property', 'time-pos'])
            if pos_resp and pos_resp.get('data') is not None:
                cur_pos = float(pos_resp['data'])

            dur_resp = ipc_cmd(['get_property', 'duration'])
            if dur_resp and dur_resp.get('data') is not None:
                duration = float(dur_resp['data'])

            vol_resp = ipc_cmd(['get_property', 'volume'])
            if vol_resp and vol_resp.get('data') is not None:
                volume = int(vol_resp['data'])

            pause_resp = ipc_cmd(['get_property', 'pause'])
            if pause_resp and pause_resp.get('data') is not None:
                paused = bool(pause_resp['data'])

            # Handle keyboard input
            key = get_key()
            if key == 'q':
                break
            elif key == ' ':
                ipc_cmd(['cycle', 'pause'])
                paused = not paused
            elif key in ('9', '-'):
                ipc_cmd(['add', 'volume', -5])
            elif key in ('0', '+', '='):
                ipc_cmd(['add', 'volume', 5])
            elif key == 'm':
                ipc_cmd(['cycle', 'mute'])
            elif key == 'left':
                ipc_cmd(['seek', -5])
            elif key == 'right':
                ipc_cmd(['seek', 5])
            elif key == 'down':
                ipc_cmd(['seek', -30])
            elif key == 'up':
                ipc_cmd(['seek', 30])

            # ── Dynamic Responsive Dimensions ────────────────────────────────
            term_w, term_h = shutil.get_terminal_size((96, 28))

            # Detect terminal resize and wipe frame buffer cleanly
            is_resized = ((term_w, term_h) != last_term_size) or winch_resized[0]
            if is_resized:
                winch_resized[0] = False
                last_term_size = (term_w, term_h)
                sys.stdout.write('\033[2J\033[H')
                sys.stdout.flush()

            # Constrain total target width to fit terminal comfortably
            target_w = min(120, max(74, term_w - 4))

            # Prevent frame from exceeding terminal height (avoids scrollback spill)
            max_box_rows = max(6, term_h - 11)

            # Calculate album art dimensions (proportional square in terminal halfblocks)
            if term_h >= 34 and target_w >= 110:
                art_cols = 36
                art_rows = 18
            elif term_h >= 28 and target_w >= 96:
                art_cols = 32
                art_rows = 16
            elif term_h >= 24 and target_w >= 84:
                art_cols = 28
                art_rows = 14
            else:
                art_cols = 24
                art_rows = 12

            art_rows = min(max_box_rows, art_rows)
            box_rows = art_rows

            # Lyrics box consumes the remaining width
            lyrics_cols = max(36, target_w - art_cols - 7)

            # Render Album Cover Art lines
            cover_lines = cover_mgr.render(art_cols, art_rows)

            # ── Render Lyrics Lines ──────────────────────────────────────────
            lyrics = lyrics_holder.get('data')
            is_loading = lyrics_holder.get('loading', True)
            lyrics_display = []

            if is_loading:
                for r in range(box_rows):
                    if r == box_rows // 2:
                        lyrics_display.append(pad_visible("  \033[38;5;244m⠋ Searching lyrics...\033[0m", lyrics_cols, align='center'))
                    else:
                        lyrics_display.append(pad_visible("", lyrics_cols))

            elif lyrics and lyrics.get('synced') and lyrics.get('lines'):
                # Synchronized karaoke scrolling view
                all_lines = lyrics['lines']
                active_idx = -1
                for idx, (t, txt) in enumerate(all_lines):
                    if t <= cur_pos + 0.3:
                        active_idx = idx
                    else:
                        break

                # Center the currently singing line in the box
                half_box = box_rows // 2
                start_row = max(0, active_idx - half_box)
                end_row = min(len(all_lines), start_row + box_rows)
                if (end_row - start_row) < box_rows and start_row > 0:
                    start_row = max(0, end_row - box_rows)

                for r in range(box_rows):
                    line_idx = start_row + r
                    if 0 <= line_idx < len(all_lines):
                        t, txt = all_lines[line_idx]
                        if line_idx == active_idx:
                            # Prominently highlight current sung line with bright color & marker
                            item = f"\033[1;38;5;231m\033[48;5;237m ▶ {txt} \033[0m"
                        elif line_idx < active_idx:
                            # Dim past sung lines
                            item = f"  \033[38;5;243m{txt}\033[0m"
                        else:
                            # Upcoming lines in clean silver
                            item = f"  \033[38;5;251m{txt}\033[0m"
                        lyrics_display.append(pad_visible(item, lyrics_cols))
                    else:
                        lyrics_display.append(pad_visible("", lyrics_cols))

            elif lyrics and not lyrics.get('synced') and lyrics.get('lines'):
                # Plain unsynchronized lyrics with progress-based smooth scrolling
                all_lines = lyrics['lines']
                if int(cur_pos) != last_sec and duration:
                    last_sec = int(cur_pos)
                    plain_scroll_idx = int((cur_pos / max(1.0, duration)) * max(1, len(all_lines) - box_rows))

                for r in range(box_rows):
                    idx = plain_scroll_idx + r
                    if idx < len(all_lines):
                        item = f"  \033[38;5;250m{all_lines[idx]}\033[0m"
                        lyrics_display.append(pad_visible(item, lyrics_cols))
                    else:
                        lyrics_display.append(pad_visible("", lyrics_cols))

            else:
                # Clean, minimal state when no lyrics are found (zero fake filler text)
                for r in range(box_rows):
                    if r == box_rows // 2:
                        lyrics_display.append(pad_visible("\033[38;5;244mNo synchronized lyrics available for this track\033[0m", lyrics_cols, align='center'))
                    else:
                        lyrics_display.append(pad_visible("", lyrics_cols))

            # ── Assemble Output Buffer ───────────────────────────────────────
            buf = []
            buf.append("\033[H")  # Move cursor to top-left

            # Top Header Bar
            header_inner = target_w - 2
            h_left = "  \033[38;5;141m♪\033[0m \033[1;37mevery-cli\033[0m \033[38;5;244m• Music\033[0m"
            state_text = "\033[38;5;214m⏸ Paused\033[0m" if paused else "\033[38;5;48m● Playing\033[0m"
            h_right = f"{state_text}   \033[38;5;45m🔊 {volume}%\033[0m  "

            h_spaces = header_inner - visible_len(h_left) - visible_len(h_right)
            h_line = h_left + (' ' * max(1, h_spaces)) + h_right

            buf.append(f"  \033[38;5;240m╭{'─' * header_inner}╮\033[0m\033[K")
            buf.append(f"  \033[38;5;240m│\033[0m{h_line}\033[38;5;240m│\033[0m\033[K")
            buf.append(f"  \033[38;5;240m╰{'─' * header_inner}╯\033[0m\033[K")

            # Main Body: Cover Art (Left) & Lyrics (Right)
            art_box_w = art_cols + 2
            lyrics_box_w = lyrics_cols + 2

            art_top = "╭── ALBUM ART " + ("─" * max(0, art_box_w - 14)) + "╮"
            lyrics_top = "╭── LYRICS " + ("─" * max(0, lyrics_box_w - 11)) + "╮"
            buf.append(f"  \033[38;5;240m{art_top} {lyrics_top}\033[0m\033[K")

            for r in range(box_rows):
                c_cell = cover_lines[r] if r < len(cover_lines) else (" " * art_cols)
                l_cell = lyrics_display[r] if r < len(lyrics_display) else pad_visible("", lyrics_cols)
                buf.append(f"  \033[38;5;240m│\033[0m {c_cell} \033[38;5;240m│\033[0m \033[38;5;240m│\033[0m {l_cell} \033[38;5;240m│\033[0m\033[K")

            art_bot = "╰" + ("─" * art_box_w) + "╯"
            lyrics_bot = "╰" + ("─" * lyrics_box_w) + "╯"
            buf.append(f"  \033[38;5;240m{art_bot} {lyrics_bot}\033[0m\033[K")

            # Track Metadata Info
            display_title = title if title else "Track"
            display_artist = f"\033[38;5;244m•\033[0m  \033[38;5;141m{artist}\033[0m" if artist else ""
            meta_line = f"  \033[1;37m{display_title}\033[0m  {display_artist}"
            buf.append(f"{meta_line}\033[K")

            # Progress Bar
            pos_str = fmt_time(cur_pos)
            dur_str = fmt_time(duration)
            pct = int((cur_pos / max(1.0, duration or 1.0)) * 100) if duration else 0
            bar_len = max(20, target_w - 24)
            filled = int((pct / 100.0) * bar_len) if duration else 0
            empty = max(0, bar_len - filled - 1)
            pbar = f"\033[38;5;141m{'━' * filled}●\033[38;5;240m{'─' * empty}\033[0m"

            buf.append(f"  {pos_str}  {pbar}  {dur_str}  \033[38;5;244m({pct}%)\033[0m\033[K")
            buf.append("")

            # Keyboard Controls Bar
            controls = "  \033[38;5;245m[Space] Play/Pause    [9/0] Volume    [←/→] Seek ±5s    [q] Return\033[0m"
            buf.append(f"{controls}\033[K")
            buf.append("\033[J")  # Clear any remaining lines below

            # Flush frame to terminal without trailing newline (prevents scrolling)
            sys.stdout.write('\033[H' + '\n'.join(buf))
            sys.stdout.flush()

            time.sleep(0.10)

    except KeyboardInterrupt:
        pass
    finally:
        # Cleanup MPV and restore terminal state
        try:
            ipc_cmd(['quit'])
        except:
            pass
        try:
            proc.terminate()
        except:
            pass
        if pipe:
            try: pipe.close()
            except: pass
        if not IS_WIN and orig_settings and sys.stdin.isatty():
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, orig_settings)
        if sys.stdout.isatty():
            sys.stdout.write('\033[?1049l\033[?25h')
            sys.stdout.flush()
        print("\n  \033[38;5;141m◆\033[0m \033[38;5;244mPlayback ended.\033[0m\n")

if __name__ == '__main__':
    main()
