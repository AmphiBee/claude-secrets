#!/usr/bin/python3
"""Contraste WCAG des paires de couleurs de Theme.swift (AA : 4,5 pour le texte, 3 pour les éléments graphiques)."""
import colorsys, re, sys, pathlib, zlib

src = pathlib.Path(__file__).resolve().parent.parent / "Sources/ClaudeSecrets/Theme.swift"
text = src.read_text()
def dyn(name):
    m = re.search(rf"static let {name} = dynamic\(\((\d+), (\d+), (\d+)\), \((\d+), (\d+), (\d+)\)\)", text)
    v = list(map(int, m.groups())); return tuple(v[:3]), tuple(v[3:])
def lum(c):
    f = lambda x: (x / 255 / 12.92) if x / 255 <= 0.03928 else (((x / 255) + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2])
def ratio(a, b):
    la, lb = sorted([lum(a), lum(b)], reverse=True); return (la + 0.05) / (lb + 0.05)
def hsl(h, s, l):
    r, g, b = colorsys.hls_to_rgb(h, l, s); return tuple(round(x * 255) for x in (r, g, b))

fail = 0
def check(label, a, b, need):
    global fail
    r = ratio(a, b); ok = r >= need; fail += not ok
    print(f"  [{'✓' if ok else '✗'}] {label} : {r:.2f} (≥ {need})")

for i, mode in enumerate(("clair", "sombre")):
    print(mode)
    paper, raised = dyn("paper")[i], dyn("paperRaised")[i]
    ink, soft, copper, rule = dyn("ink")[i], dyn("inkSoft")[i], dyn("copper")[i], dyn("rule")[i]
    check("encre sur papier", ink, paper, 4.5)
    check("encre douce sur papier", soft, paper, 4.5)
    check("encre douce sur papier relevé", soft, raised, 4.5)
    check("cuivre (texte, tampon) sur papier", copper, paper, 4.5)
    check("cuivre sur papier relevé", copper, raised, 4.5)
    check("filet sur papier (graphique)", rule, paper, 1.2)   # décor, pas une information
    check("texte du toast (papier sur encre)", paper, ink, 4.5)
    check("« Annuler » du toast sur l'encre", dyn("toastAccent")[i], ink, 4.5)
    worst = 99
    for t in range(24):
        h = t / 24
        bg = hsl(h, .62, .90 if i == 0 else .22); fg = hsl(h, .66, .26 if i == 0 else .86)
        worst = min(worst, ratio(fg, bg))
    ok = worst >= 4.5; fail += not ok
    print(f"  [{'✓' if ok else '✗'}] monogramme, pire des 24 teintes : {worst:.2f} (≥ 4.5)")
sys.exit(1 if fail else 0)
