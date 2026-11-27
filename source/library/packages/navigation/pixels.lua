-- Section: Pixel drawing | Bounded 16-colour navigator framebuffer operations.
local P={width=342,height=216}
P.colors={white=0,cyan=9,yellow=4,purple=10,green=5,red=14,gray=7,black=15}
P.font={
    A="01110/10001/10001/11111/10001/10001/10001",
    B="11110/10001/10001/11110/10001/10001/11110",
    C="01111/10000/10000/10000/10000/10000/01111",
    D="11110/10001/10001/10001/10001/10001/11110",
    E="11111/10000/10000/11110/10000/10000/11111",
    F="11111/10000/10000/11110/10000/10000/10000",
    G="01111/10000/10000/10111/10001/10001/01111",
    H="10001/10001/10001/11111/10001/10001/10001",
    I="01110/00100/00100/00100/00100/00100/01110",
    J="00111/00010/00010/00010/10010/10010/01100",
    K="10001/10010/10100/11000/10100/10010/10001",
    L="10000/10000/10000/10000/10000/10000/11111",
    M="10001/11011/10101/10101/10001/10001/10001",
    N="10001/11001/11001/10101/10011/10011/10001",
    O="01110/10001/10001/10001/10001/10001/01110",
    P="11110/10001/10001/11110/10000/10000/10000",
    Q="01110/10001/10001/10001/10101/10010/01101",
    R="11110/10001/10001/11110/10100/10010/10001",
    S="01111/10000/10000/01110/00001/00001/11110",
    T="11111/00100/00100/00100/00100/00100/00100",
    U="10001/10001/10001/10001/10001/10001/01110",
    V="10001/10001/10001/10001/10001/01010/00100",
    W="10001/10001/10001/10101/10101/10101/01010",
    X="10001/10001/01010/00100/01010/10001/10001",
    Y="10001/10001/01010/00100/00100/00100/00100",
    Z="11111/00001/00010/00100/01000/10000/11111",
    ["0"]="01110/10001/10011/10101/11001/10001/01110",
    ["1"]="00100/01100/00100/00100/00100/00100/01110",
    ["2"]="01110/10001/00001/00010/00100/01000/11111",
    ["3"]="11110/00001/00001/01110/00001/00001/11110",
    ["4"]="00010/00110/01010/10010/11111/00010/00010",
    ["5"]="11111/10000/10000/11110/00001/00001/11110",
    ["6"]="01110/10000/10000/11110/10001/10001/01110",
    ["7"]="11111/00001/00010/00100/01000/01000/01000",
    ["8"]="01110/10001/10001/01110/10001/10001/01110",
    ["9"]="01110/10001/10001/01111/00001/00001/01110",
    [" "]="00000/00000/00000/00000/00000/00000/00000",
    ["."]="00000/00000/00000/00000/00000/00110/00110",
    ["-"]="00000/00000/00000/11111/00000/00000/00000",
    ["+"]="00000/00100/00100/11111/00100/00100/00000",
    ["/"]="00001/00010/00010/00100/01000/01000/10000",
    ["?"]="01110/10001/00001/00010/00100/00000/00100",
    [":"]="00000/00110/00110/00000/00110/00110/00000",
    ["("]="00010/00100/01000/01000/01000/00100/00010",
    [")"]="01000/00100/00010/00010/00010/00100/01000",
}
P.font['|']='00100/00100/00100/00100/00100/00100/00100'
P.font[';']='00000/00110/00110/00000/00110/00100/01000'
P.font['%']='11001/11010/00100/01000/10110/00110/00000'
for key,rows in pairs(P.font) do P.font[key]=rows:gsub('/','') end
-- Summary: Allocate a black logical frame with a fresh list of touch regions.
-- Each byte is a mode-one palette index. Coordinates are zero-based pixels.
function P.new()
 local f={rows={},regions={}}
 for y=1,P.height do f.rows[y]={};for x=1,P.width do f.rows[y][x]=15 end end
 return setmetatable(f,{__index=P})
