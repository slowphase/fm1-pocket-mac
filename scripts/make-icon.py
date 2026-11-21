#!/usr/bin/env python3
"""FM-1 Pocket's icon: a cream knob with a purple LED-pixel ring on a near-black tile.
   make-icon.py OUT.svg [--small] [--full-bleed]
   --small: fewer, chunkier pixels for 16 and 32 px.  --full-bleed: square, no margin or shadow (web touch icon)."""
import math, sys
out = sys.argv[1]; small = "--small" in sys.argv; full = "--full-bleed" in sys.argv
C, R = 512, 292
N, lit_s, dim_s = (13, 52, 46) if small else (27, 30, 26)
start, end, ptr = -135, 135, 35
dots = []
for i in range(N):
    a = start + (end - start) * i / (N - 1)
    lit = a <= ptr + 0.01
    if lit:
        t = (a - start) / (ptr - start)
        c0, c1 = (0x5a, 0x2e, 0x9c), (0xd2, 0xa0, 0xff)
        col = "#%02x%02x%02x" % tuple(int(c0[k] + (c1[k] - c0[k]) * t ** 1.4) for k in range(3))
    else:
        col = "#34343b" if small else "#2b2b31"
    r = math.radians(a); x = C + R * math.sin(r); y = C - R * math.cos(r)
    s = lit_s if lit else dim_s
    glow = ' filter="url(#glow)"' if lit and not small and (a - start) / (ptr - start) > 0.6 else ""
    dots.append(f'<rect x="{x-s/2:.1f}" y="{y-s/2:.1f}" width="{s}" height="{s}" rx="{s/6:.1f}" fill="{col}" '
                f'transform="rotate({a:.2f} {x:.1f} {y:.1f})"{glow}/>')
pr = math.radians(ptr); dx = C + 138 * math.sin(pr); dy = C - 138 * math.cos(pr)
dot_r = 34 if small else 25
F = 'color-interpolation-filters="sRGB"'
if full:
    tile = '<rect width="1024" height="1024" fill="url(#bg)"/>'
    content = f'<g transform="translate(512 512) scale(1.15) translate(-512 -512)">'
else:
    tile = ('<g filter="url(#shadow)"><rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>'
            '<rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="#ffffff" '
            'stroke-opacity="0.07" stroke-width="3"/></g>')
    content = '<g>'
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
 <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#26262b"/><stop offset="1" stop-color="#0d0d10"/></linearGradient>
 <linearGradient id="knob" x1="0.2" y1="0" x2="0.8" y2="1"><stop offset="0" stop-color="#e9e1cf"/><stop offset="1" stop-color="#b9ae97"/></linearGradient>
 <radialGradient id="face" cx="0.4" cy="0.32" r="0.8"><stop offset="0" stop-color="#fffaf0"/><stop offset="1" stop-color="#ece4d3"/></radialGradient>
 <linearGradient id="collar" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#050506"/><stop offset="1" stop-color="#1c1c20"/></linearGradient>
 <filter {F} id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12"/><feComponentTransfer><feFuncA type="linear" slope="0.45"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>
 <filter {F} id="kshadow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur in="SourceAlpha" stdDeviation="16"/><feOffset dy="18"/><feComponentTransfer><feFuncA type="linear" slope="0.6"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>
 <filter {F} id="glow" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="9" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
</defs>
{tile}
{content}
{"".join(dots)}
<circle cx="{C}" cy="{C}" r="232" fill="url(#collar)"/>
<g filter="url(#kshadow)"><circle cx="{C}" cy="{C}" r="196" fill="url(#knob)"/></g>
<circle cx="{C}" cy="{C}" r="172" fill="url(#face)"/>
<circle cx="{C}" cy="{C}" r="172" fill="none" stroke="#ffffff" stroke-opacity="0.6" stroke-width="2"/>
<circle cx="{dx:.1f}" cy="{dy:.1f}" r="{dot_r}" fill="#8a4fe0"/>
<circle cx="{dx-4:.1f}" cy="{dy-5:.1f}" r="{dot_r*0.36:.1f}" fill="#ffffff" fill-opacity="0.18"/>
</g>
</svg>'''
open(out, "w").write(svg)
