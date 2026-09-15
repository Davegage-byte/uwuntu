from pathlib import Path
import re

path = Path("Uwuntu Image Manager.sh")
text = path.read_text(encoding="utf-8")
original = text

# Version 1.18 -> 1.19 an allen drei Stellen.
assert text.count('APP_VERSION="1.18"') == 2
assert text.count('VERSION = "1.18"') == 1
text = text.replace('APP_VERSION="1.18"', 'APP_VERSION="1.19"')
text = text.replace('VERSION = "1.18"', 'VERSION = "1.19"')

# Restore-Erfolg erst NACH sicherem Auswerfen melden.
old_backend = '''        log(f"RESTORE ERFOLGREICH: {image} -> {disk}")

        emit(
            "success",
            message=(
                "Uwuntu wurde erfolgreich auf den Zielstick "
                "wiederhergestellt."
            ),
        )

        run(["udisksctl", "power-off", "-b", disk], check=False)
'''
new_backend = '''        log(f"RESTORE ERFOLGREICH: {image} -> {disk}")

        # Erst nach einem bestätigten UDisks-Power-Off darf die Oberfläche
        # behaupten, dass der einzelne Stick sicher entfernt werden kann.
        poweroff = run(
            ["udisksctl", "power-off", "-b", disk],
            check=False,
            capture=True,
        )
        safe_to_remove = poweroff.returncode == 0

        if safe_to_remove:
            detail = (
                "Der Stick wurde synchronisiert, sicher ausgeworfen und "
                "kann jetzt entfernt werden."
            )
        else:
            poweroff_detail = (
                (poweroff.stderr or poweroff.stdout or "").strip()
            )
            if poweroff_detail:
                log("UDISKS POWER-OFF FEHLER: " + poweroff_detail)
            detail = (
                "Restore und Dateisystemprüfung sind abgeschlossen, aber "
                "das automatische sichere Auswerfen wurde nicht bestätigt. "
                "Den Stick bitte noch nicht entfernen."
            )

        emit(
            "success",
            message=(
                "Uwuntu wurde erfolgreich auf den Zielstick "
                "wiederhergestellt."
            ),
            detail=detail,
            safe_to_remove=safe_to_remove,
            disk=disk,
        )
'''
assert old_backend in text
text = text.replace(old_backend, new_backend, 1)

# Farben für parallele Restore-Zeilen.
css_anchor = '''progressbar progress {
    min-height: 22px;
    border-radius: 9px;
}
"""
'''
css_new = '''progressbar progress {
    min-height: 22px;
    border-radius: 9px;
}
progressbar.restore-waiting progress {
    background: #6b6b73;
}
progressbar.restore-running progress {
    background: #f5a623;
}
progressbar.restore-ready progress {
    background: #61d36b;
}
progressbar.restore-error progress {
    background: #e85d5d;
}
.batch-summary {
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
"""
'''
assert css_anchor in text
text = text.replace(css_anchor, css_new, 1)

