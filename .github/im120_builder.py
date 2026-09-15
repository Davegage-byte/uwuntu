from pathlib import Path
import re

path = Path("Uwuntu Image Manager.sh")
text = path.read_text(encoding="utf-8")
original = text

# Version 1.19 -> 1.20 an Shell, Root-Helper und Frontend.
assert text.count('APP_VERSION="1.19"') == 2
assert text.count('VERSION = "1.19"') == 1
text = text.replace('APP_VERSION="1.19"', 'APP_VERSION="1.20"')
text = text.replace('VERSION = "1.19"', 'VERSION = "1.20"')

# Kompakte Batch-spezifische Darstellung.
old_css = '''.batch-summary {
    font-size: 15px;
    font-weight: 900;
}
.stick-title {
    font-size: 15px;
    font-weight: 900;
}
.stick-ready {
    color: #61d36b;
    font-weight: 900;
}
.stick-error {
    color: #e85d5d;
    font-weight: 900;
}
'''
new_css = '''.batch-summary {
    font-size: 14px;
    font-weight: 900;
}
.batch-stick {
    background: #232329;
    border: 1px solid #34343c;
    border-radius: 8px;
    padding: 5px 7px;
}
.batch-stick-title {
    font-size: 13px;
    font-weight: 900;
}
.batch-stick-detail {
    color: #b6b6bf;
    font-size: 11px;
}
progressbar.batch-progress trough {
    min-height: 14px;
    border-radius: 6px;
}
progressbar.batch-progress progress {
    min-height: 14px;
    border-radius: 6px;
}
.stick-ready {
    color: #61d36b;
    font-weight: 900;
}
.stick-error {
    color: #e85d5d;
    font-weight: 900;
}
'''
assert old_css in text
text = text.replace(old_css, new_css, 1)

# Die gemeinsame Zeitachse bleibt erhalten, wird aber deutlich flacher.
replacements = {
    'self.set_content_height(66)': 'self.set_content_height(46)',
    'x0 = 10.0\n        bar_w = max(10.0, float(width) - 20.0)\n        bar_y = 30.0\n        bar_h = 18.0':
        'x0 = 8.0\n        bar_w = max(10.0, float(width) - 16.0)\n        bar_y = 15.0\n        bar_h = 12.0',
    'cr.set_font_size(12.0)': 'cr.set_font_size(10.0)',
    'cr.move_to(x, 18.0)\n            cr.line_to(x, bar_y + bar_h + 5.0)':
        'cr.move_to(x, 11.0)\n            cr.line_to(x, bar_y + bar_h + 4.0)',
    'cr.move_to(x - label_w / 2.0, 14.0)':
        'cr.move_to(x - label_w / 2.0, 9.0)',
    'cr.move_to(x0, min(float(height) - 3.0, bar_y + bar_h + 16.0))':
        'cr.move_to(x0, float(height) - 2.0)',
    'max(x0, x0 + bar_w - right_w),\n            min(float(height) - 3.0, bar_y + bar_h + 16.0),':
        'max(x0, x0 + bar_w - right_w),\n            float(height) - 2.0,',
}
for old, new in replacements.items():
    assert old in text, old
    text = text.replace(old, new, 1)

# Nur den visuellen Aufbau der Batch-Ansicht ersetzen. Die Worker-/Restore-
# Logik bleibt unverändert.
init_pattern = re.compile(
    r'    def __init__\(self, parent, image, disks\):\n.*?\n    def elapsed\(self\):',
    re.S,
)
init_match = init_pattern.search(text)
assert init_match
new_init = '''    def __init__(self, parent, image, disks):
        super().__init__(
            title="Uwuntu Parallel-Restore",
            transient_for=parent,
            modal=True,
        )
        # 2 Spalten x maximal 5 Reihen: zehn Sticks passen ohne Scrollen
        # zusammen mit Übersicht und Gesamt-Zeitachse in ein normales Display.
        self.set_default_size(1180, 690)
        self.set_deletable(False)

        self.parent_window = parent
        self.image = image
        self.batch_started = time.monotonic()
        self.states = []
        self.rows = []
        self.timeout_id = None

        root = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=6,
        )
        root.set_margin_top(10)
        root.set_margin_bottom(10)
        root.set_margin_start(10)
        root.set_margin_end(10)
        self.set_child(root)

        header = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=12,
        )
        root.append(header)

        title = make_label("PARALLEL-RESTORE", "card-title", wrap=False)
        title.set_hexpand(True)
        header.append(title)

        legend = make_label(
            "Orange = läuft · Grün = sicher ausgeworfen / entfernbar",
            "subtitle",
            wrap=False,
        )
        legend.set_xalign(1.0)
        header.append(legend)

        overview = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=12,
        )
        root.append(overview)

        self.summary = make_label("", "batch-summary", wrap=False)
        self.summary.set_hexpand(True)
        overview.append(self.summary)

        self.batch_eta = make_label(
            "Batch-Prognose wird berechnet …",
            "progress-info",
            wrap=False,
        )
        self.batch_eta.set_xalign(1.0)
        overview.append(self.batch_eta)

        self.timeline = BatchTimeline(self)
        root.append(self.timeline)

        # Kein Scroller: maximal zehn kompakte Kacheln werden als 2 x 5
        # Dashboard angeordnet. So bleibt auch der Gesamtverlauf sichtbar.
        tiles = Gtk.Grid(column_spacing=6, row_spacing=6)
        tiles.set_column_homogeneous(True)
        tiles.set_vexpand(True)
        root.append(tiles)

        for index, disk in enumerate(disks, start=1):
            state = {
                "disk": disk,
                "status": "waiting",
                "started": None,
                "stage": "Wartet auf Start …",
                "stage_index": 0,
                "stage_count": 4,
                "phase_fraction": 0.0,
                "overall_fraction": 0.0,
                "rate_bps": 0.0,
                "eta": None,
                "finished_elapsed": None,
                "error": "",
            }
            self.states.append(state)

            tile = Gtk.Box(
                orientation=Gtk.Orientation.VERTICAL,
                spacing=2,
            )
            tile.add_css_class("batch-stick")
            tile.set_hexpand(True)
            tile.set_vexpand(True)

            model = compact_text(disk.get("model", "Unbekannt"), 27)
            title_label = make_label(
                f"Stick {index} · {model} · {disk['path']}",
                "batch-stick-title",
                wrap=False,
            )
            tile.append(title_label)

            bar = Gtk.ProgressBar()
            bar.set_show_text(True)
            bar.set_fraction(0.0)
            bar.set_text("0 %")
            bar.add_css_class("batch-progress")
            bar.add_css_class("restore-waiting")
            tile.append(bar)

            detail_label = make_label(
                "Wartet auf Start …",
                "batch-stick-detail",
                wrap=False,
            )
            tile.append(detail_label)

            position = index - 1
            column = position % 2
            row_number = position // 2
            tiles.attach(tile, column, row_number, 1, 1)

            self.rows.append(
                {
                    "bar": bar,
                    "detail": detail_label,
                }
            )

        self.close_button = Gtk.Button(label="SCHLIESSEN")
        self.close_button.add_css_class("secondary")
        self.close_button.set_sensitive(False)
        self.close_button.connect("clicked", lambda *_: self.close())
        root.append(self.close_button)

        self._refresh_all()
        self.present()

    def elapsed(self):'''
