#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later OR LGPL-2.1-or-later
"""
Screens for setup.sh's interactive setup, styled like whiptail but without buttons: each screen lists
its keys along the bottom (whiptail and dialog always draw OK/Cancel buttons and can't bind other keys).

Usage:
  tui.py menu TITLE TEXT [options] [--] TAG ITEM [TAG ITEM ...]
      --deletable N   the first N items can be deleted with Del
      --del LABEL     what Del does, for the key line (default "delete")
      --default TAG   item selected initially
      --esc LABEL     what Esc does, for the key line (default "back")
      --min-width N   window width (default 66; wider for long items, narrower on small terminals)
    Result: "select TAG" (Enter) or "delete TAG" (Del); Esc exits with status 1.
  tui.py input TITLE TEXT VALUE [--browse] [--note NOTE]
    One-line text field (e.g. a path). NOTE is shown in red under TEXT, after a blank line. Result: "ok VALUE" (Enter) or, with --browse, "browse VALUE"
    (Ctrl+O). Esc exits with status 1.
  tui.py form TITLE [options] -- {text LABEL VALUE | check LABEL 0|1} ...
    Text fields and checkboxes under each other; Up/Down move between them, Space toggles a
    checkbox. Result: "ok" (Enter) or "browse" (Ctrl+O), then each value (checkbox: 1/0), one per
    line. Esc gives "cancel" and the values, with exit status 1.
      --text TEXT        shown above the fields
      --note NOTE        shown in red at the bottom, above the keys
      --after TEXT       shown under the fields
      --browse           Ctrl+O (for the first field)
      --code-from-path   the second field follows the activation code in the first field's file name
                         (..._XXXX-XXXX.alf) until it's edited
      --prefix-from-installer
                         the second field follows the Wine prefix named after the Altium version in
                         the first field's file name (..._Altium_Designer_..._21_... ->
                         ~/.wine-altium21) while it's empty or matches, until it's edited, and red notes show whether that folder is
                         already a Wine prefix and has Altium Designer (version --ad-version) in it
      --ad-version V     Altium version prefix for that note (default: any version)
      --tested LIST      with --prefix-from-installer: Altium versions (space-separated, e.g. "21.5.1")
                         tested with setup; for any other version in the installer's file name, or none,
                         a red warning
      --no-box           no box around the fields
  tui.py pick TITLE LABEL VALUE LIST_LABEL [--browse] -- TAG ITEM [TAG ITEM ...]
    A text field with a list under it; Down/Up move between them. Moving in the list puts the item's
    TAG in the field. Items can have a second column after a tab character; it's aligned.
    Result: "ok VALUE" (Enter) or "browse VALUE" (Ctrl+O). Esc exits with status 1.
  tui.py checklist TITLE TEXT ENTER_LABEL -- TAG 0|1 LABEL [TAG 0|1 LABEL ...]
    A scrolling list of checkboxes; Space toggles one, Enter accepts (ENTER_LABEL is what the key line
    calls it). Result: "ok", then the TAG of each checked item, one per line. Esc exits with status 1.
  tui.py message TITLE TEXT
    Enter or Esc closes it.
  tui.py confirm TITLE TEXT [--head HEAD] [--warn WARNING] [--red LINE ...]
    y: exit status 0; n or Esc: status 1. HEAD is shown in red above TEXT, WARNING in red under it, and
    each line of TEXT equal to a --red LINE in red.

Results are written to file descriptor 3, as in: res="$(tui.py ... 3>&1 1>&2)"
"""
import curses
import locale
import os
import re
import sys

ENTER = (curses.KEY_ENTER, 10, 13)
ESC = 27
CTRL_O, CTRL_U = 15, 21
BACKSPACE = (curses.KEY_BACKSPACE, 127, 8)


