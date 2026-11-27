"""Capture production navigator Lua frames as palette-index JSON for visual review.

Run with the project Python environment (Lupa). Pass --png using a Python
installation with Pillow to turn existing captures into nearest-neighbour PNGs.
"""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output/tests/navigator-graphics'


def capture():
    """Execute the packaged renderer against representative cached telemetry."""
    sys.path.insert(0, str(ROOT))
    from tests.test_displays import NavigatorGraphicsTests
    NavigatorGraphicsTests.setUpClass()
    lua = NavigatorGraphicsTests().runtime()
    lua.execute("""
u,s,m=navFixture(342,216,'FLIGHT')
s.nodes={};s.fleetBoot={ready=true}
for _,q in ipairs({'FL','FR','BL','BR'}) do
 s.nodes[q]={online=true,statusFresh=true,ready=true,thrustControlState='RDY',liftControlState='CMD',
  balloon={hasBalloon=true,hasBalloonValid=true,gasMixValid=true,gasMix={steam=38285},gasMixAmount=38285,lift=53988,liftValid=true},
  providers={steam={gasOutput=.12,gasOutputValid=true,targetAmount=38285,targetValid=true}}}
end
s.thrust={requested={['primary-left']=.42,['primary-right']=.42},headingControl={state='HOLDING'},units={
 ['primary-left']={online=true,statusFresh=true,readings={{speedRaw=128,validity={speedRaw=true}}}},['primary-right']={online=true,statusFresh=true,readings={{speedRaw=128,validity={speedRaw=true}}}}}}
s.trimControl={manualTrimAvailable=true,manualForeAftBias=.2,manualTargetForeAftHeightDifferenceBlocks=.2,
 foreAftHeightDifferenceBlocks=.18,coarseSteamTrimRoll=.01,coarseSteamTrimPitch=.02}
""")
    cases = {
        'flight': "s.page='FLIGHT'",
        'engine-health': "previewUnits=s.thrust.units;s.thrust.units={['primary-left']={discovered=false},['primary-right']={discovered=true,online=false,statusFresh=false}}",
        'nav-main': "s.thrust.units=previewUnits;s.page='NAV';u.navSection='MAIN'",
        'nav-single': "u.navSection='ADVANCED';u.navMode='single'",
        'nav-route': "u.navMode='route'",
        'ap': "s.autopilot.active=true;s.autopilot.state='CRUISE';s.autopilot.route={kind='waypoints',index=1,entries=s.autopilot.playlist};s.autopilot.distance=1200;s.autopilot.requestedSpeed=3;s.autopilot.requestedHeading=90;s.autopilot.crossTrack=1.2",
        'ap-single': "s.autopilot.route={kind='single',index=1,entries={s.autopilot.playlist[1]}}",
        'ap-final': "s.autopilot.route={kind='waypoints',index=2,entries=s.autopilot.playlist}",
        'ship-lift': "s.autopilot.active=false;s.page='SHIP';u.shipView='LIFT'",
        'ship-prop': "u.shipView='PROP'",
        'ship-trim': "u.shipView='TRIM'",
        'settings': "s.page='SETTINGS';u.settingsView='GENERAL'",
        'systems': "u.systemsMenu=true",
        'kill-confirm': "u.systemsMenu=nil;u.killReview=NOW",
        'disassembled': "u.killReview=nil;s.page='FLIGHT';s.assembly={state='DISASSEMBLED'}",
        'keyboard': "u.killReview=nil;s.assembly=nil;s.page='NAV';u:openEditor('x','X',704,{type='ap_edit',key='x'})",
        'keyboard-name': "u:openEditor('name','NAME','Harbour',{type='ap_edit',key='name'})",
    }
    OUT.mkdir(parents=True, exist_ok=True)
    for name, setup in cases.items():
        lua.execute(setup + ";assert(u:draw(s))")
        rows = [[ord(c) for c in row] for _, row in lua.globals().u.previous.items()]
        (OUT / (name + '.json')).write_text(json.dumps(rows))
    print('Captured', len(cases), 'production frames in', OUT)


def png():
    """Map the CC palette to enlarged PNGs and a labelled contact sheet."""
    from PIL import Image, ImageDraw
    palette = ['f0f0f0','f2b233','e57fd8','99b2f2','dede6c','7fcc19','f2b2cc','4c4c4c',
               '999999','4c99b2','b266e5','3366cc','7f664c','57a64e','cc4c4c','000000']
    previews = []
    for path in OUT.glob('*.json'):
        rows = json.loads(path.read_text())
        im = Image.new('RGB', (len(rows[0]), len(rows)))
        im.putdata([tuple(bytes.fromhex(palette[v])) for row in rows for v in row])
        im.resize((1026,648), Image.Resampling.NEAREST).save(path.with_suffix('.png'))
        previews.append((path.stem, im))
    contact = Image.new('RGB', (1062, (len(previews)+1)//2*354), '#202020')
    draw = ImageDraw.Draw(contact)
    for i,(name,im) in enumerate(previews):
        x=i%2*531; y=i//2*354
        draw.text((x+9,y+5),name,fill='white')
        contact.paste(im.resize((513,324),Image.Resampling.NEAREST),(x+9,y+24))
    contact.save(OUT/'contact.png')
    selected=['flight','nav-main','nav-single','nav-route','ap','ship-lift','ship-prop','ship-trim']
    overview=Image.new('RGB',(1062,354*4),'#202020')
    draw=ImageDraw.Draw(overview)
    for i,name in enumerate(selected):
        x=i%2*531;y=i//2*354
        draw.text((x+9,y+5),name,fill='white')
        frame=Image.open(OUT/(name+'.png'))
        overview.paste(frame.resize((513,324),Image.Resampling.NEAREST),(x+9,y+24))
    overview.save(OUT/'overview.png')
    print('Rendered previews in', OUT)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--png',action='store_true')
    args=parser.parse_args()
    png() if args.png else capture()
