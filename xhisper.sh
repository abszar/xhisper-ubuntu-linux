#!/bin/bash

# xhisper v1.2 - Push-to-talk
# Dictate anywhere in Linux. Transcription at your cursor.
# Hold your shortcut key to record, release to transcribe.

# Requirements:
# - pipewire, pipewire-utils (audio)
# - wl-clipboard (Wayland) or xclip (X11) for clipboard
# - jq, curl, ffmpeg (processing)
# - python3 with libX11 (for key release detection)

[ -f "$HOME/.env" ] && source "$HOME/.env"

# Parse command-line arguments
LOCAL_MODE=0
WRAP_KEY=""
for arg in "$@"; do
  case "$arg" in
    --local)
      LOCAL_MODE=1
      ;;
    --log)
      if [ -f "/tmp/xhisper.log" ]; then
        cat /tmp/xhisper.log
      else
        echo "No log file found at /tmp/xhisper.log" >&2
      fi
      exit 0
      ;;
    --leftalt|--rightalt|--leftctrl|--rightctrl|--leftshift|--rightshift|--super)
      if [ -n "$WRAP_KEY" ]; then
        echo "Error: Multiple wrap keys not yet supported" >&2
        exit 1
      fi
      WRAP_KEY="${arg#--}"
      ;;
    *)
      echo "Error: Unknown option '$arg'" >&2
      echo "Usage: xhisper [--local] [--log] [--leftalt|--rightalt|--leftctrl|--rightctrl|--leftshift|--rightshift|--super]" >&2
      exit 1
      ;;
  esac
done

# Set binary paths based on local mode
if [ "$LOCAL_MODE" -eq 1 ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  XHISPERTOOL="$SCRIPT_DIR/xhispertool"
  XHISPERTOOLD="$SCRIPT_DIR/xhispertoold"
  XHISPER_NOTIFY="$SCRIPT_DIR/xhisper-notify"
else
  XHISPERTOOL="xhispertool"
  XHISPERTOOLD="xhispertoold"
  XHISPER_NOTIFY="xhisper-notify"
fi

RECORDING="/tmp/xhisper.wav"
LOGFILE="/tmp/xhisper.log"
PIDFILE="/tmp/xhisper.pid"
PROCESS_PATTERN="pw-record.*$RECORDING"

# Prevent concurrent execution with PID file
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    # Another instance is still running, ignore this press
    exit 0
  fi
  # Stale PID file, remove it
  rm -f "$PIDFILE"
fi
echo $$ > "$PIDFILE"

# Default configuration
long_recording_threshold=1000
transcription_prompt=""
silence_threshold=-50
silence_percentage=95
non_ascii_initial_delay=0.1
non_ascii_default_delay=0.025
target_language="French"

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/xhisper/xhisperrc"

if [ -f "$CONFIG_FILE" ]; then
  while IFS=: read -r key value || [ -n "$key" ]; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
    case "$key" in
      long-recording-threshold) long_recording_threshold="$value" ;;
      transcription-prompt) transcription_prompt="$value" ;;
      silence-threshold) silence_threshold="$value" ;;
      silence-percentage) silence_percentage="$value" ;;
      non-ascii-initial-delay) non_ascii_initial_delay="$value" ;;
      non-ascii-default-delay) non_ascii_default_delay="$value" ;;
      target-language) target_language="$value" ;;
    esac
  done < "$CONFIG_FILE"
fi

# Auto-start daemon if not running
if ! pgrep -x xhispertoold > /dev/null; then
    "$XHISPERTOOLD" 2>> /tmp/xhispertoold.log &
    sleep 1
    if ! pgrep -x xhispertoold > /dev/null; then
        echo "Error: Failed to start xhispertoold daemon" >&2
        exit 1
    fi
fi

# Check if xhispertool is available
if ! command -v "$XHISPERTOOL" &> /dev/null; then
    echo "Error: xhispertool not found" >&2
    exit 1
fi

# Detect clipboard tool
if command -v wl-copy &> /dev/null; then
    CLIP_COPY="wl-copy"
    CLIP_PASTE="wl-paste"
elif command -v xclip &> /dev/null; then
    CLIP_COPY="xclip -selection clipboard"
    CLIP_PASTE="xclip -o -selection clipboard"
else
    echo "Error: No clipboard tool found." >&2
    exit 1
fi

press_wrap_key() {
  if [ -n "$WRAP_KEY" ]; then
    "$XHISPERTOOL" "$WRAP_KEY"
  fi
}

paste() {
  local text="$1"
  press_wrap_key
  echo -n "$text" | $CLIP_COPY
  sleep 0.05
  "$XHISPERTOOL" paste
  sleep 0.05
  if command -v copyq &> /dev/null; then
    copyq remove 0 &>/dev/null &
  fi
  press_wrap_key
}

