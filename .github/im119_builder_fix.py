from pathlib import Path
p = Path('.github/im119_builder.py')
s = p.read_text(encoding='utf-8')
old = '''assert text.count('APP_VERSION="1.18"') == 2
assert text.count('VERSION = "1.18"') == 1
text = text.replace('APP_VERSION="1.18"', 'APP_VERSION="1.19"')
text = text.replace('VERSION = "1.18"', 'VERSION = "1.19"')'''
new = '''assert text.count('APP_VERSION="1.18"') == 1
assert text.count('VERSION = "1.18"') == 2
text = text.replace('APP_VERSION="1.18"', 'APP_VERSION="1.19"')
text = text.replace('VERSION = "1.18"', 'VERSION = "1.19"')'''
if old not in s:
    raise SystemExit('Versionsblock nicht gefunden')
s = s.replace(old, new, 1)
old2 = '''assert text.count('APP_VERSION="1.19"') == 2
assert text.count('VERSION = "1.19"') == 1'''
new2 = '''assert text.count('APP_VERSION="1.19"') == 1
assert text.count('VERSION = "1.19"') == 2'''
if old2 not in s:
    raise SystemExit('Endprüfung nicht gefunden')
s = s.replace(old2, new2, 1)
p.write_text(s, encoding='utf-8')
print('Builder fix OK')
