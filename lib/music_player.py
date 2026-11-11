#!/usr/bin/env python3
"""
lib/music_player.py — Native Terminal Music Player for every-cli

Features:
- TrueColor (24-bit) halfblock album cover art (▀) directly in the terminal
- Real-time synchronized lyrics via LRCLIB (scrolling & active line karaoke highlight)
- Interactive keyboard controls (Space, 9/0, m, Left/Right seek, q)
- MPV IPC control over named pipes (Windows) / Unix domain sockets (Linux/macOS)
- Responsive side-by-side terminal UI layout
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

def parse_title_artist(raw_title):
    # Remove junk tags like (Official Video), (Lyrics), etc.
    cleaned = re.sub(r'[\(\[](?:Official|Lyrics?|HD|4K|Audio|Video|Music Video|Visualizer|Lyric Video)[^\)\]]*[\)\]]', '', raw_title, flags=re.IGNORECASE).strip()
    cleaned = re.sub(r'\s+', ' ', cleaned).strip()
    artist, title = '', cleaned
    for sep in (' - ', ' – ', ': '):
        if sep in cleaned:
            parts = cleaned.split(sep, 1)
            artist = parts[0].strip()
            title = parts[1].strip()
            break
    return title, artist

# ── Thumbnail / Cover Art Engine ──────────────────────────────────────────────
def generate_cover_art(video_id, cols=24, rows=12):
    """Generates TrueColor ANSI halfblock (▀) lines representing album artwork."""
    try:
        from PIL import Image
    except ImportError:
        # Fallback ASCII Art vinyl when PIL is not available
        return [
            "  ╭────────────────────╮  ",
            "  │     ▄▄▄▄▄▄▄▄▄▄     │  ",
            "  │   ▄▀▀        ▀▀▄   │  ",
            "  │  ▄▀   ▄▄▄▄▄▄   ▀▄  │  ",
            "  │ █    █  ██  █    █ │  ",
            "  │ █    █  ██  █    █ │  ",
            "  │  ▀▄   ▀▀▀▀▀▀   ▄▀  │  ",
            "  │   ▀▄▄        ▄▄▀   │  ",
            "  │     ▀▀▀▀▀▀▀▀▀▀     │  ",
            "  │   every-cli  audio │  ",
            "  ╰────────────────────╯  ",
            "                          ",
        ]

    cache_dir = os.path.join(os.environ.get('TMPDIR', os.environ.get('TEMP', '/tmp')), 'every-cli', 'covers')
    os.makedirs(cache_dir, exist_ok=True)
    cache_file = os.path.join(cache_dir, f"{video_id}.jpg") if video_id else None

    img_data = None
    if cache_file and os.path.exists(cache_file):
        try:
            with open(cache_file, 'rb') as f:
                img_data = f.read()
        except:
            img_data = None

    if not img_data and video_id:
        for thumb_url in (f"https://i.ytimg.com/vi/{video_id}/maxresdefault.jpg",
                          f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg"):
            try:
                req = urllib.request.Request(thumb_url, headers={'User-Agent': 'Mozilla/5.0'})
                with urllib.request.urlopen(req, timeout=4) as resp:
                    if resp.status == 200:
                        img_data = resp.read()
                        if cache_file:
                            with open(cache_file, 'wb') as f:
                                f.write(img_data)
                        break
            except:
                continue

    if not img_data:
        # Placeholder vinyl
        return [
            "  \033[38;5;141m╭────────────────────╮\033[0m  ",
            "  \033[38;5;141m│\033[0m   \033[38;5;244m▄▄▄▄▄▄▄▄▄▄▄▄▄▄   \033[38;5;141m│\033[0m  ",
            "  \033[38;5;141m│\033[0m  \033[38;5;248m▄▀▀          ▀▀▄ \033[38;5;141m│\033[0m  ",
            "  \033[38;5;141m│\033[0m \033[38;5;252m▄▀   \033[38;5;51m▄▄▄▄▄▄\033[0m   \033[38;5;252m▀▄\033[0m\033[38;5;141m│\033[0m  ",
            "  \033[38;5;141m│\033[0m \033[38;5;255m█    \033[38;5;51m█  ██  █\033[0m    \033[38;5;255m█\033[0m\033[38;5;141m│\033[0m  ",
            "  \033[38;5;141m│\033[0m \033[38;5;255m█    \033[38;5;51m█  ██  █\033[0m    \033[38;5;255m█\033[0m\033[38;5;141m│\033[0m  ",
            "  \033[38;5;141m│\033[0m \033[38;5;252m▀▄   \033[38;5;51m▀▀▀▀▀▀\033[0m   \033[38;5;252m▄▀\033[0m\033[38;5;141m│\033[0m  ",
            "  \033[38;5;141m│\033[0m  \033[38;5;248m▀▄▄          ▄▄▀ \033[38;5;141m│\033[0m  ",
            "  \033[38;5;141m│\033[0m   \033[38;5;244m▀▀▀▀▀▀▀▀▀▀▀▀▀▀   \033[38;5;141m│\033[0m  ",
            "  \033[38;5;141m│\033[0m   \033[38;5;220m♪ High-Res Audio \033[38;5;141m│\033[0m  ",
            "  \033[38;5;141m╰────────────────────╯\033[0m  ",
            "                          ",
        ]

    try:
        img = Image.open(io.BytesIO(img_data)).convert('RGB')
        w, h = img.size
        # Trim black bars
        min_dim = min(w, h)
        left = (w - min_dim) // 2
        top = (h - min_dim) // 2
        img = img.crop((left, top, left + min_dim, top + min_dim))
        img = img.resize((cols, rows * 2), Image.Resampling.BILINEAR)

        lines = []
        for y in range(0, rows * 2, 2):
            line_str = ''
            for x in range(cols):
                r1, g1, b1 = img.getpixel((x, y))
                r2, g2, b2 = img.getpixel((x, y + 1))
                line_str += f'\033[38;2;{r1};{g1};{b1}m\033[48;2;{r2};{g2};{b2}m▀\033[0m'
            lines.append(line_str)
        return lines
    except:
        return ["  [Cover Art Error]       "] * rows

# ── Lyrics Engine (LRCLIB) ───────────────────────────────────────────────────
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

def fetch_lyrics(title, artist=''):
    """Queries LRCLIB for synchronized and plain lyrics."""
    lyrics_data = {'synced': False, 'lines': []}
    queries = []
    if artist:
        queries.append(f"https://lrclib.net/api/get?track_name={urllib.parse.quote(title)}&artist_name={urllib.parse.quote(artist)}")
    queries.append(f"https://lrclib.net/api/search?q={urllib.parse.quote((artist + ' ' + title).strip())}")

    for url in queries:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'every-cli/1.0 (terminal music center)'})
            with urllib.request.urlopen(req, timeout=4) as res:
                payload = json.loads(res.read().decode('utf-8'))
                if isinstance(payload, list):
                    item = next((x for x in payload if x.get('syncedLyrics') or x.get('plainLyrics')), None)
                else:
                    item = payload if (payload.get('syncedLyrics') or payload.get('plainLyrics')) else None

                if item:
                    if item.get('syncedLyrics'):
                        parsed = parse_lrc_lines(item['syncedLyrics'])
                        if parsed:
                            lyrics_data['synced'] = True
                            lyrics_data['lines'] = parsed
                            return lyrics_data
                    elif item.get('plainLyrics'):
                        plain = [l.strip() for l in item['plainLyrics'].splitlines() if l.strip()]
                        if plain:
                            lyrics_data['synced'] = False
                            lyrics_data['lines'] = plain
                            return lyrics_data
        except:
            continue
    return lyrics_data

# ── Format Time ───────────────────────────────────────────────────────────────
def fmt_time(seconds):
    if seconds is None or seconds < 0:
        return "--:--"
    m = int(seconds) // 60
    s = int(seconds) % 60
    return f"{m:02d}:{s:02d}"

# ── Main Terminal Music Player ────────────────────────────────────────────────
def main():
    if len(sys.argv) < 2:
        print("Usage: music_player.py <URL> [TITLE]")
        sys.exit(1)

    url = sys.argv[1]
    raw_title = sys.argv[2] if len(sys.argv) > 2 else "Music Track"

    video_id = extract_video_id(url)
    title, artist = parse_title_artist(raw_title)

    # Background loading of cover art & lyrics
    cover_holder = {'lines': None}
    lyrics_holder = {'data': None}

    def load_cover():
        cover_holder['lines'] = generate_cover_art(video_id, cols=24, rows=12)

    def load_lyrics():
        lyrics_holder['data'] = fetch_lyrics(title, artist)

    t1 = threading.Thread(target=load_cover, daemon=True)
    t2 = threading.Thread(target=load_lyrics, daemon=True)
    t1.start()
    t2.start()

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
    time.sleep(0.4)

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
        # Fallback to direct mpv
        proc.terminate()
        os.execvp(mpv_bin, [mpv_bin, '--no-video', '--ytdl-format=bestaudio/best', url])
        return

    # IPC communicator
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

    # Start playback
    ipc_cmd(['loadfile', url])

    # Save original terminal settings on Unix
    orig_settings = None
    if not IS_WIN and sys.stdin.isatty():
        orig_settings = termios.tcgetattr(sys.stdin)
        tty.setcbreak(sys.stdin.fileno())

    # Hide cursor
    if sys.stdout.isatty():
        sys.stdout.write('\033[?25l\033[2J\033[H')
        sys.stdout.flush()

    try:
        cur_pos = 0.0
        duration = None
        volume = 80
        paused = False
        plain_scroll_idx = 0
        last_second = -1

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

            # Handle user keys
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

            # Prepare visual components
            term_w = shutil.get_terminal_size((80, 24)).columns

            # Cover Art Lines (12 rows, 24 cols)
            cover_lines = cover_holder.get('lines')
            if not cover_lines:
                cover_lines = ["  \033[38;5;244m⠋ Loading Cover Art...\033[0m "] * 12

            # Lyrics Lines (12 rows, ~44 cols)
            lyrics = lyrics_holder.get('data')
            lyrics_display = []

            if not lyrics:
                lyrics_display = [
                    "",
                    "  \033[38;5;244m⠋ Fetching Lyrics from LRCLIB...\033[0m",
                    "",
                    "  \033[38;5;240mStreaming 320kbps High-Fidelity Audio\033[0m",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                ]
            elif lyrics['synced'] and lyrics['lines']:
                # Synchronized karaoke view
                all_lines = lyrics['lines']
                active_idx = -1
                for idx, (t, txt) in enumerate(all_lines):
                    if t <= cur_pos + 0.3:
                        active_idx = idx
                    else:
                        break

                # Show 4 lines before, active line, and 4 lines after (total 9 rows)
                start_row = max(0, active_idx - 4)
                end_row = min(len(all_lines), start_row + 9)
                if end_row - start_row < 9 and start_row > 0:
                    start_row = max(0, end_row - 9)

                lyrics_display.append("\033[38;5;141m  ♪ Synchronized Lyrics (LRCLIB)\033[0m")
                for i in range(start_row, end_row):
                    t, txt = all_lines[i]
                    txt_trunc = txt[:42]
                    if i == active_idx:
                        # Active sung line highlighted in bold white with pill marker
                        lyrics_display.append(f"  \033[1;37m\033[48;5;236m ▶ {txt_trunc:<42} \033[0m")
                    elif i < active_idx:
                        # Past lines faded
                        lyrics_display.append(f"  \033[38;5;242m   {txt_trunc:<42}\033[0m")
                    else:
                        # Upcoming lines
                        lyrics_display.append(f"  \033[38;5;250m   {txt_trunc:<42}\033[0m")
                while len(lyrics_display) < 12:
                    lyrics_display.append("")

            elif not lyrics['synced'] and lyrics['lines']:
                # Plain lyrics scroll view
                all_lines = lyrics['lines']
                if int(cur_pos) != last_second and duration:
                    last_second = int(cur_pos)
                    plain_scroll_idx = int((cur_pos / max(1, duration)) * max(1, len(all_lines) - 9))

                lyrics_display.append("\033[38;5;220m  ♪ Plain Lyrics\033[0m")
                for l in all_lines[plain_scroll_idx:plain_scroll_idx + 9]:
                    lyrics_display.append(f"  \033[38;5;250m{l[:44]:<44}\033[0m")
                while len(lyrics_display) < 12:
                    lyrics_display.append("")
            else:
                lyrics_display = [
                    "",
                    "  \033[38;5;244m♪ Instrumental or No Lyrics Found\033[0m",
                    "",
                    "  \033[38;5;51mHigh-Fidelity Audio Stream Active\033[0m",
                    "  \033[38;5;242mLRCLIB Database checked for metadata\033[0m",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                ]

            # ── Render Frame Buffer ──────────────────────────────────────────
            buf = []
            buf.append("\033[H")  # Cursor home

            # Top Header Bar
            buf.append("  \033[38;5;243m╭────────────────────────────────────────────────────────────────────────╮\033[0m")
            buf.append("  \033[38;5;243m│\033[0m  \033[38;5;141m♪\033[0m \033[1;37mevery-cli\033[0m \033[38;5;243m• Music Player\033[0m           \033[38;5;48m● 320kbps Audio (Max Quality)\033[0m  \033[38;5;243m│\033[0m")
            buf.append("  \033[38;5;243m╰────────────────────────────────────────────────────────────────────────╯\033[0m")

            # Main Body: Cover Art (Left) & Lyrics (Right)
            buf.append("  \033[38;5;243m╭── ALBUM ART ──────────╮\033[0m \033[38;5;243m╭── LYRICS & DETAILS ──────────────────────────╮\033[0m")

            for r in range(12):
                c_line = cover_lines[r] if r < len(cover_lines) else (" " * 24)
                l_line = lyrics_display[r] if r < len(lyrics_display) else ""
                buf.append(f"  \033[38;5;243m│\033[0m {c_line} \033[38;5;243m│\033[0m \033[38;5;243m│\033[0m {l_line:<46} \033[38;5;243m│\033[0m")

            buf.append("  \033[38;5;243m╰───────────────────────╯\033[0m \033[38;5;243m╰──────────────────────────────────────────────╯\033[0m")

            # Metadata Info Row
            t_short = title[:34]
            a_short = (artist if artist else "Unknown Artist")[:34]
            state_badge = "\033[38;5;214m[⏸ PAUSED]\033[0m" if paused else "\033[38;5;48m[▶ PLAYING]\033[0m"
            buf.append(f"   \033[1;37m{t_short:<36}\033[0m  \033[38;5;45m🔊 Vol: {volume:>3}%\033[0m    {state_badge}")
            buf.append(f"   \033[38;5;244m{a_short:<36}\033[0m  \033[38;5;141m⚡ YouTube 320k Direct Audio\033[0m")

            # Progress Bar
            pos_str = fmt_time(cur_pos)
            dur_str = fmt_time(duration)
            pct = int((cur_pos / max(1.0, duration or 1.0)) * 100) if duration else 0
            bar_len = 36
            filled = int((pct / 100.0) * bar_len) if duration else 0
            empty = bar_len - filled
            pbar = f"\033[38;5;141m{'━' * filled}●\033[38;5;240m{'─' * max(0, empty - 1)}\033[0m"

            buf.append(f"   {pos_str}  {pbar}  {dur_str}  \033[38;5;244m({pct:>2}%)\033[0m")
            buf.append("")
            buf.append("   \033[38;5;244m[Space] Pause  [9/0] Volume  [←/→] Seek ±5s  [m] Mute  [q] Quit\033[0m")

            # Write buffer to screen
            sys.stdout.write('\n'.join(buf) + '\n')
            sys.stdout.flush()

            time.sleep(0.12)

    except KeyboardInterrupt:
        pass
    finally:
        # Restore terminal & close MPV
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
            sys.stdout.write('\033[?25h\033[2J\033[H')
            sys.stdout.flush()
        print("\n  \033[38;5;141m◆\033[0m \033[38;5;244mPlayback ended.\033[0m\n")

if __name__ == '__main__':
    main()