batch_classes = r'''
class BatchTimeline(Gtk.DrawingArea):
    """Gemeinsame Zeitachse mit erwarteten Fertig-Zeitpunkten je Stick."""

    def __init__(self, owner):
        super().__init__()
        self.owner = owner
        self.set_content_height(66)
        self.set_hexpand(True)
        self.set_draw_func(self._draw)

    def _draw(self, _area, cr, width, height):
        states = self.owner.states
        elapsed = self.owner.elapsed()

        if not states or width < 80:
            return

        predictions = []
        for state in states:
            finish = state.get("finished_elapsed")
            if finish is None:
                eta = state.get("eta")
                if eta is not None and state.get("status") in {"running", "waiting"}:
                    finish = elapsed + max(0.0, float(eta))
            predictions.append(finish)

        known = [float(value) for value in predictions if value is not None]
        horizon = max([elapsed + 1.0, *known])
        terminal = all(
            state.get("status") in {"ready", "done_not_ejected", "error"}
            for state in states
        )
        if terminal and known:
            horizon = max(known)
        horizon = max(1.0, horizon)

        x0 = 10.0
        bar_w = max(10.0, float(width) - 20.0)
        bar_y = 30.0
        bar_h = 18.0

        # Hintergrund.
        cr.set_source_rgb(0.20, 0.20, 0.24)
        cr.rectangle(x0, bar_y, bar_w, bar_h)
        cr.fill()

        # Verstrichener Batch-Anteil auf der gemeinsamen Zeitachse.
        if terminal and all(state.get("status") == "ready" for state in states):
            cr.set_source_rgb(0.38, 0.83, 0.42)
            batch_fraction = 1.0
        elif terminal and any(state.get("status") == "error" for state in states):
            cr.set_source_rgb(0.91, 0.36, 0.36)
            batch_fraction = 1.0
        else:
            cr.set_source_rgb(0.96, 0.65, 0.14)
            batch_fraction = min(1.0, elapsed / horizon)

        cr.rectangle(x0, bar_y, bar_w * batch_fraction, bar_h)
        cr.fill()

        cr.set_font_size(12.0)

        for index, (state, finish) in enumerate(zip(states, predictions), start=1):
            if finish is None:
                continue

            pos = min(1.0, max(0.0, float(finish) / horizon))
            x = x0 + bar_w * pos

            status = state.get("status")
            if status == "ready":
                cr.set_source_rgb(0.38, 0.83, 0.42)
            elif status == "error":
                cr.set_source_rgb(0.91, 0.36, 0.36)
            else:
                cr.set_source_rgb(0.96, 0.65, 0.14)

            cr.set_line_width(2.0)
            cr.move_to(x, 18.0)
            cr.line_to(x, bar_y + bar_h + 5.0)
            cr.stroke()

            label = str(index)
            ext = cr.text_extents(label)
            try:
                label_w = ext.width
            except Exception:
                label_w = ext[2]
            cr.move_to(x - label_w / 2.0, 14.0)
            cr.show_text(label)

        # Zeitachse links/rechts klein beschriften.
        cr.set_source_rgb(0.65, 0.65, 0.70)
        cr.set_font_size(10.0)
        cr.move_to(x0, min(float(height) - 3.0, bar_y + bar_h + 16.0))
        cr.show_text("0:00")

        right = fmt_eta(max(0.0, horizon - elapsed))
        ext = cr.text_extents(right)
        try:
            right_w = ext.width
        except Exception:
            right_w = ext[2]
        cr.move_to(
            max(x0, x0 + bar_w - right_w),
            min(float(height) - 3.0, bar_y + bar_h + 16.0),
        )
        cr.show_text(right)


class BatchRestoreWindow(Gtk.Window):
    TERMINAL = {"ready", "done_not_ejected", "error"}

    def __init__(self, parent, image, disks):
        super().__init__(
            title="Uwuntu Parallel-Restore",
            transient_for=parent,
            modal=True,
        )
        self.set_default_size(1080, 760)
        self.set_deletable(False)

        self.parent_window = parent
        self.image = image
        self.batch_started = time.monotonic()
        self.states = []
        self.rows = []
        self.timeout_id = None

        root = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=10,
        )
        root.set_margin_top(16)
        root.set_margin_bottom(16)
        root.set_margin_start(16)
        root.set_margin_end(16)
        self.set_child(root)

        root.append(make_label("PARALLEL-RESTORE", "card-title"))
        root.append(
            make_label(
                "Alle ausgewählten Sticks werden gleichzeitig beschrieben. "
                "Grün bedeutet erst dann: sicher ausgeworfen und entfernbar.",
                "card-text",
            )
        )

        self.summary = make_label("", "batch-summary", wrap=False)
        root.append(self.summary)

        self.timeline = BatchTimeline(self)
        root.append(self.timeline)

        self.batch_eta = make_label(
            "Batch-Prognose wird berechnet …",
            "progress-info",
            wrap=False,
        )
        root.append(self.batch_eta)

        scroller = Gtk.ScrolledWindow()
        scroller.set_vexpand(True)
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        root.append(scroller)

        rows_box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=10,
        )
        scroller.set_child(rows_box)

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

            card = Gtk.Box(
                orientation=Gtk.Orientation.VERTICAL,
                spacing=6,
            )
            card.add_css_class("card")

            title = make_label(
                f"Stick {index} · {disk.get('model', 'Unbekannt')} · {disk['path']}",
                "stick-title",
                wrap=False,
            )
            card.append(title)

            bar = Gtk.ProgressBar()
            bar.set_show_text(True)
            bar.set_fraction(0.0)
            bar.set_text("0 %")
            bar.add_css_class("restore-waiting")
            card.append(bar)

            info_row = Gtk.Box(
                orientation=Gtk.Orientation.HORIZONTAL,
                spacing=12,
            )
            card.append(info_row)

            elapsed_label = make_label(
                "Läuft: 0 s",
                "progress-info",
                wrap=False,
            )
            elapsed_label.set_size_request(170, -1)
            info_row.append(elapsed_label)

            phase_label = make_label(
                "Wartet …",
                "progress-info",
                wrap=False,
            )
            phase_label.set_hexpand(True)
            info_row.append(phase_label)

            eta_label = make_label(
                "Rest: berechne …",
                "progress-info",
                wrap=False,
            )
            eta_label.set_xalign(1.0)
            eta_label.set_size_request(190, -1)
            info_row.append(eta_label)

            status_label = make_label(
                "Bitte eingesteckt lassen.",
                "subtitle",
            )
            card.append(status_label)

            rows_box.append(card)
            self.rows.append(
                {
                    "bar": bar,
                    "elapsed": elapsed_label,
                    "phase": phase_label,
                    "eta": eta_label,
                    "status": status_label,
                }
            )

        self.close_button = Gtk.Button(label="SCHLIESSEN")
        self.close_button.add_css_class("secondary")
        self.close_button.set_sensitive(False)
        self.close_button.connect("clicked", lambda *_: self.close())
        root.append(self.close_button)

        self._refresh_all()
        self.present()

    def elapsed(self):
        return max(0.0, time.monotonic() - self.batch_started)

    def start(self):
        self.batch_started = time.monotonic()
        for index, state in enumerate(self.states):
            state["status"] = "running"
            state["started"] = time.monotonic()
            self._refresh_row(index)
            threading.Thread(
                target=self._worker,
                args=(index,),
                daemon=True,
            ).start()

        self.timeout_id = GLib.timeout_add_seconds(1, self._tick)
        self._refresh_all()

    def _worker(self, index):
        state = self.states[index]
        disk = state["disk"]
        command = [
            "sudo",
            "-n",
            ROOT_HELPER,
            "restore",
            "--disk",
            disk["path"],
            "--image",
            str(self.image["path"]),
        ]

        saw_success = False
        saw_error = False

        try:
            proc = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )

            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue

                try:
                    event = json.loads(line)
                except Exception:
                    continue

                if event.get("type") == "success":
                    saw_success = True
                elif event.get("type") == "error":
                    saw_error = True

                GLib.idle_add(self.handle_event, index, event)

            rc = proc.wait()

            if rc != 0 and not saw_error:
                GLib.idle_add(
                    self.handle_event,
                    index,
                    {
                        "type": "error",
                        "message": (
                            "Restore-Prozess wurde mit einem Fehler beendet. "
                            "Details stehen im Log."
                        ),
                    },
                )
            elif rc == 0 and not saw_success:
                GLib.idle_add(
                    self.handle_event,
                    index,
                    {
                        "type": "error",
                        "message": "Restore endete ohne Erfolgsbestätigung.",
                    },
                )
        except Exception as exc:
            GLib.idle_add(
                self.handle_event,
                index,
                {"type": "error", "message": str(exc)},
            )

    def _set_bar_class(self, bar, css_class):
        for name in (
            "restore-waiting",
            "restore-running",
            "restore-ready",
            "restore-error",
        ):
            bar.remove_css_class(name)
        bar.add_css_class(css_class)

    def handle_event(self, index, data):
        state = self.states[index]
        typ = data.get("type")

        if typ == "stage":
            state["stage"] = data.get("stage", "")
            state["stage_index"] = int(data.get("stage_index") or 1)
            state["stage_count"] = max(1, int(data.get("stage_count") or 1))
            state["phase_fraction"] = 0.0
            state["overall_fraction"] = max(
                0.0,
                min(
                    1.0,
                    (state["stage_index"] - 1) / state["stage_count"],
                ),
            )

        elif typ == "progress":
            fraction = max(
                0.0,
                min(1.0, float(data.get("fraction") or 0.0)),
            )
            stage_index = int(data.get("stage_index") or state["stage_index"] or 1)
            stage_count = max(1, int(data.get("stage_count") or state["stage_count"] or 1))

            state["stage"] = data.get("stage") or state["stage"]
            state["stage_index"] = stage_index
            state["stage_count"] = stage_count
            state["phase_fraction"] = fraction
            state["overall_fraction"] = max(
                0.0,
                min(1.0, ((stage_index - 1) + fraction) / stage_count),
            )
            try:
                state["rate_bps"] = float(data.get("rate_bps") or 0.0)
            except Exception:
                state["rate_bps"] = 0.0

            started = state.get("started")
            elapsed = max(0.0, time.monotonic() - started) if started else 0.0
            overall = state["overall_fraction"]
            if overall >= 0.01 and overall < 0.999 and elapsed >= 2.0:
                raw_eta = elapsed * (1.0 - overall) / overall
                if state["eta"] is None:
                    state["eta"] = raw_eta
                else:
                    state["eta"] = 0.84 * state["eta"] + 0.16 * raw_eta
            elif overall >= 0.999:
                state["eta"] = 0.0

        elif typ == "success":
            state["overall_fraction"] = 1.0
            state["phase_fraction"] = 1.0
            state["eta"] = 0.0
            state["finished_elapsed"] = self.elapsed()

            if bool(data.get("safe_to_remove")):
                state["status"] = "ready"
                state["stage"] = "Fertig"
            else:
                state["status"] = "done_not_ejected"
                state["stage"] = "Restore fertig · Auswerfen nicht bestätigt"

        elif typ == "error":
            state["status"] = "error"
            state["error"] = data.get("message", "Unbekannter Fehler.")
            state["eta"] = 0.0
            state["finished_elapsed"] = self.elapsed()

        self._refresh_row(index)
        self._refresh_summary()
        self.timeline.queue_draw()
        return False

    def _refresh_row(self, index):
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
        if started:
            elapsed = max(0.0, time.monotonic() - started)
        else:
            elapsed = 0.0
        row["elapsed"].set_text("Läuft: " + fmt_duration(elapsed))

        stage_index = state.get("stage_index") or 0
        stage_count = state.get("stage_count") or 4
        rate = fmt_rate(state.get("rate_bps"))
        if stage_index:
            row["phase"].set_text(
                f"Phase {stage_index}/{stage_count} · {state['stage']} · {rate}"
            )
        else:
            row["phase"].set_text(state["stage"])

        if status in self.TERMINAL:
            row["eta"].set_text("Rest: 0 s")
        else:
            row["eta"].set_text("Rest: ca. " + fmt_eta(state.get("eta")))

        if status == "ready":
            row["status"].set_text(
                "✓ Sicher ausgeworfen · kann jetzt entfernt werden"
            )
            row["status"].remove_css_class("stick-error")
            row["status"].add_css_class("stick-ready")
        elif status == "done_not_ejected":
            row["status"].set_text(
                "⚠ Restore fertig · Auswerfen fehlgeschlagen · noch nicht entfernen"
            )
            row["status"].remove_css_class("stick-ready")
            row["status"].remove_css_class("stick-error")
        elif status == "error":
            row["status"].set_text(
                "✕ FEHLER · " + compact_text(state.get("error"), 100)
            )
            row["status"].remove_css_class("stick-ready")
            row["status"].add_css_class("stick-error")
        else:
            row["status"].set_text("Bitte eingesteckt lassen.")
            row["status"].remove_css_class("stick-ready")
            row["status"].remove_css_class("stick-error")

    def _refresh_summary(self):
        counts = {
            "waiting": 0,
            "running": 0,
            "ready": 0,
            "done_not_ejected": 0,
            "error": 0,
        }
        for state in self.states:
            counts[state["status"]] = counts.get(state["status"], 0) + 1

        parts = [f"{len(self.states)} STICKS"]
        if counts["running"]:
            parts.append(f"{counts['running']} laufen")
        if counts["ready"]:
            parts.append(f"{counts['ready']} sicher entfernbar")
        if counts["done_not_ejected"]:
            parts.append(f"{counts['done_not_ejected']} nicht ausgeworfen")
        if counts["error"]:
            parts.append(f"{counts['error']} Fehler")
        if counts["waiting"]:
            parts.append(f"{counts['waiting']} warten")

        self.summary.set_text(" · ".join(parts))

        active_etas = [
            state.get("eta")
            for state in self.states
            if state.get("status") in {"running", "waiting"}
            and state.get("eta") is not None
        ]

        if all(state["status"] in self.TERMINAL for state in self.states):
            self.batch_eta.set_text(
                "Batch abgeschlossen · Gesamtzeit " + fmt_duration(self.elapsed())
            )
            self.set_deletable(True)
            self.close_button.set_sensitive(True)
        elif active_etas:
            self.batch_eta.set_text(
                "Gesamtzeit "
                + fmt_duration(self.elapsed())
                + " · Batch voraussichtlich fertig in ca. "
                + fmt_eta(max(active_etas))
            )
        else:
            self.batch_eta.set_text(
                "Gesamtzeit "
                + fmt_duration(self.elapsed())
                + " · Batch-Prognose wird berechnet …"
            )

    def _refresh_all(self):
        for index in range(len(self.states)):
            self._refresh_row(index)
        self._refresh_summary()
        self.timeline.queue_draw()

    def _tick(self):
        self._refresh_all()
        if all(state["status"] in self.TERMINAL for state in self.states):
            self.timeout_id = None
            return False
        return True


'''
insert_anchor = 'class ActionWindow(Gtk.Window):\n'
assert insert_anchor in text
text = text.replace(insert_anchor, batch_classes + insert_anchor, 1)