text = init_pattern.sub(new_init, text, count=1)

refresh_pattern = re.compile(
    r'    def _refresh_row\(self, index\):\n.*?\n    def _refresh_summary\(self\):',
    re.S,
)
refresh_match = refresh_pattern.search(text)
assert refresh_match
new_refresh = '''    def _refresh_row(self, index):
        state = self.states[index]
        row = self.rows[index]
        status = state["status"]
        fraction = max(0.0, min(1.0, state["overall_fraction"]))

        row["bar"].set_fraction(fraction)
        row["bar"].set_text(f"{fraction * 100:.0f} %")

        if status == "ready":
            self._set_bar_class(row["bar"], "restore-ready")
        elif status == "error":
            self._set_bar_class(row["bar"], "restore-error")
        elif status == "waiting":
            self._set_bar_class(row["bar"], "restore-waiting")
        else:
            self._set_bar_class(row["bar"], "restore-running")

        started = state.get("started")
        elapsed = max(0.0, time.monotonic() - started) if started else 0.0
        elapsed_text = fmt_duration(elapsed)

        detail = row["detail"]
        detail.remove_css_class("stick-ready")
        detail.remove_css_class("stick-error")

        if status == "ready":
            detail.set_text(
                "✓ FERTIG · sicher ausgeworfen · "
                + elapsed_text
                + " · kann entfernt werden"
            )
            detail.add_css_class("stick-ready")
        elif status == "done_not_ejected":
            detail.set_text(
                "⚠ Restore fertig · "
                + elapsed_text
                + " · Auswerfen nicht bestätigt · NICHT entfernen"
            )
        elif status == "error":
            detail.set_text(
                "✕ FEHLER · " + compact_text(state.get("error"), 78)
            )
            detail.add_css_class("stick-error")
        else:
            stage_index = state.get("stage_index") or 0
            stage_count = state.get("stage_count") or 4
            rate = fmt_rate(state.get("rate_bps"))
            eta = fmt_eta(state.get("eta"))
            stage = compact_text(state.get("stage"), 31)

            if stage_index:
                detail.set_text(
                    f"P{stage_index}/{stage_count} · {stage} · {rate} · "
                    f"{elapsed_text} · Rest {eta}"
                )
            else:
                detail.set_text(
                    f"{stage} · {elapsed_text} · Rest {eta}"
                )

    def _refresh_summary(self):'''
text = refresh_pattern.sub(new_refresh, text, count=1)

# Der Backend-Restore und dessen Sicherheitslogik müssen bytegenau inhaltlich
# erhalten bleiben; nur Frontend-Layout und Versionsnummer ändern sich.
assert 'safe_to_remove=safe_to_remove' in text
assert 'class BatchRestoreWindow(Gtk.Window):' in text
assert 'Gtk.ScrolledWindow()' in original
# Im BatchRestoreWindow-Block darf kein Scroller mehr vorkommen.
batch_block = text.split('class BatchRestoreWindow(Gtk.Window):', 1)[1].split('\n\nclass ActionWindow', 1)[0]
assert 'Gtk.ScrolledWindow()' not in batch_block
assert 'tiles = Gtk.Grid(column_spacing=6, row_spacing=6)' in batch_block
assert 'column = position % 2' in batch_block
assert 'row_number = position // 2' in batch_block

if text == original:
    raise SystemExit("Keine Änderungen erzeugt")

path.write_text(text, encoding="utf-8")
print("IM1.20 compact parallel UI built")