end
-- Summary: Set a clipped logical pixel to the named palette colour.
function P:pixel(x,y,color)
 x=math.floor(x);y=math.floor(y)
 if x>=0 and y>=0 and x<P.width and y<P.height then self.rows[y+1][x+1]=P.colors[color] or color or 0 end
end
-- Summary: Fill a clipped rectangle, or paint its one-pixel outline.
function P:rect(x,y,w,h,color,outline)
 for yy=math.max(0,y),math.min(P.height-1,y+h-1) do
  for xx=math.max(0,x),math.min(P.width-1,x+w-1) do
   if not outline or yy==y or yy==y+h-1 or xx==x or xx==x+w-1 then self:pixel(xx,yy,color) end
  end
 end
end
-- Summary: Draw a clipped integer line between logical pixel coordinates.
function P:line(x,y,tx,ty,color)
 local steps=math.max(math.abs(tx-x),math.abs(ty-y))
 for i=0,steps do
  local t=steps==0 and 0 or i/steps
  self:pixel(x+(tx-x)*t+.5,y+(ty-y)*t+.5,color or 'gray')
 end
end
-- Summary: Paint the bitmap font with bounded text width and integer scale.
-- Values longer than the available span end in dots; source data stays intact.
function P:text(x,y,value,color,scale,width)
 local text=string.upper(tostring(value or '--'));scale=scale or 1
 local available=math.floor((width or (P.width-x))/(6*scale))
 if #text>available then text=available>=3 and text:sub(1,available-3)..'...' or text:sub(1,available) end
 for i=1,#text do
  local glyph=P.font[text:sub(i,i)] or P.font['?']
  for yy=0,6 do for xx=0,4 do
   if glyph:sub(yy*5+xx+1,yy*5+xx+1)=='1' then self:rect(x+(i-1)*6*scale+xx*scale,y+yy*scale,scale,scale,color) end
  end end
 end
