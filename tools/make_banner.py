#!/usr/bin/env python3
"""Build the B/W banner (1280x720), platform banner (521x165) and icon (36x36) PNGs
from the Tengai key art. Run from the repo root: python3 tools/make_banner.py [art]
Then convert with tools/png2pocket.py."""
from PIL import Image, ImageDraw, ImageOps, ImageFilter, ImageFont
import numpy as np
from collections import deque
src=Image.open(__import__('sys').argv[1] if len(__import__('sys').argv)>1 else 'docs/banner_raw.webp').convert('RGB')
a=np.asarray(src).astype(int); h,w,_=a.shape
bg=(a.min(axis=2)>=240); mask=np.zeros((h,w),bool); q=deque()
for x in range(w):
    for y in (0,h-1):
        if bg[y,x]: mask[y,x]=True; q.append((y,x))
for y in range(h):
    for x in (0,w-1):
        if bg[y,x] and not mask[y,x]: mask[y,x]=True; q.append((y,x))
while q:
    y,x=q.popleft()
    for dy,dx in ((1,0),(-1,0),(0,1),(0,-1)):
        ny,nx=y+dy,x+dx
        if 0<=ny<h and 0<=nx<w and bg[ny,nx] and not mask[ny,nx]:
            mask[ny,nx]=True; q.append((ny,nx))
mi=Image.fromarray((mask*255).astype('uint8')).filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(1.0))
alpha=ImageOps.invert(mi)
g=ImageOps.autocontrast(src.convert('L'),cutoff=1)

fig=Image.merge('LA',(g,alpha))
# face to waist crop (bow/sash is the waist ~y=305)
crop=fig.crop((105,0,475,318))

B='/usr/share/fonts/liberation/LiberationSans-Bold.ttf'; R='/usr/share/fonts/liberation/LiberationSans-Regular.ttf'
J='/usr/share/fonts/droid/DroidSansJapanese.ttf'
def compose(W,H,title_sz,sub_sz,jp_sz,pad):
    c=Image.new('L',(W,H),0)
    # subtle vertical gradient + scanlines
    grad=np.tile(np.linspace(28,0,W)[None,:],(H,1))
    grad[::3,:]*=0.55
    c=Image.fromarray(grad.astype('uint8'))
    fh=H; fw=int(crop.width*fh/crop.height)
    f=crop.resize((fw,fh),Image.LANCZOS)
    x0=W-fw
    al=np.asarray(f.getchannel('A')).astype(float)
    ramp=np.clip(np.linspace(0,1.6,fw),0,1)[None,:]
    al=(al*ramp).astype('uint8')
    c.paste(f.getchannel('L'),(x0,0),Image.fromarray(al))
    d=ImageDraw.Draw(c)
    ft=ImageFont.truetype(B,title_sz); fs=ImageFont.truetype(R,sub_sz); fj=ImageFont.truetype(J,jp_sz)
    y=int(H*0.14)
    d.text((pad,y),'天外',font=fj,fill=150)
    y+=int(jp_sz*1.05)
    d.text((pad,y),'TENGAI',font=ft,fill=255)
    y+=int(title_sz*0.95)
    d.text((pad,y),'POKETTO',font=ft,fill=200)
    y+=int(title_sz*1.15)
    d.line((pad,y,pad+int(W*0.36),y),fill=120,width=max(1,H//180))
    y+=int(sub_sz*0.6)
    d.text((pad,y),'Psikyo 68k Arcade System',font=fs,fill=210)
    y+=int(sub_sz*1.3)
    d.text((pad,y),'openFPGA core for Analogue Pocket',font=fs,fill=140)
    return c
compose(1280,720,118,34,60,64).save('docs/banner_bw.png')
compose(521,165,32,11,15,16).save('docs/platform_521x165.png')
# icon: face
face=fig.crop((200,0,360,160)).resize((36,36),Image.LANCZOS)
ic=Image.new('L',(36,36),0); ic.paste(face.getchannel('L'),(0,0),face.getchannel('A')); ic=ImageOps.autocontrast(ic,cutoff=2); ic.save('docs/icon36.png')

