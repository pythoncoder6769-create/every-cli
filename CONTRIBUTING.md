# Contributing to every-cli

Thank you for your interest in contributing to every-cli!

## Development Setup

1. Clone the repo:
   ```sh
   git clone https://github.com/pythoncoder6769-create/every-cli.git
   cd every-cli
   ```

2. Install dependencies:
   - **Linux**: `sudo apt install curl fzf mpv yt-dlp ffmpeg`
   - **macOS**: `brew install curl fzf mpv yt-dlp ffmpeg`
   - **Windows**: `scoop install git fzf mpv yt-dlp ffmpeg`

3. Run directly:
   ```sh
   ./every-cli -c youtube "test"
   ```

## Guidelines

- All shell code must be **POSIX sh** compatible (no bashisms)
- Use `do_curl` / `retry_curl` for ALL HTTP requests (never bare curl)
- Maintain the exact User-Agent string from ani-cli
- Every scraper must handle failure gracefully and return non-zero
- Provider fallback chains must always end with YouTube
- Test on both Linux and Windows 11 Git Bash
- Use `"$HOME"` not `~` in all paths
- Avoid `sed -i` (not portable); use temp files instead

## Adding a New Source

1. Create `lib/scrapers/yoursource.sh` with `search()`, `episodes()`, and `stream()` functions
2. Add it to the appropriate provider in `lib/providers/`
3. Insert it in the fallback chain (before YouTube)
4. Test the full chain with `sh -x every-cli -c <category> "query"`

## Reporting Issues

When reporting a broken source, include:
- The exact command you ran
- Output of `sh -x every-cli ...` (verbose mode)
- Your OS and shell version
