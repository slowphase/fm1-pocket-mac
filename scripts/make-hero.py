import random, sys, subprocess
from PIL import Image
title, out = sys.argv[1], sys.argv[2]
W,H=2000,670
from PIL import ImageFont
import os
fs=150
while ImageFont.truetype(os.path.expanduser('~/.fonts/SpaceGrotesk-700.ttf'),fs).getlength(title)>1000: fs-=2
random.seed(7)
stars=[]
for _ in range(260):
    x=random.uniform(0,W); y=random.uniform(0,H)
    if 820<x<1900 and 170<y<500: continue   # keep the text clear
    s=random.choice([4,4,5,6,8]); o=random.uniform(0.08,0.45)
    c=random.choice(['#8a4fe0','#b98aff','#5a2e9c','#ece4d3'])
    stars.append(f'<rect x="{x:.0f}" y="{y:.0f}" width="{s}" height="{s}" rx="1" fill="{c}" opacity="{o:.2f}"/>')
svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">
<defs>
 <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1c1c21"/><stop offset="1" stop-color="#0b0b0d"/></linearGradient>
 <radialGradient id="halo" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#7a44d0" stop-opacity="0.35"/><stop offset="1" stop-color="#7a44d0" stop-opacity="0"/></radialGradient>
</defs>
<rect width="{W}" height="{H}" fill="url(#bg)"/>
{''.join(stars)}
<circle cx="470" cy="335" r="420" fill="url(#halo)"/>
<text x="900" y="330" font-family="Space Grotesk" font-weight="700" font-size="{fs}" fill="#f3efe6" letter-spacing="-3">{title}</text>
<text x="904" y="425" font-family="Space Grotesk" font-weight="500" font-size="54" fill="#b98aff">A universe of firmware. One little player.</text>
</svg>'''
open('hero.svg','w').write(svg)
subprocess.run(['rsvg-convert','-w',str(W),'hero.svg','-o','hero-bg.png'],check=True)
bg=Image.open('hero-bg.png').convert('RGBA'); knob=Image.open('bare.png').convert('RGBA')
bg.alpha_composite(knob,(470-410,335-410)); bg.convert('RGB').save(out,optimize=True)
