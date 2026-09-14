from pathlib import Path

PATH = Path("Uwuntu Image Manager.sh")
text = PATH.read_text(encoding="utf-8")


def replace_once(old, new, label):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: erwartet 1 Treffer, gefunden {count}")
    text = text.replace(old, new, 1)


def replace_range(start_marker, end_marker, replacement, label, start_at=0):
    global text
    start = text.find(start_marker, start_at)
    if start < 0:
        raise SystemExit(f"{label}: Startmarker fehlt")
    end = text.find(end_marker, start + len(start_marker))
    if end < 0:
        raise SystemExit(f"{label}: Endmarker fehlt")
    text = text[:start] + replacement + text[end:]


# Version und Format
replace_once('APP_VERSION="1.15"', 'APP_VERSION="1.16"', 'Shell-Version')
replace_once('APP_VERSION = "1.15"', 'APP_VERSION = "1.16"', 'Root-Version')
replace_once(
    'FORMAT_VERSION = "uwuntu-image-v2"\nSUPPORTED_FORMAT_VERSIONS = {"uwuntu-image-v1", FORMAT_VERSION}',
    'FORMAT_VERSION = "uwuntu-image-v3"\nSUPPORTED_FORMAT_VERSIONS = {"uwuntu-image-v1", "uwuntu-image-v2", FORMAT_VERSION}',
    'Format-Version',
)
replace_once('VERSION = "1.15"', 'VERSION = "1.16"', 'Frontend-Version')


# Neue ext3/ext4-Helfer. Die bisherigen tar-Helfer bleiben für alte v1/v2-Images erhalten.
helper_marker = 'def stream_tar_to_zstd(mountpoint, target, estimate, progress):\n'
helpers = '''def ext_partclone_program(fstype):
    fstype = str(fstype or "").lower()
    if fstype == "ext3":
        return "partclone.ext3"
    if fstype == "ext4":
        return "partclone.ext4"
    raise RuntimeError(
        f"Nicht unterstütztes Persistenz-Dateisystem: {fstype or 'unbekannt'}"
    )


def ext_filesystem_size_bytes(path):
    info = output(
        ["env", "LC_ALL=C", "dumpe2fs", "-h", str(path)],
        timeout=30,
    )

    block_count = None
    block_size = None

    for line in info.splitlines():
        if line.startswith("Block count:"):
            block_count = int(line.split(":", 1)[1].strip())
        elif line.startswith("Block size:"):
            block_size = int(line.split(":", 1)[1].strip())

    if not block_count or not block_size:
        raise RuntimeError(
            "Größe des kompakten Persistenz-Dateisystems konnte nicht "
            "ermittelt werden."
        )

    return block_count * block_size


def prepare_compact_ext_image(source, target, source_size, progress):
    target.unlink(missing_ok=True)

    # Rohes ext-Abbild als sparse Datei: unbenutzte Blöcke werden nicht
    # physisch kopiert. Der Master-Stick selbst bleibt unverändert.
    run(["e2image", "-rap", str(source), str(target)])
    progress.update(1, force=True)

    run(["e2fsck", "-fy", str(target)])
    run(["resize2fs", "-M", str(target)])
    minimum_size = ext_filesystem_size_bytes(target)
    progress.update(2, force=True)

    # Etwas freien Spielraum im gespeicherten Dateisystem lassen. Trotzdem
    # bleibt es kompakt genug, um auf unterschiedlich großen 32-GB-Sticks
    # wiederhergestellt und danach auf die Zielpartition erweitert zu werden.
    compact_size = min(
        int(source_size),
        math.ceil((minimum_size + 256 * MIB) / MIB) * MIB,
    )

    if compact_size < minimum_size:
        raise RuntimeError(
            "Kompaktes Persistenz-Dateisystem ist größer als die Quellpartition."
        )

    with open(target, "r+b") as handle:
        handle.truncate(compact_size)

    if compact_size > minimum_size:
        run(["resize2fs", str(target)])

    run(["e2fsck", "-fy", str(target)])
    actual_size = ext_filesystem_size_bytes(target)

    if actual_size > compact_size:
        raise RuntimeError(
            "Das vorbereitete Persistenz-Dateisystem überschreitet seine "
            "kompakte Zielgröße."
        )

    progress.finish(3)
    return compact_size


def stream_ext_partclone_to_zstd(
    source,
    target,
    total,
    progress,
    fstype,
):
    program = ext_partclone_program(fstype)
    log_handle = LOG_FILE.open("a", encoding="utf-8")
    partclone_proc = subprocess.Popen(
        [program, "-c", "-s", str(source), "-o", "-", "-q"],
        stdout=subprocess.PIPE,
        stderr=log_handle,
    )
    zstd_proc = subprocess.Popen(
        ["zstd", "-T0", "-3", "-q", "-o", str(target)],
        stdin=subprocess.PIPE,
        stdout=log_handle,
        stderr=log_handle,
    )

    done = 0
    partclone_rc = None
    zstd_rc = None
    pipeline_error = None

    try:
        while True:
            chunk = partclone_proc.stdout.read(CHUNK)
            if not chunk:
                break

            zstd_proc.stdin.write(chunk)
            done += len(chunk)
            progress.update(done)

        zstd_proc.stdin.close()
        partclone_rc = partclone_proc.wait()
        zstd_rc = zstd_proc.wait()
    except Exception as exc:
        pipeline_error = exc
        try:
            zstd_proc.stdin.close()
        except Exception:
            pass

        for proc in (partclone_proc, zstd_proc):
            try:
                if proc.poll() is None:
                    proc.terminate()
            except Exception:
                pass

        for proc in (partclone_proc, zstd_proc):
            try:
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
    finally:
        try:
            partclone_proc.stdout.close()
        except Exception:
            pass
        log_handle.close()

    if pipeline_error is not None:
        raise RuntimeError(
            f"Partclone-Persistenz-Backup fehlgeschlagen: {pipeline_error}"
        ) from pipeline_error
    if partclone_rc != 0:
        raise RuntimeError("Partclone-Sicherung der Persistenz ist fehlgeschlagen.")
    if zstd_rc != 0:
        raise RuntimeError("zstd-Komprimierung der Persistenz ist fehlgeschlagen.")

    progress.finish(done)
    return done


'''
replace_once(helper_marker, helpers + helper_marker, 'Persistenz-Helfer')


