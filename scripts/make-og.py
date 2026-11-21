import random, subprocess, os
from PIL import Image, ImageFont
W,H=1200,630
random.seed(11)
stars=[]
for _ in range(150):
    x=random.uniform(0,W); y=random.uniform(0,H)
    if 560<x<1170 and 200<y<450: continue
    s=random.choice([3,3,4,5,6]); o=random.uniform(0.08,0.45)
    c=random.choice(['#8a4fe0','#b98aff','#5a2e9c','#ece4d3'])
    stars.append(f'<rect x="{x:.0f}" y="{y:.0f}" width="{s}" height="{s}" rx="1" fill="{c}" opacity="{o:.2f}"/>')
f=os.path.expanduser('~/.fonts/SpaceGrotesk-700.ttf'); fs=96
while ImageFont.truetype(f,fs).getlength("FM-1 Pocket Player")>580: fs-=2
svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">
<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1c1c21"/><stop offset="1" stop-color="#0b0b0d"/></linearGradient>
<radialGradient id="halo" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#7a44d0" stop-opacity="0.35"/><stop offset="1" stop-color="#7a44d0" stop-opacity="0"/></radialGradient></defs>
<rect width="{W}" height="{H}" fill="url(#bg)"/>{''.join(stars)}
<circle cx="300" cy="315" r="330" fill="url(#halo)"/>
<text x="580" y="300" font-family="Space Grotesk" font-weight="700" font-size="{fs}" fill="#f3efe6" letter-spacing="-2">FM-1 Pocket Player</text>
<text x="582" y="360" font-family="Space Grotesk" font-weight="500" font-size="29" fill="#b98aff">A universe of firmware. One little player.</text>
<text x="582" y="410" font-family="Space Grotesk" font-weight="500" font-size="24" fill="#8f8f98">FM-1 community firmware in your browser</text>
</svg>'''
open('og.svg','w').write(svg)
subprocess.run(['rsvg-convert','-w',str(W),'og.svg','-o','og-bg.png'],check=True)
subprocess.run(['rsvg-convert','-w','560','bare.svg','-o','bare560.png'],check=True)
bg=Image.open('og-bg.png').convert('RGBA'); k=Image.open('bare560.png').convert('RGBA')
bg.alpha_composite(k,(300-280,315-280)); bg.convert('RGB').save('og.png',optimize=True)
