# Draws the Pacely app icons with plain Python (no extra libraries).
import zlib, struct, math, os, sys
def png(path, size):
    bg=(47,125,120); fg=(251,247,241); sun=(246,196,83)
    cx=cy=size/2; R=size*0.30; w=size*0.075
    rows=[]
    for y in range(size):
        row=bytearray([0])
        for x in range(size):
            px,py=x+0.5-cx,y+0.5-cy
            d=math.hypot(px,py)
            col=bg
            # progress ring: 75% arc starting at top, clockwise
            ang=(math.degrees(math.atan2(px,-py))+360)%360
            ring=1-min(1,max(0,abs(d-R)-w/2+0.5))
            track=ring*0.28
            arc=ring if ang<=270 else 0
            a=max(arc,track)
            # rounded arc ends
            for ea in (0,270):
                ex=cx+R*math.sin(math.radians(ea))-x-0.5; ey=cy-R*math.cos(math.radians(ea))-y-0.5
                if ea==0 or True:
                    dd=math.hypot(ex,ey); a=max(a,1-min(1,max(0,dd-w/2+0.5)))
            col=tuple(round(col[i]*(1-a)+fg[i]*a) for i in range(3))
            # centre dot
            dd=1-min(1,max(0,d-size*0.085+0.5))
            col=tuple(round(col[i]*(1-dd)+sun[i]*dd) for i in range(3))
            row+=bytes(col)
        rows.append(bytes(row))
    raw=b''.join(rows)
    def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
    data=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',size,size,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw,9))+chunk(b'IEND',b'')
    open(path,'wb').write(data)
out=sys.argv[1] if len(sys.argv)>1 else 'static'
for s in (180,192,512): png(os.path.join(out,f'icon-{s}.png'),s)