# Neue v3-Paketstruktur.
package_start = text.index('def package_image(')
package_end = text.index('\ndef feed_member_to_zstd', package_start)
package = text[package_start:package_end]
old_member = '        "persistence.tar.zst",\n'
if package.count(old_member) != 1:
    raise SystemExit('package_image: persistence.tar.zst nicht eindeutig')
package = package.replace(old_member, '        "persistence.ext.partclone.zst",\n', 1)
text = text[:package_start] + package + text[package_end:]


# Backup: Persistenz nicht mehr als Dateibaum tar-en, sondern lokal kompakt
# machen und blockbasiert sichern.
backup_start = text.index('def backup(args):')
backup_end = text.index('\n\n# ============================================================\n# Restore', backup_start)
backup = text[backup_start:backup_end]
phase_start = backup.index('        # ----------------------------------------------------\n        # 2/4 Persistenz')
phase_end = backup.index('        # ----------------------------------------------------\n        # 3/4 Metadaten / Prüfsummen', phase_start)
new_phase = '''        # ----------------------------------------------------
        # 2/5 Persistenz-Dateisystem kompakt vorbereiten
        # ----------------------------------------------------
        compact_ext = temp_dir / "persistence.compact.ext"

        p = Progress(
            "Persistenz für Schnell-Restore vorbereiten",
            2,
            5,
            3,
            "VORBEREITEN",
        )

        compact_size_bytes = prepare_compact_ext_image(
            p2,
            compact_ext,
            p2_info["size_bytes"],
            p,
        )

        # ----------------------------------------------------
        # 3/5 Persistenz blockweise sichern
        # ----------------------------------------------------
        persistence_zst = temp_dir / "persistence.ext.partclone.zst"

        p = Progress(
            "Persistenz blockweise sichern",
            3,
            5,
            compact_size_bytes,
            "LESEN",
        )

        persistence_stream_bytes = stream_ext_partclone_to_zstd(
            compact_ext,
            persistence_zst,
            compact_size_bytes,
            p,
            p2_info["fstype"],
        )

        compact_ext.unlink(missing_ok=True)

'''
backup = backup[:phase_start] + new_phase + backup[phase_end:]
backup = backup.replace(
    '            1,\n            4,\n            p1_info["size_bytes"],',
    '            1,\n            5,\n            p1_info["size_bytes"],',
    1,
)
backup = backup.replace('# 3/4 Metadaten / Prüfsummen', '# 4/5 Metadaten / Prüfsummen', 1)
backup = backup.replace(
    '            "Image prüfen und vorbereiten",\n            3,\n            4,',
    '            "Image prüfen und vorbereiten",\n            4,\n            5,',
    1,
)
backup = backup.replace(
    '            "persistence.tar.zst": hash_file(persistence_zst),',
    '            "persistence.ext.partclone.zst": hash_file(persistence_zst),',
    1,
)
old_p2_meta = '''            "partition2": {
                **p2_info,
                "backup": "persistence.tar.zst",
                "tar_stream_bytes": tar_stream_bytes,
            },'''