# Status overlay (animated wave pill, falls back to notify-send)
show_status() {
  if command -v "$XHISPER_NOTIFY" &> /dev/null; then
    "$XHISPER_NOTIFY" "$@" &
  else
    case "$1" in
      recording)    notify-send -a xhisper "xhisper" "Recording..." -t 30000 ;;
      transcribing) notify-send -a xhisper "xhisper" "Transcribing..." -t 30000 ;;
      translating)  notify-send -a xhisper "xhisper" "Translating..." -t 30000 ;;
      done)         notify-send -a xhisper "xhisper" "Done" -t 1000 ;;
      silent)       notify-send -a xhisper "xhisper" "No sound detected" -t 2000 ;;
    esac
  fi
}

hide_status() {
  if command -v "$XHISPER_NOTIFY" &> /dev/null; then
    "$XHISPER_NOTIFY" hide 2>/dev/null
  fi
}

get_duration() {
  local recording="$1"
  ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$recording" 2>/dev/null || echo "0"
}

is_silent() {
  local recording="$1"
  local vol_stats=$(ffmpeg -i "$recording" -af "volumedetect" -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume")
  local max_vol=$(echo "$vol_stats" | grep "max_volume" | awk '{print $5}')
  if [ -n "$max_vol" ]; then
    local is_quiet=$(echo "$max_vol < $silence_threshold" | bc -l)
    [ "$is_quiet" -eq 1 ] && return 0
  fi
  return 1
}

logging_end_and_write_to_logfile() {
  local title="$1"
  local result="$2"
  local logging_start="$3"
  local logging_end=$(date +%s%N)
  local time=$(echo "scale=3; ($logging_end - $logging_start) / 1000000000" | bc)
  echo "=== $title ===" >> "$LOGFILE"
  echo "Result: [$result]" >> "$LOGFILE"
  echo "Time: ${time}s" >> "$LOGFILE"
}

transcribe() {
  local recording="$1"
  local logging_start=$(date +%s%N)
  local is_long_recording=$(echo "$(get_duration "$recording") > $long_recording_threshold" | bc -l)
  local model=$([[ $is_long_recording -eq 1 ]] && echo "whisper-large-v3" || echo "whisper-large-v3-turbo")

  local transcription=$(curl -s -X POST "https://api.groq.com/openai/v1/audio/transcriptions" \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: multipart/form-data" \
    -F "file=@$recording" \
    -F "model=$model" \
    -F "language=en" \
    -F "prompt=$transcription_prompt" \
    | jq -r '.text' | sed 's/^ //')

  logging_end_and_write_to_logfile "Transcription" "$transcription" "$logging_start"
  echo "$transcription"
}

translate_text() {
  local raw_text="$1"
  local formality="$2"
  local lang="$3"
  local logging_start=$(date +%s%N)

  local style_instruction
  if [ "$formality" = "formal" ]; then
    style_instruction="Use formal/polite register."
  else
    style_instruction="Use casual/informal register."
  fi

  local translated=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg text "$raw_text" --arg style "$style_instruction" --arg lang "$lang" '{
      model: "llama-3.3-70b-versatile",
      messages: [
        {
          role: "system",
          content: ("You are a translator. Translate the following text to " + $lang + ". " + $style + " Output ONLY the translated text, nothing else. Do not add quotes around the output.")
        },
        {
          role: "user",
          content: $text
        }
      ],
      temperature: 0.3
    }')" \
    | jq -r '.choices[0].message.content')

  logging_end_and_write_to_logfile "Translation" "$translated" "$logging_start"
  echo "$translated"
}

# Wait for all keys to be released (push-to-talk detection)
# Auto-detects X11 vs Wayland and uses the appropriate method
wait_for_key_release() {
  python3 << 'PYEOF'
import os, time

session = os.environ.get('XDG_SESSION_TYPE', 'x11')

if session != 'wayland':
    # X11: use XQueryKeymap
    from ctypes import cdll, c_char
    X11 = cdll.LoadLibrary("libX11.so.6")
    display = X11.XOpenDisplay(None)
    if not display:
        exit(0)
    keys_start = (c_char * 32)()
    keys_check = (c_char * 32)()
    time.sleep(0.05)
    X11.XQueryKeymap(display, keys_start)
    pressed = set()
    for i in range(32):
        b = keys_start[i] if isinstance(keys_start[i], int) else ord(keys_start[i])
        for bit in range(8):
            if b & (1 << bit):
                pressed.add(i * 8 + bit)
    if not pressed:
        X11.XCloseDisplay(display)
        exit(0)
    while True:
        time.sleep(0.05)
        X11.XQueryKeymap(display, keys_check)
        still = False
        for kc in pressed:
            b = keys_check[kc // 8]
            b = b if isinstance(b, int) else ord(b)
            if b & (1 << (kc % 8)):
                still = True
                break
        if not still:
            break
    X11.XCloseDisplay(display)
else:
    # Wayland: use evdev (kernel input subsystem)
    import fcntl, glob

    def EVIOCGKEY(length):
        return (2 << 30) | (ord('E') << 8) | 0x18 | (length << 16)

    KEY_MAX = 0x2ff
    BUF = (KEY_MAX + 7) // 8 + 1

    def find_keyboards():
        kbds = []
        for dev in sorted(glob.glob('/dev/input/event*')):
            try:
                n = dev.rsplit('event', 1)[1]
                with open('/sys/class/input/event%s/device/capabilities/ev' % n) as f:
                    if not (int(f.read().strip(), 16) & 2):
                        continue
                with open('/sys/class/input/event%s/device/capabilities/key' % n) as f:
                    if len(f.read().strip()) > 20:
                        kbds.append(dev)
            except (IOError, ValueError):
                pass
        return kbds

    def get_pressed(fd, buf):
        try:
            fcntl.ioctl(fd, EVIOCGKEY(BUF), buf)
        except OSError:
            return set()
        return {i for i in range(KEY_MAX + 1) if buf[i // 8] & (1 << (i % 8))}

    fds = []
    for kb in find_keyboards():
        try:
            fds.append(os.open(kb, os.O_RDONLY))
        except OSError:
            pass
    if not fds:
        exit(0)

    time.sleep(0.05)
    buf = bytearray(BUF)
    initial = set()
    for fd in fds:
        initial |= get_pressed(fd, buf)
    if not initial:
        for fd in fds: os.close(fd)
        exit(0)

    while True:
        time.sleep(0.05)
        still = False
        for fd in fds:
            if initial & get_pressed(fd, buf):
                still = True
                break
        if not still:
            break

    for fd in fds:
        os.close(fd)
PYEOF
}

# Cleanup
CLEANED_UP=0
cleanup() {
  [ "$CLEANED_UP" -eq 1 ] && return
  CLEANED_UP=1
  pkill -f "$PROCESS_PATTERN" 2>/dev/null
  hide_status
  rm -f "$RECORDING" "$PIDFILE"
  if [ -n "$SAVED_CLIPBOARD" ]; then
    echo -n "$SAVED_CLIPBOARD" | $CLIP_COPY
  fi
}
trap cleanup EXIT INT TERM

# Main — Push-to-talk flow

# Small delay to let GNOME finish processing the shortcut key
sleep 0.3

# Start recording in background
rm -f "$RECORDING"
pw-record --channels=1 --rate=16000 "$RECORDING" &
PW_PID=$!

# Show recording overlay
show_status recording

# Wait for key release
wait_for_key_release

# Stop recording
kill $PW_PID 2>/dev/null
wait $PW_PID 2>/dev/null
sleep 0.2

# Save clipboard for paste phase
SAVED_CLIPBOARD=$($CLIP_PASTE 2>/dev/null)

# Check if recording is silent
if is_silent "$RECORDING"; then
  show_status silent --timeout 2000
  rm -f "$RECORDING"
  exit 0
fi

show_status transcribing
TRANSCRIPTION=$(transcribe "$RECORDING")
# Check if transcription starts with "translate this"
if echo "$TRANSCRIPTION" | grep -iq "^translate this"; then
  TARGET_LANG="$target_language"
  FORMALITY="casual"
  # Strip "translate this" prefix
  TEXT_TO_TRANSLATE=$(echo "$TRANSCRIPTION" | sed -E 's/^[Tt]ranslate this[,.]? *//i')
  # Check for "to <language>" and extract it
  if echo "$TEXT_TO_TRANSLATE" | grep -iqE "^to [a-z]+"; then
    TARGET_LANG=$(echo "$TEXT_TO_TRANSLATE" | sed -E 's/^[Tt]o ([A-Za-z]+).*/\1/')
    TEXT_TO_TRANSLATE=$(echo "$TEXT_TO_TRANSLATE" | sed -E 's/^[Tt]o [A-Za-z]+[,.]? *//i')
  fi
  # Check for "official" (formal register)
  if echo "$TEXT_TO_TRANSLATE" | grep -iq "^official"; then
    FORMALITY="formal"
    TEXT_TO_TRANSLATE=$(echo "$TEXT_TO_TRANSLATE" | sed -E 's/^[Oo]fficial[,.]? *//i')
  fi
  show_status translating
  TRANSCRIPTION=$(translate_text "$TEXT_TO_TRANSLATE" "$FORMALITY" "$TARGET_LANG")
fi

paste "$TRANSCRIPTION"

# Show done overlay briefly
show_status done --timeout 1500

# Restore original clipboard
sleep 0.1
if [ -n "$SAVED_CLIPBOARD" ]; then
  echo -n "$SAVED_CLIPBOARD" | $CLIP_COPY
fi

rm -f "$RECORDING"
