<div align="center">
  <h1>xhisper Ubuntu Linux</h1>
  <img src="demo.gif" alt="xhisper demo" width="300">
  <br><br>
</div>

Voice-to-text dictation at cursor for Ubuntu. Based on [imaginalnika/xhisper](https://github.com/imaginalnika/xhisper) with push-to-talk, animated status overlay, keyboard layout compatibility, translation support, and clipboard manager integration.

## Features

- **Push-to-talk** — Hold your shortcut key to record, release to transcribe. No double-press needed
- **Animated status overlay** — A dark pill with animated sound wave bars slides up from the bottom of the screen during recording, transcribing, and translating (falls back to desktop notifications if GTK is unavailable)
- **Non-QWERTY layout support** — Uses clipboard-based paste instead of simulated keypresses, so it works natively with AZERTY, QWERTZ, or any keyboard layout
- **English language forced** — Whisper transcription is locked to English to prevent language misdetection
- **Translate to French** — Say "translate this ..." and the rest of your speech will be translated to French via Groq LLM. Casual (tu) by default, say "translate this official ..." for formal (vous)
- **Stability** — PID-file based concurrency control prevents duplicate instances from interfering with each other
- **Clipboard preservation** — Your clipboard content is saved before transcription and restored after pasting
- **Clipboard manager cleanup** — Automatically removes xhisper's temporary clipboard entries from CopyQ history

---

## Installation on Ubuntu

### 1. Install dependencies

```sh
sudo apt update
sudo apt install pipewire jq curl ffmpeg gcc xclip python3 python3-gi gir1.2-gtk-3.0 bc
```

### 2. Add user to input group

```sh
sudo usermod -aG input $USER
```

Then **log out and log back in** (restart is safer) for the group change to take effect.

Verify by running:

```sh
groups
```

You should see `input` in the output.

### 3. Set up uinput permissions

```sh
echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' | sudo tee /etc/udev/rules.d/99-uinput.rules
sudo udevadm control --reload-rules
sudo udevadm trigger /dev/uinput
```

### 4. Get a Groq API key

Get a free API key from [console.groq.com](https://console.groq.com) and add it to `~/.env`:

```sh
echo 'GROQ_API_KEY=<your_API_key>' >> ~/.env
```

### 5. Clone, build, and install

```sh
git clone --depth 1 https://github.com/abszar/xhisper-ubuntu-linux.git
cd xhisper-ubuntu-linux && make
sudo make install
```

### 6. Set up a keyboard shortcut (GNOME)

Run the following in a terminal to bind xhisper to a key. Change `binding` to your preferred shortcut:

```sh
name="xhisper"
binding="Pause"  # Pause/Break key. Other examples: "<Alt>d", "<CTRL><SHIFT>X"
action="/usr/local/bin/xhisper"

media_keys=org.gnome.settings-daemon.plugins.media-keys
custom_kbd=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding
kbd_path=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/$name/
new_bindings=$(gsettings get $media_keys custom-keybindings | sed -e"s>'\]>','$kbd_path']>" | sed -e"s>@as \[\]>['$kbd_path']>")
gsettings set $media_keys custom-keybindings "$new_bindings"
gsettings set $custom_kbd:$kbd_path name "$name"
gsettings set $custom_kbd:$kbd_path binding "$binding"
gsettings set $custom_kbd:$kbd_path command "$action"
```

---

## Usage

**Hold** your shortcut key to record, **release** to stop and transcribe. The transcribed text is pasted at your cursor.

An animated wave pill overlay slides up from the bottom of your screen showing the current state:
- **Recording** — animated wave bars while you hold the key
- **Transcribing** — gentler pulse while Whisper processes your audio
- **Done** — brief confirmation, then fades out

### Translate to French

Start your dictation with **"translate this"** followed by what you want translated. By default it uses **casual French (tu)**:

> "Translate this how are you doing"

Result: `Comment tu vas ?`

For **formal French (vous)**, say **"translate this official"**:

> "Translate this official how are you doing"

Result: `Comment allez-vous ?`

### View logs

```sh
xhisper --log
```

---

## Configuration

Configuration is read from `~/.config/xhisper/xhisperrc`:

```sh
mkdir -p ~/.config/xhisper
cp default_xhisperrc ~/.config/xhisper/xhisperrc
```

---

## Troubleshooting

**No sound detected**: Check that your microphone is working and PipeWire is running (`pw-record --channels=1 test.wav`).

**Permission denied on /dev/uinput**: Make sure you completed step 3 (udev rules) and that you're in the `input` group.

**Wrong text pasted**: If xhisper pastes old clipboard content instead of the transcription, make sure `xclip` is installed (`sudo apt install xclip`).

**Overlay not showing**: Make sure PyGObject is installed (`sudo apt install python3-gi gir1.2-gtk-3.0`). The script falls back to `notify-send` if GTK is unavailable.

---

<p align="center">
  <em>Push-to-talk voice dictation for Ubuntu with AZERTY support and French translation</em>
</p>