new_p2_meta = '''            "partition2": {
                **p2_info,
                "backup": "persistence.ext.partclone.zst",
                "backup_method": f"partclone-{p2_info['fstype']}",
                "partclone_stream_bytes": persistence_stream_bytes,
                "compact_size_bytes": compact_size_bytes,
            },'''
if old_p2_meta not in backup:
    raise SystemExit('Backup-Metadatenblock für Partition 2 fehlt')
backup = backup.replace(old_p2_meta, new_p2_meta, 1)
backup = backup.replace('# 4/4 Einzelne .uwuntu-Datei', '# 5/5 Einzelne .uwuntu-Datei', 1)
backup = backup.replace(
    '            "Einzelnes .uwuntu-Image erstellen",\n            4,\n            4,',
    '            "Einzelnes .uwuntu-Image erstellen",\n            5,\n            5,',
    1,
)
if 'tar_stream_bytes' in backup:
    raise SystemExit('Neuer Backup-Pfad enthält noch tar_stream_bytes')
text = text[:backup_start] + backup + text[backup_end:]


# Neuer Restore-Helfer für die v3-Persistenz.
restore_marker = 'def restore(args):\n'
restore_helper = '''def restore_persistence_partclone_member(
    image,
    metadata,
    target,
    progress,
):
    p2_meta = metadata["partition2"]
    member_name = str(p2_meta.get("backup") or "")

    if member_name != "persistence.ext.partclone.zst":
        raise RuntimeError(
            "Partclone-Persistenz enthält einen unerwarteten Dateinamen."
        )

    expected_stream = int(p2_meta.get("partclone_stream_bytes") or 0)
    if expected_stream <= 0:
        raise RuntimeError("Partclone-Persistenz-Streamgröße fehlt im Image.")

    source_fs = str(p2_meta.get("fstype") or "").lower()
    program = ext_partclone_program(source_fs)
    if p2_meta.get("backup_method") != f"partclone-{source_fs}":
        raise RuntimeError(
            "Partclone-Persistenz enthält keine gültige Backup-Methode."
        )

    expected_hash = metadata["checksums"][member_name]
    zstd, thread, result, log_handle = feed_member_to_zstd(
        image,
        member_name,
        expected_hash,
    )

    partclone_log = LOG_FILE.open("a", encoding="utf-8")
    partclone_proc = subprocess.Popen(
        [program, "-r", "-s", "-", "-o", str(target), "-q"],
        stdin=subprocess.PIPE,
        stdout=partclone_log,
        stderr=partclone_log,
    )

    done = 0
    zstd_rc = None
    partclone_rc = None
    pipeline_error = None

    try:
        while True:
            chunk = zstd.stdout.read(CHUNK)
            if not chunk:
                break

            partclone_proc.stdin.write(chunk)
            done += len(chunk)
            progress.update(done)

        partclone_proc.stdin.close()
        zstd_rc = zstd.wait()
        partclone_rc = partclone_proc.wait()
        thread.join()
    except Exception as exc:
        pipeline_error = exc
        try:
            partclone_proc.stdin.close()
        except Exception:
            pass

        for proc in (zstd, partclone_proc):
            try:
                if proc.poll() is None:
                    proc.terminate()
            except Exception:
                pass

        try:
            thread.join(timeout=5)
        except Exception:
            pass
    finally:
        log_handle.close()
        partclone_log.close()

    if pipeline_error is not None:
        if result.get("error"):
            raise result["error"]
        raise RuntimeError(
            f"Partclone-Persistenz-Restore fehlgeschlagen: {pipeline_error}"
        ) from pipeline_error
    if zstd_rc != 0:
        raise RuntimeError("Partclone-Persistenz konnte nicht dekomprimiert werden.")
    if partclone_rc != 0:
        raise RuntimeError(
            "Partclone-Wiederherstellung der Persistenz ist fehlgeschlagen."
        )

    check_member_hash(result, expected_hash)

    if done != expected_stream:
        raise RuntimeError(
            "Partclone-Persistenz-Stream hat eine unerwartete Größe "
            f"({done} statt {expected_stream} Bytes)."
        )

    progress.finish(done)


'''
replace_once(restore_marker, restore_helper + restore_marker, 'Restore-Persistenz-Helfer')


