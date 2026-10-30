#!/usr/bin/env python3
"""Kaynaktaki yerelleştirilen metinlerin İngilizce tabloda karşılığı var mı denetler.
Kullanım: python3 scripts/check-strings.py   (eksik varsa 1 ile çıkar)"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
table = dict(re.findall(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";', (root / "Resources/en.lproj/Localizable.strings").read_text(), re.M))

def norm_swift(lit: str) -> str:
    """\\(...) enterpolasyonlarını (iç içe parantezli olsa da) tek bir yer tutucuya çevirir."""
    out, i = "", 0
    while i < len(lit):
        if lit.startswith("\\(", i):
            depth, i = 1, i + 2
            while i < len(lit) and depth:
                depth += (lit[i] == "(") - (lit[i] == ")")
                i += 1
            out += "§"
        else:
            out += lit[i]; i += 1
    return out

def norm_key(key: str) -> str:
    return re.sub(r"%(?:lld|@)", "§", key)

import plistlib
dict_keys = plistlib.load(open(root / "Resources/en.lproj/Localizable.stringsdict", "rb"))
keys = {norm_key(k): k for k in list(table) + list(dict_keys)}
SKIP = {"Tazele", "GitHub", "macOS", "App Store", "npm", "Cask", "Homebrew (cask)"}
constructs = re.compile(r'(?:Text|Button|Label|Toggle|Picker|String\(localized:|\.help)\(?\s*"((?:[^"\\]|\\.)*)"')
missing, used = [], set()
for f in sorted((root / "Sources").rglob("*.swift")):
    for lit in constructs.findall(f.read_text()):
        n = norm_swift(lit)
        if lit in SKIP or not re.search(r"[A-Za-zçğıöşüÇĞİÖŞÜ]{2}", n.replace("§", "")):
            continue
        if n in keys: used.add(n)
        else: missing.append((f.name, lit))
unused = [k for n, k in keys.items() if n not in used]
for f, lit in missing: print(f"EKSİK  {f}: {lit}")
for k in unused: print(f"KULLANILMAYAN anahtar: {k}")
print(f"{len(keys)} anahtar, {len(missing)} eksik, {len(unused)} kullanılmayan")
sys.exit(1 if missing else 0)