def wrap(text, width):
    lines = []
    for para in text.split('\n'):
        if len(para) <= width:            # keep lines that fit as they are (e.g. aligned columns)
            lines.append(para)
            continue
        line = ''
        for word in para.split(' '):
            while len(word) > width:      # e.g. a long path: break it rather than cut it off
                if line:
                    lines.append(line)
                    line = ''
                lines.append(word[:width])
                word = word[width:]
            if line and len(line) + 1 + len(word) > width:
                lines.append(line)
                line = word
            else:
                line = f'{line} {word}' if line else word
        lines.append(line)
    return lines


def text_width(text):
    """Window width for a message: its longest line, at least 50 and at most 110 (or the screen)."""
    return max(50, min(110, max(len(line) for line in text.split("\n")) + 6))


def init_colors():
    curses.use_default_colors()
    # whiptail (newt) default colors
    curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)    # root
    curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_WHITE)   # window, border, items
    curses.init_pair(3, curses.COLOR_RED, curses.COLOR_WHITE)     # title
    curses.init_pair(4, curses.COLOR_WHITE, curses.COLOR_RED)     # selected item
    curses.init_pair(5, curses.COLOR_BLACK, curses.COLOR_BLACK)   # shadow
    curses.init_pair(6, curses.COLOR_WHITE, curses.COLOR_BLUE)    # text field