# Restore-Pfad: v3 benutzt kompaktes Dateisystem + Partclone und wächst danach
# auf die reale Zielpartition. V1/V2 bleiben unverändert kompatibel.
restore_start = text.index('def restore(args):')
restore_end = text.index('\n\n# ============================================================\n# Ventoy Update', restore_start)
restore = text[restore_start:restore_end]
old_p2_used = '''    # Tatsächlich gespeicherte Nutzdaten der ext4-Seite.
    p2_used = int(
        metadata["partition2"].get("tar_stream_bytes")
        or metadata["partition2"].get("size_bytes")
        or 0
    )'''
new_p2_used = '''    p2_meta = metadata["partition2"]

    if metadata.get("format") == "uwuntu-image-v3":
        p2_used = int(p2_meta.get("compact_size_bytes") or 0)
        if p2_used <= 0:
            raise RuntimeError("Kompakte Persistenzgröße fehlt im Image.")
    else:
        # V1/V2 verwenden weiterhin das bisherige tar-Format.
        p2_used = int(
            p2_meta.get("tar_stream_bytes")
            or p2_meta.get("size_bytes")
            or 0
        )'''
if old_p2_used not in restore:
    raise SystemExit('Restore p2_used Block fehlt')
restore = restore.replace(old_p2_used, new_p2_used, 1)
restore = restore.replace(
    'metadata.get("format") == "uwuntu-image-v2"',
    'metadata.get("format") in {"uwuntu-image-v2", "uwuntu-image-v3"}',
)
persist_start = restore.index('        # ----------------------------------------------------\n        # 3/4 Persistenz')
persist_end = restore.index('        # ----------------------------------------------------\n        # 4/4 Abschlussprüfung', persist_start)
new_restore_persist = '''        # ----------------------------------------------------
        # 3/4 Persistenz
        # ----------------------------------------------------
        p2_meta = metadata["partition2"]

        source_fs = str(p2_meta.get("fstype") or "").lower()
        if source_fs not in {"ext3", "ext4"}:
            raise RuntimeError(
                "Nicht unterstütztes Persistenz-Dateisystem im Image: "
                f"{source_fs or 'unbekannt'}"
            )

        if metadata.get("format") == "uwuntu-image-v3":
            persistence_total = int(
                p2_meta.get("partclone_stream_bytes") or 0
            )
            if persistence_total <= 0:
                raise RuntimeError(
                    "Partclone-Persistenz-Streamgröße fehlt im Image."
                )

            p = Progress(
                "Persistenz blockweise wiederherstellen",
                3,
                4,
                persistence_total,
                "SCHREIBEN",
            )

            restore_persistence_partclone_member(
                image,
                metadata,
                p2,
                p,
            )

            run(["e2fsck", "-fy", p2])
            run(["resize2fs", p2])
        else:
            mkfs_program = (
                "mkfs.ext3"
                if source_fs == "ext3"
                else "mkfs.ext4"
            )
            mkfs_args = [mkfs_program, "-F"]

            label = str(p2_meta.get("label") or "")
            uuid = str(p2_meta.get("uuid") or "")

            if label:
                mkfs_args += ["-L", label]

            if re.fullmatch(
                r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{12}",
                uuid,
            ):
                mkfs_args += ["-U", uuid]

            mkfs_args.append(p2)

            run(mkfs_args)
            run(["mount", p2, str(mount_dir)])

            p = Progress(
                "Persistenz wiederherstellen",
                3,
                4,
                int(p2_meta["tar_stream_bytes"]),
                "SCHREIBEN",
            )

            restore_persistence_member(
                image,
                metadata,
                mount_dir,
                p,
            )

            run(["sync"], check=False)
            run(["umount", str(mount_dir)])

'''
restore = restore[:persist_start] + new_restore_persist + restore[persist_end:]
restore = restore.replace(
    '''        # Die Persistenz wurde gerade neu angelegt, beschrieben, synchronisiert
        # und sauber ausgehängt. Ohne -f überspringt e2fsck auf einem sauberen
        # Dateisystem den teuren erzwungenen Vollscan.''',
    '''        # Keine erzwungene zweite Vollprüfung: auf einem sauberen
        # Dateisystem beendet sich e2fsck hier schnell.''',
    1,
)
text = text[:restore_start] + restore + text[restore_end:]


