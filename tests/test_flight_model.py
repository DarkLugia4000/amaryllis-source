"""Analytic plant checks and deterministic loops using maintained lift control."""
import json
import math
import unittest
import project
from tools.flight_model import Plant,pressure
from tests import test_persistence as persistence
from tests.test_runtime_bundling import table

class FlightModelTests(unittest.TestCase):
    def test_pressure_reference_points(self):
        for y,want in [(280,.41979029080811425),(300,.306447),(306,.237081),(310,.1805098250474892),(320,0)]:
            self.assertAlmostEqual(pressure(y),want,places=6)

    def test_drag_neutral_support_and_first_order_fill(self):
        p=Plant(constant_pressure=1,mass=100,raw_lift=100,speed=10)
        p.step(100,0,5.5)
        self.assertAlmostEqual(p.speed,10/math.e,places=9)
        self.assertAlmostEqual(p.altitude,250,places=9)
        p=Plant(constant_pressure=1,mass=100,raw_lift=100,gas_lag=2,gravity=0)
        p.step(200,0,2)
        self.assertAlmostEqual(p.raw_lift,200-100/math.e,places=9)

    def test_constant_imbalance_and_step_convergence(self):
        p=Plant(constant_pressure=1,mass=100,raw_lift=110,vertical_drag=0)
        p.step(110,0,2)
        self.assertAlmostEqual(p.vertical_speed,2.2,places=9)
        self.assertAlmostEqual(p.altitude,252.2,places=9)
        a=Plant();b=Plant()
        for _ in range(200):a.step(400000,0,.5)
        for _ in range(1000):b.step(400000,0,.1)
        self.assertAlmostEqual(a.altitude,b.altitude,places=6)
        self.assertAlmostEqual(a.raw_lift,b.raw_lift,places=6)

    def test_delay_capacity_and_source_provenance(self):
        p=Plant(constant_pressure=1,mass=100,raw_lift=100,gas_delay=2,maximum_raw_lift=120)
        p.step(999,0,1);self.assertEqual(p.raw_lift,100)
        p.step(999,0,20);self.assertLessEqual(p.raw_lift,120)
        profile=json.loads((project.ROOT/'tests/fixtures/plant-profile.json').read_text())
        self.assertEqual(profile['windows'][0]['pressureSource'],'SABLE AERO')
        self.assertEqual(profile['windows'][0]['air_pressure_sable']['samples'],profile['rows'])
        self.assertIn('estimated',profile['gasResponseFit']['status'])

    def test_startup_missing_bulk_data_uses_bounded_fallback(self):
        persistence.PersistenceTests.setUpClass()
        lua=persistence.PersistenceTests().runtime(False)
        lua.globals().CONFIG=table(lua,json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes()))
        lua.execute(r"""
local F=require('avionics.flight').new(CONFIG)
local run={phase='MAIN_LIFT',target=260,dynamics={sampleSeconds=.5}}
local io={nodes={},vessel={altitude=250,verticalSpeed=0,environment={gravity={y=-11}}}}
local ratio=F:systemsAcquisitionControl(io,run,.5,1,10,.5)
assert(ratio>=.8 and ratio<=1.2 and run.acquisitionPidActive==false)
""")

    def test_longitudinal_loop_uses_maintained_thrust(self):
        from tests import test_autopilot as ap
        reports=[]
        for selected,initial in [(4,0),(4,6),(0,1.9),(0,4),(0,-4)]:
            lua=persistence.PersistenceTests().runtime(False)
            lua.globals().CONFIG=table(lua,json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes()))
            lua.execute(ap.HARNESS)
            lua.execute(r"""
A,IO,C,T=fixture();C.targets.speed=4;C.modes.throttle='SEL'
function speedStep(at,value,target,p)
 C.targets.speed=target;sample(IO,at,0,0,90,value,0)
 T.airPressure=p
 local request,why=T:speedDriveRequest(IO,at,C);assert(request,why)
 return request/IO.config.thrust.direct_max_request,T.speedControl.state
end
""")
            p=Plant(constant_pressure=.55,speed=initial)
            for tick in range(600):
                drive,state=lua.globals().speedStep(10+tick*.2,p.speed,selected,.55)
                p.step(p.raw_lift,drive,.2)
                self.assertTrue(math.isfinite(p.speed) and abs(drive)<=1)
            reports.append({'selected':selected,'initial':initial,'final':p.speed,'state':state})
            if selected==0:self.assertLess(abs(p.speed),2)
        out=project.ROOT/'output/tests/flight-model';out.mkdir(parents=True,exist_ok=True)
        (out/'longitudinal.json').write_text(json.dumps(reports,indent=2)+'\n')

    def test_closed_loop_maintained_acquisition_and_hold(self):
        persistence.PersistenceTests.setUpClass()
        reports=[]
        for bundled in [False,True]:
            for start,target,lag in [(250,260,2),(280,290,2),(300,306,5),(306,300,2),(250,255,8)]:
                lua=persistence.PersistenceTests().runtime(bundled)
                lua.globals().CONFIG=table(lua,json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes()))
                # Load the maintained flight module in either source or generated form.
                if bundled:
                    source=project.builder_module().bundling.pack({**persistence.PersistenceTests.sources,
                        '/avionics/main.lua':b"return require('avionics.flight')"},persistence.PersistenceTests.loader,role='model',entry='/avionics/main.lua')
                    lua.globals().Flight=lua.execute('return assert(load(...))()',source.decode())
                else:lua.execute("Flight=require('avionics.flight')")
                lua.execute(r"""
F=Flight.new(CONFIG)
RUN={phase='MAIN_LIFT',target=260,responseLagSeconds=2,lastAckWaitSeconds=.5,
 dynamics={sampleSeconds=.5,verticalAcceleration=0}}
IO={nodes={},nodeFresh=function() return true end,vessel={environment={gravity={y=-11}}}}
local gas,strength=next(F.config.verified_gas_lift_strengths)
assert(gas and strength>0)
function controller(y,vs,raw,applied,p,mass,at,target,lag)
 RUN.target=target;RUN.responseLagSeconds=lag
 if math.abs(target-y)<1 and math.abs(vs)<.2 then RUN.phase='READY' end
 IO.vessel.altitude=y;IO.vessel.verticalSpeed=vs;IO.vessel.mass=mass
 IO.vessel.environment.airPressure=p
 for _,q in ipairs({'FL','FR','BL','BR'}) do
  IO.nodes[q]={balloon={gasMixValid=true,gasMix={[gas]=raw/(4*strength)}},
   providers={bulk={controlRole='bulk',gasTypeValid=true,gasType=gas,gasOutputValid=true,
    gasOutput=applied/(4*strength),targetAmount=applied/(4*strength)}}}
 end
 local ratio,why=F:systemsAcquisitionControl(IO,RUN,.5,raw*p/mass,at,.5)
 assert(ratio,why);return ratio,RUN.phase,F.verticalTarget
end
""")
                p=Plant(altitude=start,gas_lag=lag)
                commands=[];heights=[];applied=p.raw_lift
                for tick in range(600):
                    ratio,phase,_=lua.globals().controller(p.altitude,p.vertical_speed,p.raw_lift,applied,p.air_pressure(),p.mass,tick*.5,target,lag)
                    self.assertTrue(math.isfinite(ratio) and 0<=ratio<=2)
                    applied=min(p.maximum_raw_lift,ratio*p.mass/max(p.air_pressure(),1e-9))
                    commands.append(applied);p.step(applied,0,.5);heights.append(p.altitude)
                reports.append({'bundled':bundled,'start':start,'target':target,'gasLag':lag,'finalAltitude':p.altitude,
                    'finalError':target-p.altitude,'overshoot':max(heights)-target,'finalPhase':phase,
                    'maxCommand':max(commands),'status':'synthetic aggregate control characterization'})
                self.assertLess(abs(p.vertical_speed),20)
        out=project.ROOT/'output/tests/flight-model';out.mkdir(parents=True,exist_ok=True)
        (out/'scenarios.json').write_text(json.dumps(reports,indent=2)+'\n')
        for i in range(5):
            self.assertAlmostEqual(reports[i]['finalAltitude'],reports[i+5]['finalAltitude'],places=9)

if __name__=='__main__':unittest.main()