# Hauptkarte auf Mehrfach-Restore hinweisen.
old_card = '''                "Schreibt ein gespeichertes .uwuntu-Image auf einen anderen "
                "Stick. Das Ziellayout wird automatisch an die reale "
                "Kapazität des Zielsticks angepasst und bleibt maximal "
                "29 GiB groß.",
'''
new_card = '''                "Schreibt ein gespeichertes .uwuntu-Image auf einen oder "
                "mehrere Sticks gleichzeitig. Jeder Stick hat eigenen "
                "Fortschritt, Rate und Restzeit und wird nach erfolgreichem "
                "Abschluss einzeln sicher ausgeworfen.",
'''
assert old_card in text
text = text.replace(old_card, new_card, 1)

# Restore-Auswahl von einem Dropdown auf bis zu 10 parallele Ziele umstellen.
start_marker = '    def open_restore(self, *_):\n'
end_marker = '    # --------------------------------------------------------\n    # Ventoy\n'
start = text.index(start_marker)
end = text.index(end_marker, start)
new_restore = r'''    def open_restore(self, *_):
        images = image_items()

        if not images:
            self.error(
                "Im Uwuntu-Image-Ordner wurde noch kein gültiges "
                ".uwuntu-Image gefunden."
            )
            return

        disks = list_disks()

        if not disks:
            self.error(
                "Kein geeigneter Ziel-Datenträger wurde gefunden.\n\n"
                "Neue Sticks einstecken und erneut öffnen."
            )
            return

        win = ActionWindow(self, "Uwuntu wiederherstellen")

        win.root.append(
            make_label("UWUNTU WIEDERHERSTELLEN", "card-title")
        )

        win.root.append(
            make_label(
                "Wähle das Image und danach bis zu 10 Zielsticks. Alle "
                "ausgewählten Sticks werden parallel beschrieben. ALLE "
                "Daten auf diesen Zielsticks werden gelöscht. Der laufende "
                "Ubuntu-Datenträger bleibt geschützt.",
                "card-text",
            )
        )

        image_dd = dropdown_from_strings(
            [image_display(item) for item in images]
        )
        win.root.append(image_dd)

        details = make_label(image_details(images[0]), "details")
        win.root.append(details)

        def image_changed(dd, _pspec):
            idx = dd.get_selected()
            if idx < len(images):
                details.set_text(image_details(images[idx]))

        image_dd.connect("notify::selected", image_changed)

        target_title = make_label(
            "ZIELSTICKS AUSWÄHLEN · maximal 10",
            "progress-info",
        )
        win.root.append(target_title)

        target_scroller = Gtk.ScrolledWindow()
        target_scroller.set_policy(
            Gtk.PolicyType.NEVER,
            Gtk.PolicyType.AUTOMATIC,
        )
        target_scroller.set_min_content_height(150)
        target_scroller.set_max_content_height(230)
        win.root.append(target_scroller)

        target_box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=5,
        )
        target_box.set_margin_top(6)
        target_box.set_margin_bottom(6)
        target_box.set_margin_start(6)
        target_box.set_margin_end(6)
        target_scroller.set_child(target_box)

        checks = []
        selected_label = make_label(
            "0 Sticks ausgewählt",
            "details",
        )

        def update_selected(*_):
            count = sum(1 for check, _disk in checks if check.get_active())
            selected_label.set_text(f"{count} Sticks ausgewählt")

        for disk in disks:
            check = Gtk.CheckButton(label=disk_display(disk))
            check.connect("toggled", update_selected)
            target_box.append(check)
            checks.append((check, disk))

        win.root.append(selected_label)

        warning = make_label(
            "ACHTUNG: Jeder ausgewählte Zielstick wird vollständig gelöscht. "
            "Ein Stick wird erst GRÜN angezeigt, wenn das sichere Auswerfen "
            "vom System bestätigt wurde.",
            "warning",
        )
        win.root.append(warning)

        buttons = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=8,
        )
        win.root.append(buttons)

        cancel = Gtk.Button(label="ABBRECHEN")
        cancel.add_css_class("secondary")
        cancel.set_hexpand(True)
        cancel.connect("clicked", lambda *_: win.close())
        buttons.append(cancel)

        start_button = Gtk.Button(label="PARALLEL-RESTORE STARTEN")
        start_button.add_css_class("primary")
        start_button.set_hexpand(True)

        def clicked(*_):
            image_idx = image_dd.get_selected()
            if image_idx >= len(images):
                return

            selected = [disk for check, disk in checks if check.get_active()]

            if not selected:
                self.error("Bitte mindestens einen Zielstick auswählen.")
                return

            if len(selected) > 10:
                self.error(
                    "Für einen Batch sind maximal 10 Zielsticks vorgesehen."
                )
                return

            image = images[image_idx]
            targets = "\n".join(
                f"Stick {index}: {disk_display(disk)}"
                for index, disk in enumerate(selected, start=1)
            )

            def begin_batch():
                win.close()
                batch = BatchRestoreWindow(self, image, selected)
                self._active_restore_batch = batch
                batch.start()

            self.confirm(
                f"{len(selected)} ZIELSTICK(S) WIRKLICH LÖSCHEN?",
                f"Image:\n{image_display(image)}\n\n"
                f"Ziele:\n{targets}\n\n"
                "Alle ausgewählten Sticks werden gleichzeitig neu "
                "partitioniert und beschrieben. Fertige Sticks dürfen "
                "erst entfernt werden, wenn ihre Zeile GRÜN ist und "
                "'kann jetzt entfernt werden' anzeigt.",
                begin_batch,
            )

        start_button.connect("clicked", clicked)
        buttons.append(start_button)

        win.present()

'''
text = text[:start] + new_restore + text[end:]

if text == original:
    raise SystemExit("Keine Änderung erzeugt")

# Sicherheitsprüfungen.
assert text.count('APP_VERSION="1.19"') == 2
assert text.count('VERSION = "1.19"') == 1
assert 'class BatchRestoreWindow(Gtk.Window):' in text
assert 'safe_to_remove=safe_to_remove' in text
assert 'PARALLEL-RESTORE STARTEN' in text
assert 'maximal 10' in text

path.write_text(text, encoding="utf-8")
print("IM1.19 Transformation abgeschlossen")