# Ventoy muss neue v3-Images ebenfalls verstehen. Die vorhandene Uwuntu.dat
# bestimmt weiterhin Größe und UUID; nur ihr Inhalt wird blockbasiert ersetzt.
ventoy_start = text.index('def ventoy_update(args):')
ventoy_end = text.index('\n\n# ============================================================\n# Online-Update', ventoy_start)
ventoy = text[ventoy_start:ventoy_end]
old_required = '    required = int(metadata["partition2"]["tar_stream_bytes"] * 1.05) + 256 * MIB'
new_required = '''    p2_meta = metadata["partition2"]
    if metadata.get("format") == "uwuntu-image-v3":
        required = int(p2_meta.get("compact_size_bytes") or 0)
        if required <= 0:
            raise RuntimeError("Kompakte Persistenzgröße fehlt im Image.")
    else:
        required = int(p2_meta["tar_stream_bytes"] * 1.05) + 256 * MIB'''
if old_required not in ventoy:
    raise SystemExit('Ventoy required Block fehlt')
ventoy = ventoy.replace(old_required, new_required, 1)
ventoy = ventoy.replace('    rollback_needed = False\n', '    rollback_needed = False\n    loopdev = ""\n', 1)

mkfs_start = ventoy.index('        mkfs = ["mkfs.ext4", "-F", "-L", "casper-rw"]')
mkfs_end = ventoy.index('        emit(\n            "progress",', mkfs_start)
new_mkfs = '''        if metadata.get("format") != "uwuntu-image-v3":
            mkfs = ["mkfs.ext4", "-F", "-L", "casper-rw"]

            if re.fullmatch(
                r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{12}",
                dat_uuid,
            ):
                mkfs += ["-U", dat_uuid]

            mkfs.append(str(new_file))
            run(mkfs)

'''
ventoy = ventoy[:mkfs_start] + new_mkfs + ventoy[mkfs_end:]

