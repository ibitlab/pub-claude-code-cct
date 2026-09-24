"""Drive the cct TUI inside a pty, capture screens, render them to PNG.

Geometry, palette and blur match the screenshots already in docs/images:
16px Menlo on #16181E, a 10x21 cell grid, 16px padding, and redacted regions
blurred with three passes of GaussianBlur(6).
"""
import fcntl, os, pty, re, select, signal, struct, termios, time, random

import pyte
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# ---------- terminal ----------

KEYS = {                      # curses runs in application-cursor mode: ESC O x
    "down": "\x1bOB", "up": "\x1bOA", "right": "\x1bOC", "left": "\x1bOD",
    "home": "\x1bOH", "end": "\x1bOF", "pgdn": "\x1b[6~", "pgup": "\x1b[5~",
    "enter": "\r", "esc": "\x1b",
}


class Term:
    """A cct process on a pty, with a pyte screen behind it."""

    def __init__(self, argv, cwd, cols=118, rows=34):
        self.cols, self.rows = cols, rows
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        env = dict(os.environ, TERM="xterm-256color",
                   LINES=str(rows), COLUMNS=str(cols), ESCDELAY="25")
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execvpe(argv[0], argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.alive = True

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if not r:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                self.alive = False
                return False
            if not data:
                self.alive = False
                return False
            self.stream.feed(data)
        return True

    def send(self, key, settle=0.6):
        """key: a name from KEYS, literal text, or a number = just wait."""
        if isinstance(key, (int, float)):
            return self.pump(key)
        if not self.alive:
            raise RuntimeError("cct exited before key %r" % key)
        os.write(self.fd, KEYS.get(key, key).encode())
        return self.pump(settle)

    def lines(self):
        return ["".join(self.screen.buffer[y][x].data or " " for x in range(self.cols))
                for y in range(self.rows)]

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except OSError:
            pass


# ---------- rendering ----------

FONT = "/System/Library/Fonts/Menlo.ttc"
FS = 16
PAD = 16
BG = (22, 24, 30)
PALETTE = {
    "black": (60, 63, 74), "red": (255, 105, 97), "green": (126, 217, 87),
    "brown": (240, 196, 25), "yellow": (240, 220, 90), "blue": (110, 168, 254),
    "magenta": (214, 137, 255), "cyan": (110, 226, 236), "white": (228, 231, 238),
    "default": (228, 231, 238),
}
FILLER = "mwnhukdbaeosrtmwnhukdbgpq"   # stand-in text under the blur


def color(name, is_bg=False):
    if name == "default":
        return BG if is_bg else PALETTE["default"]
    if name in PALETTE:
        return PALETTE[name]
    if re.fullmatch(r"[0-9a-fA-F]{6}", str(name)):
        return tuple(int(name[i:i + 2], 16) for i in (0, 2, 4))
    return BG if is_bg else PALETTE["default"]


def render(term, path, boxes=(), rows=None, seed=7):
    """Render the current screen. `boxes` are (y, x0, x1) cell ranges that are
    replaced with filler letters and then blurred, so the published PNG has no
    real text in it at all — not even under the blur."""
    rnd = random.Random(seed)
    nrows = rows or term.rows
    buf = [term.screen.buffer[y] for y in range(nrows)]
    hide = {}
    for (y, x0, x1) in boxes:
        hide.setdefault(y, set()).update(range(x0, x1))

    font = ImageFont.truetype(FONT, FS)
    bold = ImageFont.truetype(FONT, FS, index=1)
    cw = ImageDraw.Draw(Image.new("RGB", (8, 8))).textlength("M", font=font)
    ch = FS + 5
    W, H = int(cw * term.cols) + PAD * 2, ch * nrows + PAD * 2
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    for y, line in enumerate(buf):
        for x in range(term.cols):
            cell = line[x]
            data = cell.data
            if x in hide.get(y, ()) and data not in ("", " "):
                data = rnd.choice(FILLER)          # keep spaces: same ink pattern
            blank = data in ("", " ")
            if blank and cell.bg == "default" and not cell.reverse:
                continue
            fg, bg = color(cell.fg), color(cell.bg, True)
            if cell.reverse:
                fg, bg = (BG if cell.bg == "default" else color(cell.bg, True)), fg
            px, py = PAD + x * cw, PAD + y * ch
            if bg != BG:
                d.rectangle([px, py, px + cw + 1, py + ch], fill=bg)
            if data == "█":            # bar charts: fill the cell, no seams
                d.rectangle([px, py, px + cw + 1, py + ch], fill=fg)
            elif not blank:
                d.text((px, py + 2), data, font=bold if cell.bold else font, fill=fg)

    for (y, x0, x1) in boxes:
        if y >= nrows or x1 <= x0:
            continue
        box = (int(PAD + x0 * cw) - 1, PAD + y * ch, int(PAD + x1 * cw) + 2, PAD + (y + 1) * ch)
        region = img.crop(box)
        for _ in range(3):
            region = region.filter(ImageFilter.GaussianBlur(radius=6.0))
        img.paste(region, box)

    img.save(path)
    return W, H