end
-- Summary: Centre a bounded text label within a logical horizontal span.
function P:center(x,y,width,text,color,scale)
 scale=scale or 1
 self:text(x+math.max(0,math.floor((width-math.min(#tostring(text)*6*scale-scale,width))/2)),y,text,color,scale,width)
end
-- Summary: Draw a capsule-free oval outline and optional centre partition.
-- Reads oval bounds and partition axis, plotting its outline and optional chamber divider.
function P:oval(x,y,w,h,split)
 for i=0,720 do
  local a=i*math.pi/360
  self:pixel(x+w/2+math.cos(a)*w/2,y+h/2+math.sin(a)*h/2,'gray')
 end
 if split=='horizontal' then self:line(x,y+h/2,x+w,y+h/2,'gray')
 elseif split then self:line(x+w/2,y,x+w/2,y+h,'gray') end
end
-- Summary: Outline a compact vertical envelope with shallow curved ends and a chamber split.
-- Reads diagram bounds, keeps a full-width data area and plots two seven-pixel elliptical end caps.
function P:envelope(x,y,w,h)
 local cap=7
 self:line(x,y+cap,x,y+h-cap,'gray')
 self:line(x+w,y+cap,x+w,y+h-cap,'gray')
 for i=0,180 do
  local a=i*math.pi/180
  self:pixel(x+w/2+math.cos(a)*w/2,y+cap-math.sin(a)*cap,'gray')
  self:pixel(x+w/2+math.cos(a)*w/2,y+h-cap+math.sin(a)*cap,'gray')
 end
 self:line(x,y+h/2,x+w,y+h/2,'gray')
end
-- Summary: Draw a selectable action and retain its exact logical hit rectangle.
function P:button(x,y,w,h,label,action,enabled,selected,danger)
 local color=danger and 'red' or selected and 'cyan' or 'gray'
 self:rect(x,y,w,h,color,not selected and not danger)
 self:center(x,y+math.floor((h-7)/2),w,label,enabled==false and 'gray' or selected and 'black' or 'white')
 if action then self.regions[#self.regions+1]={x=x,y=y,w=w,h=h,action=action,enabled=enabled~=false} end
end
-- Summary: Paint the vessel's six-petal purple emblem on the disassembled page.
-- Reads the top-left origin and plots a 48-pixel flower with palette highlights and a yellow centre.
function P:flower(x,y)
 for petal=0,5 do
  local angle=-math.pi/2+petal*math.pi/3
  local cosine,sine=math.cos(angle),math.sin(angle)
  for py=2,45 do
   for px=2,45 do
    local dx,dy=px-23.5,py-23.5
    local radial=dx*cosine+dy*sine
    local across=-dx*sine+dy*cosine
    local fraction=math.max(0,math.min(1,(radial+1)/23))
    local halfWidth=6.8*math.sin(math.pi*fraction)^.8
    if radial>=0 and radial<=21 and math.abs(across)<=halfWidth then
     local color=10
     if halfWidth-math.abs(across)>=1.1 then
      if math.abs(across)<1.15 and radial<17 then color=6
      elseif across<0 then color=2 end
     end
     self:pixel(x+px,y+py,color)
    end
   end
  end
 end
 self:rect(x+21,y+21,6,6,6)
 self:rect(x+22,y+22,4,4,0)
 self:rect(x+23,y+23,2,2,4)
end
-- Summary: Paint chevron phase outlines and fill the current autopilot phase.
-- Reads the current phase, paints five chevrons and highlights its matching index.
function P:phases(state)
 local selected=({ACQ=1,CAPTURE=2,CRUISE=3,DECEL=4,ARRIVED=5,ARRIVAL=5})[state]
 for i,label in ipairs({'ACQUIRE','CAPTURE','CRUISE','DECEL','ARRIVAL'}) do
  local x=4+(i-1)*67;local active=i==selected
  if active then
   for yy=0,17 do
    local inset=math.abs(yy-8);self:line(x+8-inset,24+yy,x+65-inset,24+yy,'purple')
   end
  end
  local points={{x,24},{x+59,24},{x+65,33},{x+59,41},{x,41},{x+6,33},{x,24}}
  for k=1,#points-1 do self:line(points[k][1],points[k][2],points[k+1][1],points[k+1][2],active and 'purple' or 'gray') end
  self:center(x,29,66,label,active and 'black' or 'white')
 end
end
-- Summary: Scale a logical frame to monitor pixels and emit changed byte rows.
-- Render geometry also drives zero-based monitor_touch mapping after resize.
function P:flush(renderer)
 local m=renderer.monitor;local w,h=m.getSize(1)
 if type(w)~='number' or type(h)~='number' or w<342 or h<216 then return false,'NAVIGATOR NEEDS 342 X 216 PIXELS' end
 local scale=math.min(w/342,h/216);local dw,dh=math.floor(342*scale),math.floor(216*scale)
 local ox,oy=math.floor((w-dw)/2),math.floor((h-dh)/2)
 local rows={}
 for y=0,dh-1 do
  local source=self.rows[math.min(216,math.floor(y/scale)+1)];local row={}
  for x=0,dw-1 do row[#row+1]=string.char(source[math.min(342,math.floor(x/scale)+1)]) end
  rows[y+1]=table.concat(row)
 end
 local changed=renderer.pixelW~=w or renderer.pixelH~=h
 if not renderer.graphicsActive or changed then
  m.setGraphicsMode(1)
  if m.setFrozen then m.setFrozen(false) end
  if m.setPaletteColor then m.setPaletteColor(32768,0,0,0) end
  m.drawPixels(0,0,32768,w,h)
 end
 for y,row in ipairs(rows) do
  if changed or not renderer.previous or renderer.previous[y]~=row then m.drawPixels(ox,oy+y-1,{row}) end
 end
 renderer.previous=rows;renderer.pixelW=w;renderer.pixelH=h
 renderer.geometry={scale=scale,x=ox,y=oy,w=w,h=h};renderer.regions=self.regions;renderer.graphicsActive=true
 return true
end
return P