phase2_start = ventoy.index('        # ----------------------------------------------------\n        # 2/3 Persistence hinein')
phase2_end = ventoy.index('        # ----------------------------------------------------\n        # 3/3 Prüfen + atomar ersetzen', phase2_start)
new_ventoy_phase2 = '''        # ----------------------------------------------------
        # 2/3 Persistence hinein
        # ----------------------------------------------------
        if metadata.get("format") == "uwuntu-image-v3":
            persistence_total = int(
                p2_meta.get("partclone_stream_bytes") or 0
            )
            if persistence_total <= 0:
                raise RuntimeError(
                    "Partclone-Persistenz-Streamgröße fehlt im Image."
                )

            loopdev = output(
                ["losetup", "--find", "--show", str(new_file)],
                timeout=10,
            )

            p = Progress(
                "Uwuntu-Inhalt blockweise in Ventoy übertragen",
                2,
                3,
                persistence_total,
                "SCHREIBEN",
            )

            restore_persistence_partclone_member(
                image,
                metadata,
                loopdev,
                p,
            )

            run(["e2fsck", "-fy", loopdev])
            run(["resize2fs", loopdev])

            if re.fullmatch(
                r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{12}",
                dat_uuid,
            ):
                run(["tune2fs", "-U", dat_uuid, loopdev])

            run(["e2label", loopdev, "casper-rw"])
            ext_check = run(["e2fsck", "-p", loopdev], check=False)
            if ext_check.returncode not in (0, 1):
                raise RuntimeError(
                    "Neue Uwuntu.dat konnte nicht sauber geprüft werden."
                )

            run(["sync"], check=False)
            run(["losetup", "-d", loopdev], check=False)
            loopdev = ""
        else:
            loop_mount(new_file, mount_dir)

            p = Progress(
                "Uwuntu-Inhalt in Ventoy übertragen",
                2,
                3,
                int(p2_meta["tar_stream_bytes"]),
                "SCHREIBEN",
            )

            restore_persistence_member(
                image,
                metadata,
                mount_dir,
                p,
            )

            run(["sync"], check=False)
            run(["umount", str(mount_dir)])

        ext_check = run(["e2fsck", "-p", str(new_file)], check=False)
        if ext_check.returncode not in (0, 1):
            raise RuntimeError(
                "Neue Uwuntu.dat konnte nicht sauber geprüft werden."
            )

'''
ventoy = ventoy[:phase2_start] + new_ventoy_phase2 + ventoy[phase2_end:]

finally_marker = '''    finally:
        try:
            if subprocess.run('''
finally_replacement = '''    finally:
        if loopdev:
            try:
                run(["losetup", "-d", loopdev], check=False)
            except Exception:
                pass

        try:
            if subprocess.run('''
if finally_marker not in ventoy:
    raise SystemExit('Ventoy finally Block fehlt')
ventoy = ventoy.replace(finally_marker, finally_replacement, 1)
text = text[:ventoy_start] + ventoy + text[ventoy_end:]


# Frontend: v3 anzeigen und die neue Persistenz-Streamgröße verwenden.
frontend_formats_old = '''        if data.get("format") not in {
            "uwuntu-image-v1",
            "uwuntu-image-v2",
        }:'''
frontend_formats_new = '''        if data.get("format") not in {
            "uwuntu-image-v1",
            "uwuntu-image-v2",
            "uwuntu-image-v3",
        }:'''
replace_once(frontend_formats_old, frontend_formats_new, 'Frontend Formate')
replace_once(
    '        f"Persistenzdaten: {fmt_bytes(p2.get(\'tar_stream_bytes\'))}\\n"',
    '        f"Persistenzdaten: {fmt_bytes(p2.get(\'partclone_stream_bytes\') or p2.get(\'tar_stream_bytes\'))}\\n"',
    'Frontend Persistenzdetails',
)


PATH.write_text(text, encoding="utf-8")