def frame(scr, title, text, body_h, keys, min_width, note=None, after=None, after_note=None, boxed=True, head=None,
          red=()):
    """Draws the background and a centered window with title, text (and a red note under it), room for
    a body of body_h rows (in its own box when body_h > 0), text and a red note after the body, and the
    key line. Returns (window, body box or None, width)."""
    rows, cols = scr.getmaxyx()
    width = min(cols - 4, max(len(keys) + 6, len(title) + 8, min_width))
    # lines of the text that are in red (all wrapped parts of them)
    text_lines = [(line, 3 if para in red else 2) for para in text.split('\n') for line in wrap(para, width - 4)] \
        if text else []
    if head:      # red lines above the text
        text_lines = [(line, 3) for line in wrap(head, width - 4)] + text_lines
    if note:
        text_lines += ([('', 2)] if text_lines else []) + [(line, 3) for line in wrap(note, width - 4)]
    after_lines = [(line, 2) for line in wrap(after, width - 4)] if after else []
    if after_note:
        after_lines += ([('', 2)] if after_lines else []) + [(line, 3) for line in wrap(after_note, width - 4)]
    body_h = max(0, min(body_h, rows - len(text_lines) - len(after_lines) - 10))
    height = len(text_lines) + (body_h + 3 if body_h else 0) + (len(after_lines) + 1 if after_lines else 0) + 4
    y0, x0 = max(0, (rows - height) // 2), max(0, (cols - width) // 2)

    scr.bkgd(' ', curses.color_pair(1))
    scr.erase()
    # shadow, as whiptail draws it; the window is refreshed after it so it stays on top
    if y0 + height < rows and x0 + width + 1 < cols:
        for y in range(y0 + 1, y0 + height + 1):
            scr.chgat(y, x0 + width, 2, curses.color_pair(5))
        scr.chgat(y0 + height, x0 + 2, width, curses.color_pair(5))
    win = curses.newwin(height, width, y0, x0)
    win.bkgd(' ', curses.color_pair(2))
    win.erase()
    win.box()
    win.addstr(0, max(1, (width - len(title) - 2) // 2), f' {title} '[:width - 2], curses.color_pair(3))
    for i, (line, color) in enumerate(text_lines):
        win.addstr(1 + i, 2, line[:width - 4], curses.color_pair(color))
    box = None
    if body_h:
        box = win.derwin(body_h + 2, width - 4, len(text_lines) + 2, 2)
        if boxed:
            box.box()
    for i, (line, color) in enumerate(after_lines):
        win.addstr(height - 3 - len(after_lines) + i, 2, line[:width - 4], curses.color_pair(color))
    win.addstr(height - 2, max(2, (width - len(keys)) // 2), keys[:width - 4])
    return win, box, width


def scrollbar(win, y0, x, h, top, total, color):
    """A scrollbar in column x, rows y0 .. y0+h-1, when total rows don't fit in h: the thumb shows which
    part of the list is visible."""
    if total <= h:
        return
    size = max(1, h * h // total)
    pos = round(top * (h - size) / (total - h))
    for i in range(h):
        try:      # (a window's last cell raises an error once written, but is written)
            win.addstr(y0 + i, x, '█' if pos <= i < pos + size else '░', curses.color_pair(color))
        except curses.error:
            pass


def show(scr, win):
    scr.noutrefresh()
    win.noutrefresh()
    curses.doupdate()


def read_key(scr):
    """A key, with escape sequences the terminfo entry doesn't describe (e.g. ESC [ B when the terminal
    ignores application cursor mode) translated. A lone Esc is ESC."""
    key = scr.get_wch()
    if key != chr(ESC) and key != ESC:
        return key
    scr.nodelay(True)
    seq = ''
    while len(seq) < 6:
        try:
            seq += scr.get_wch()
        except curses.error:
            break
    scr.nodelay(False)
    return {'': ESC, '[A': curses.KEY_UP, 'OA': curses.KEY_UP, '[B': curses.KEY_DOWN, 'OB': curses.KEY_DOWN,
            '[C': curses.KEY_RIGHT, 'OC': curses.KEY_RIGHT, '[D': curses.KEY_LEFT, 'OD': curses.KEY_LEFT,
            '[H': curses.KEY_HOME, 'OH': curses.KEY_HOME, '[1~': curses.KEY_HOME,
            '[F': curses.KEY_END, 'OF': curses.KEY_END, '[4~': curses.KEY_END,
            '[3~': curses.KEY_DC, '[5~': curses.KEY_PPAGE, '[6~': curses.KEY_NPAGE}.get(seq, None)


def is_key(key, *codes):
    return key in codes or (isinstance(key, str) and len(key) == 1 and ord(key) in codes)


def menu(scr, title, text, items, deletable=0, del_label='delete', default=None, esc='back', min_width=66):
    curses.curs_set(0)
    sel = next((i for i, (tag, _) in enumerate(items) if tag == default), 0)
    top = 0
    keys = f'<Enter> select    <Esc> {esc}' + (f'    <Del> {del_label}' if deletable else '')
    while True:
        win, box, width = frame(scr, title, text, len(items), keys, max(max(len(i) for _, i in items) + 12, min_width))
        list_h = box.getmaxyx()[0] - 2
        sel = max(0, min(sel, len(items) - 1))
        if sel < top:
            top = sel
        elif sel >= top + list_h:
            top = sel - list_h + 1
        for row, (tag, item) in enumerate(items[top:top + list_h]):
            avail = width - 8
            if len(item) > avail:     # keep the start (e.g. a drive letter) and the end of a long path
                keep = min(12, avail // 3)
                item = item[:keep] + '…' + item[len(item) - (avail - keep - 1):]
            box.addstr(1 + row, 1, f' {item} '.ljust(width - 6), curses.color_pair(4 if top + row == sel else 2))
        scrollbar(box, 1, width - 6, list_h, top, len(items), 2)
        show(scr, win)

        key = read_key(scr)
        if is_key(key, curses.KEY_UP):
            sel -= 1
        elif is_key(key, curses.KEY_DOWN):
            sel += 1
        elif is_key(key, curses.KEY_HOME):
            sel = 0
        elif is_key(key, curses.KEY_END):
            sel = len(items) - 1
        elif is_key(key, curses.KEY_PPAGE):
            sel -= list_h
        elif is_key(key, curses.KEY_NPAGE):
            sel += list_h
        elif is_key(key, *ENTER):
            return f'select {items[sel][0]}'
        elif is_key(key, curses.KEY_DC) and sel < deletable:
            return f'delete {items[sel][0]}'
        elif is_key(key, ESC):
            return None


def text_input(scr, title, text, value, browse=False, note=None):
    buf, pos, off = list(value), len(value), 0
    keys = '<Enter> OK    <Esc> cancel' + ('    <Ctrl+O> browse' if browse else '')
    while True:
        curses.curs_set(0)
        win, box, width = frame(scr, title, text, 1, keys, 80, note)
        field_w = width - 8
        if pos < off:
            off = pos
        elif pos > off + field_w - 1:
            off = pos - field_w + 1
        box.addstr(1, 1, ' ' + ''.join(buf[off:off + field_w]).ljust(field_w) + ' ', curses.color_pair(6))
        by, bx = box.getparyx()
        win.move(by + 1, bx + 2 + pos - off)    # the cursor goes where the last refreshed window has it
        curses.curs_set(1)
        show(scr, win)

        key = read_key(scr)
        if is_key(key, *ENTER):
            return 'ok ' + ''.join(buf)
        if is_key(key, ESC):
            return None
        if browse and is_key(key, CTRL_O):
            return 'browse ' + ''.join(buf)
        if is_key(key, curses.KEY_LEFT):
            pos = max(0, pos - 1)
        elif is_key(key, curses.KEY_RIGHT):
            pos = min(len(buf), pos + 1)
        elif is_key(key, curses.KEY_HOME):
            pos = 0
        elif is_key(key, curses.KEY_END):
            pos = len(buf)
        elif is_key(key, *BACKSPACE):
            if pos:
                del buf[pos - 1]
                pos -= 1
        elif is_key(key, curses.KEY_DC):
            if pos < len(buf):
                del buf[pos]
        elif is_key(key, CTRL_U):
            buf, pos = [], 0
        elif isinstance(key, str) and key.isprintable():
            buf.insert(pos, key)
            pos += 1


def code_from_name(path):
    codes = re.findall(r'[A-Z0-9]{4}-[A-Z0-9]{4}', os.path.basename(path))
    return codes[-1] if codes else ''


def prefix_from_installer(path):
    """~/.wine-altium21 for e.g. OfflineSetup_Altium_Designer_Public_21_5_1.zip or AltiumDesigner21Setup.exe."""
    m = re.search(r'designer\D{0,12}?(\d{2})(?!\d)', os.path.basename(path), re.I)
    return os.path.expanduser('~/.wine-altium' + (m.group(1) if m else ''))


def installer_version(path):
    """The Altium version in an installer's file name: 21.5.1 for ..._Altium_Designer_Public_21_5_1.zip,
    21 for AltiumDesigner21Setup.exe. Empty if there's none."""
    m = re.search(r'designer\D{0,12}?(\d+(?:[_.]\d+){0,2})(?![\d_.]*\d)', os.path.basename(path), re.I)
    return m.group(1).replace('_', '.') if m else ''


def prefix_notes(path, version, cache={}):
    """Red notes for a Wine prefix folder: whether it's an existing prefix and has Altium installed."""
    path = os.path.realpath(os.path.expanduser(path.strip())) if path.strip() else ''
    if path not in cache:
        notes = []
        reg = os.path.join(path, 'system.reg')
        if path and os.path.isfile(reg):
            notes.append('NOTE: Wine prefix already exists')
            # like setup.sh's find_build: a Builds\Altium Designer {GUID} key with a Version
            in_build = False
            with open(reg, errors='replace') as f:
                for line in f:
                    if line.startswith('['):
                        in_build = line.startswith('[Software\\\\Altium\\\\Builds\\\\Altium Designer {')
                    elif in_build and line.startswith('"Version"="' + version):
                        notes.append('NOTE: Altium already installed in this wine prefix')
                        break
        cache[path] = '\n'.join(notes) or None
    return cache[path]


def form(scr, title, entries, browse=False, derive=None, text='', note=None, after=None, version='', boxed=True,
         tested=None):
    """derive: 'code' or 'prefix' (see --code-from-path, --prefix-from-installer)."""
    kinds = [kind for kind, _, _ in entries]
    labels = [label for _, label, _ in entries]
    bufs = [list(value) if kind == 'text' else value == '1' for kind, _, value in entries]
    # The second field follows the first until edited. A code only if it started out empty or matching.
    initial = entries[1][2] if derive else ''
    derived = prefix_from_installer if derive == 'prefix' else code_from_name
    follow = derive is not None and initial in ('', derived(entries[0][2]) if entries[0][2].strip() else '')
    cur, pos, off = 0, len(bufs[0]) if kinds[0] == 'text' else 0, [0] * len(entries)
    keys = ('<Enter> OK    <Esc> cancel' + ('    <Space> toggle' if 'check' in kinds else '')
            + ('    <Ctrl+O> browse' if browse else ''))
    # rows per entry: [label,] field and a gap, or one checkbox line; lab[i] is 1 if there's a label
    lab = [1 if kind == 'text' and label else 0 for kind, label in zip(kinds, labels)]
    rows = [2 + lab[i] if kind == 'text' else 1 for i, kind in enumerate(kinds)]
    tops = [sum(rows[:i]) + 1 for i in range(len(rows))]

    def values():
        return [''.join(b) if kind == 'text' else ('1' if b else '0') for kind, b in zip(kinds, bufs)]

    while True:
        if follow:
            src = ''.join(bufs[0])
            if derive == 'code':
                bufs[1] = list(code_from_name(src))
            else:
                bufs[1] = list(prefix_from_installer(src) if src.strip() else initial)
            if cur == 1:
                pos = min(pos, len(bufs[1]))
        shown_note = note
        if derive == 'prefix':
            notes = []
            src = ''.join(bufs[0]).strip()
            v = installer_version(src)
            if tested is not None and v and v not in tested:
                notes.append(f'WARNING: Altium {v} not tested with this installer')
            elif tested is not None and src and not v:
                notes.append('WARNING: Altium version unknown (compatibility is uncertain)')
            if prefix_notes(''.join(bufs[1]), version):
                notes.append(prefix_notes(''.join(bufs[1]), version))
            shown_note = '\n'.join(notes) or None
        curses.curs_set(0)
        body_h = max(1, sum(rows) - (1 if kinds[-1] == 'text' else 0) - (0 if boxed else 2))    # no border rows
        win, box, width = frame(scr, title, text, body_h, keys, 80, after=after, after_note=shown_note, boxed=boxed)
        # without the box, the fields move to its edge (up a row, left to the window's margin)
        dy, dx = (0, 0) if boxed else (-1, -1)
        field_w = width - 8 - 2 * dx
        for i, (kind, label) in enumerate(zip(kinds, labels)):
            if kind == 'check':
                mark = '[x]' if bufs[i] else '[ ]'
                box.addstr(tops[i] + dy, 2 + 2 * dx, f'{mark} {label}'[:width - 8], curses.color_pair(4 if i == cur else 2))
                continue
            p = pos if i == cur else len(bufs[i])
            if p < off[i]:
                off[i] = p
            elif p > off[i] + field_w - 1:
                off[i] = p - field_w + 1
            if label:
                box.addstr(tops[i] + dy, 2 + 2 * dx, label)
            try:      # (the window's last cell raises an error once written, but is written)
                box.addstr(tops[i] + lab[i] + dy, 1 + dx, ' ' + ''.join(bufs[i][off[i]:off[i] + field_w]).ljust(field_w)
                           + ' ', curses.color_pair(6))
            except curses.error:
                pass
        if kinds[cur] == 'text':
            by, bx = box.getparyx()
            win.move(by + tops[cur] + lab[cur] + dy, bx + 2 + dx + pos - off[cur])
            curses.curs_set(1)
        show(scr, win)

        key = read_key(scr)
        if is_key(key, *ENTER):
            return '\n'.join(['ok'] + values())
        if is_key(key, ESC):
            return '\n'.join(['cancel'] + values())
        if browse and is_key(key, CTRL_O):
            return '\n'.join(['browse'] + values())
        if is_key(key, curses.KEY_DOWN):
            cur = (cur + 1) % len(bufs)
            pos = len(bufs[cur]) if kinds[cur] == 'text' else 0
            continue
        if is_key(key, curses.KEY_UP):
            cur = (cur - 1) % len(bufs)
            pos = len(bufs[cur]) if kinds[cur] == 'text' else 0
            continue
        if kinds[cur] == 'check':
            if key == ' ':
                bufs[cur] = not bufs[cur]
            continue
        buf = bufs[cur]
        if cur == 1 and (isinstance(key, str) and key.isprintable() or is_key(key, *BACKSPACE, curses.KEY_DC, CTRL_U)):
            follow = False
        if is_key(key, curses.KEY_LEFT):
            pos = max(0, pos - 1)
        elif is_key(key, curses.KEY_RIGHT):
            pos = min(len(buf), pos + 1)
        elif is_key(key, curses.KEY_HOME):
            pos = 0
        elif is_key(key, curses.KEY_END):
            pos = len(buf)
        elif is_key(key, *BACKSPACE):
            if pos:
                del buf[pos - 1]
                pos -= 1
        elif is_key(key, curses.KEY_DC):
            if pos < len(buf):
                del buf[pos]
        elif is_key(key, CTRL_U):
            buf.clear()
            pos = 0
        elif isinstance(key, str) and key.isprintable():
            buf.insert(pos, key)
            pos += 1


def pick(scr, title, label, value, list_label, items, browse=False):
    buf, pos, off = list(value), len(value), 0
    sel = next((i for i, (tag, _) in enumerate(items) if tag == value), -1)
    top, focus = 0, 0      # focus 0: text field, 1: list
    keys = '<Enter> OK    <Esc> cancel' + ('    <Ctrl+O> browse' if browse else '')
    while True:
        curses.curs_set(0)
        rows, _ = scr.getmaxyx()
        n = len(items) or 1
        # list rows: one per item, plus a quarter of the window's height as room below them
        list_h = max(1, min(n + round((n + 13) * 0.25), rows - 16))
        min_width = max([66] + [len(i.replace('\t', '   ')) + 12 for _, i in items])
        win, box, width = frame(scr, title, '', 6 + list_h, keys, min_width, boxed=False)
        list_h = box.getmaxyx()[0] - 8 + 2     # what fit on the screen
        field_w = width - 6
        if pos < off:
            off = pos
        elif pos > off + field_w - 1:
            off = pos - field_w + 1
        box.addstr(0, 0, label)
        box.addstr(1, 0, ' ' + ''.join(buf[off:off + field_w]).ljust(field_w) + ' ', curses.color_pair(6))
        box.addstr(3, 0, list_label)
        # the list: border in the window's colors, inside in the text field's
        lst = box.derwin(list_h + 2, width - 4, 4, 0)
        lst.box()
        inner = lst.derwin(list_h, width - 6, 1, 1)

        def put(row, text, color):
            try:      # the window's last cell raises an error once written, but is written
                inner.addstr(row, 0, text.ljust(width - 6)[:width - 6], curses.color_pair(color))
            except curses.error:
                pass

        for row in range(list_h):
            put(row, '', 6)
        avail = width - 9
        # second column (after a tab) aligned; the first is shortened in the middle if it doesn't fit
        col2 = [i.split('\t', 1)[1] if '\t' in i else '' for _, i in items]
        col1 = [i.split('\t', 1)[0] for _, i in items]
        w1 = min(max([len(c) for c in col1] + [0]), max(10, avail - max([len(c) for c in col2] + [0]) - 3))
        if not items:
            put(0, ' (none found)', 6)
        else:
            if sel >= 0:
                top = min(max(top, sel - list_h + 1), sel)
            for row in range(min(list_h, len(items) - top)):
                idx = top + row
                c1, c2 = col1[idx], col2[idx]
                if len(c1) > w1:
                    keep = min(12, w1 // 3)
                    c1 = c1[:keep] + '…' + c1[len(c1) - (w1 - keep - 1):]
                item = (c1.ljust(w1) + '   ' + c2 if c2 else c1)[:avail]
                hl = idx == sel and focus == 1
                put(row, f' {item} ', 4 if hl else 6)
            scrollbar(inner, 0, width - 7, list_h, top, len(items), 6)
        if focus == 0:
            by, bx = box.getparyx()
            win.move(by + 1, bx + 1 + pos - off)
            curses.curs_set(1)
        show(scr, win)

        key = read_key(scr)
        if is_key(key, *ENTER):
            return 'ok ' + ''.join(buf)
        if is_key(key, ESC):
            return None
        if browse and is_key(key, CTRL_O):
            return 'browse ' + ''.join(buf)
        if focus == 1:
            if is_key(key, curses.KEY_UP) and sel <= 0:      # up from the first item: back to the field
                focus = 0
                continue
            moved = {curses.KEY_UP: -1, curses.KEY_DOWN: 1, curses.KEY_PPAGE: -list_h, curses.KEY_NPAGE: list_h,
                     curses.KEY_HOME: -len(items), curses.KEY_END: len(items)}
            for k, d in moved.items():
                if is_key(key, k):
                    sel = max(0, min(len(items) - 1, sel + d))
                    buf = list(items[sel][0]); pos = len(buf)
            continue
        if is_key(key, curses.KEY_DOWN) and items:
            focus = 1
            sel = max(sel, 0)
            buf = list(items[sel][0]); pos = len(buf)
        elif is_key(key, curses.KEY_LEFT):
            pos = max(0, pos - 1)
        elif is_key(key, curses.KEY_RIGHT):
            pos = min(len(buf), pos + 1)
        elif is_key(key, curses.KEY_HOME):
            pos = 0
        elif is_key(key, curses.KEY_END):
            pos = len(buf)
        elif is_key(key, *BACKSPACE):
            if pos:
                del buf[pos - 1]
                pos -= 1
        elif is_key(key, curses.KEY_DC):
            if pos < len(buf):
                del buf[pos]
        elif is_key(key, CTRL_U):
            buf, pos = [], 0
        elif isinstance(key, str) and key.isprintable():
            buf.insert(pos, key)
            pos += 1


def checklist(scr, title, text, enter_label, items):
    curses.curs_set(0)
    checked = [on == '1' for _, on, _ in items]
    sel, top = 0, 0
    keys = f'<Enter> {enter_label}    <Esc> cancel    <Space> toggle'
    while True:
        min_width = max(len(label) for _, _, label in items) + 14
        win, box, width = frame(scr, title, text, len(items), keys, max(min_width, 66))
        list_h = box.getmaxyx()[0] - 2
        if sel < top:
            top = sel
        elif sel >= top + list_h:
            top = sel - list_h + 1
        # inside the box in the text field's colors; the border keeps the window's
        inner = box.derwin(list_h, width - 6, 1, 1)
        for y in range(list_h):
            i = top + y
            text_ = f' [{"x" if checked[i] else " "}] {items[i][2]} ' if i < len(items) else ''
            try:      # (the window's last cell raises an error once written, but is written)
                inner.addstr(y, 0, text_[:width - 7].ljust(width - 6), curses.color_pair(4 if i == sel else 6))
            except curses.error:
                pass
        scrollbar(inner, 0, width - 7, list_h, top, len(items), 6)
        show(scr, win)

        key = read_key(scr)
        last = len(items) - 1
        if is_key(key, curses.KEY_UP):
            sel = max(0, sel - 1)
        elif is_key(key, curses.KEY_DOWN):
            sel = min(last, sel + 1)
        elif is_key(key, curses.KEY_HOME):
            sel = 0
        elif is_key(key, curses.KEY_END):
            sel = last
        elif is_key(key, curses.KEY_PPAGE):
            sel = max(0, sel - list_h)
        elif is_key(key, curses.KEY_NPAGE):
            sel = min(last, sel + list_h)
        elif key == ' ':
            checked[sel] = not checked[sel]
        elif is_key(key, *ENTER):
            return '\n'.join(['ok'] + [tag for (tag, _, _), on in zip(items, checked) if on])
        elif is_key(key, ESC):
            return None


def message(scr, title, text):
    curses.curs_set(0)
    win, _, _ = frame(scr, title, text, 0, '<Enter> OK', text_width(text))
    show(scr, win)
    while not is_key(read_key(scr), *ENTER, ESC):
        pass
    return ''


def confirm(scr, title, text, head=None, warn=None, red=()):
    curses.curs_set(0)
    win, _, _ = frame(scr, title, text, 0, '<y> yes    <n> no', text_width('\n'.join([head or '', text, warn or ''])),
                      head=head, after_note=warn, red=red)
    show(scr, win)
    while True:
        key = read_key(scr)
        if key in ('y', 'Y'):
            return 'yes'
        if key in ('n', 'N') or is_key(key, ESC):
            return None


def run(scr, mode, args):
    init_colors()
    scr.keypad(True)
    if mode == 'menu':
        opts, rest = {}, args[2:]
        while rest and rest[0].startswith('--'):
            opt = rest.pop(0)
            if opt == '--':
                break
            opts[opt] = rest.pop(0)
        items = list(zip(rest[0::2], rest[1::2]))
        return menu(scr, args[0], args[1], items, int(opts.get('--deletable', 0)), opts.get('--del', 'delete'),
                    opts.get('--default'), opts.get('--esc', 'back'), int(opts.get('--min-width', 66)))
    if mode == 'input':
        opts = args[3:]
        note = opts[opts.index('--note') + 1] if '--note' in opts else None
        return text_input(scr, args[0], args[1], args[2], '--browse' in opts, note)
    if mode == 'form':
        opts, rest = args[1:], []
        if '--' in opts:
            opts, rest = opts[:opts.index('--')], opts[opts.index('--') + 1:]
        def opt(name):
            return opts[opts.index(name) + 1] if name in opts else None
        entries = list(zip(rest[0::3], rest[1::3], rest[2::3]))
        derive = 'code' if '--code-from-path' in opts else 'prefix' if '--prefix-from-installer' in opts else None
        return form(scr, args[0], entries, '--browse' in opts, derive, opt('--text') or '', opt('--note'),
                    opt('--after'), opt('--ad-version') or '', '--no-box' not in opts,
                    opt('--tested').split() if '--tested' in opts else None)
    if mode == 'pick':
        opts, rest = args[4:], []
        if '--' in opts:
            opts, rest = opts[:opts.index('--')], opts[opts.index('--') + 1:]
        return pick(scr, args[0], args[1], args[2], args[3], list(zip(rest[0::2], rest[1::2])), '--browse' in opts)
    if mode == 'checklist':
        rest = args[args.index('--') + 1:] if '--' in args else []
        return checklist(scr, args[0], args[1], args[2], list(zip(rest[0::3], rest[1::3], rest[2::3])))
    if mode == 'message':
        return message(scr, args[0], args[1])
    if mode == 'confirm':
        opts = args[2:]
        def opt(name):
            return opts[opts.index(name) + 1] if name in opts else None
        red = [opts[i + 1] for i, o in enumerate(opts[:-1]) if o == '--red']
        return confirm(scr, args[0], args[1], opt('--head'), opt('--warn'), red)
    raise SystemExit(f'tui.py: unknown mode {mode}')


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    locale.setlocale(locale.LC_ALL, '')
    os.environ.setdefault('ESCDELAY', '25')
    result = curses.wrapper(run, sys.argv[1], sys.argv[2:])
    if result is None:
        sys.exit(1)
    os.write(3, result.encode())
    if result.split('\n', 1)[0] == 'cancel':     # a form's values on Esc, to keep for next time
        sys.exit(1)


if __name__ == '__main__':
    main()
