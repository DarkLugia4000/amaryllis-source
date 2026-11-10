"""Recording metrics and bounded recorded-input replay through maintained lift control."""
import csv
import json
import math
from pathlib import Path
import tempfile
import unittest
import project
from tools.recordings import analyze,write_report
from tests import test_persistence as persistence
from tests.test_runtime_bundling import table

class RecordingTests(unittest.TestCase):
    def test_metrics_gaps_sources_stalls_and_missing_values(self):
        with tempfile.TemporaryDirectory(dir=project.ROOT/'.cache') as temp:
            p=Path(temp)/'run.csv'
            fields=['epoch_ms','sample_dt','air_pressure_source','vertical_speed','altitude','systems_target_altitude','speed_output','core_event_lag_s']
            with p.open('w',newline='') as f:
                w=csv.DictWriter(f,fieldnames=fields);w.writeheader()
                for i in range(70):
                    row=dict(zip(fields,[i*1000+(5000 if i>=35 else 0),1,'SABLE AERO' if i<40 else 'ALTITUDE SENSOR',0,100,110,1 if i<10 else .2,'nan' if i==3 else .5]))
                    w.writerow(row)
                    if i==50:w.writerow(row)
            report=write_report(p,Path(temp)/'report')
            self.assertEqual(len(report['gaps']),1)
            self.assertEqual(report['duplicateOrReorderedSamples'],1)
            self.assertEqual(len(report['pressureWindows']),2)
            self.assertEqual(len(report['altitudeStalls']),2)
            self.assertEqual(report['speedOutputSaturation']['saturated'],10)
            self.assertEqual(report['distributions']['core_event_lag_s']['max'],.5)
            self.assertIn('command_ack_wait_s',report['missingColumns'])
            self.assertIsNone(report['distributions']['command_ack_wait_s'])
            self.assertTrue((Path(temp)/'report/report.md').exists())

    def test_historical_headers_and_added_columns(self):
        with tempfile.TemporaryDirectory(dir=project.ROOT/'.cache') as temp:
            p=Path(temp)/'old.csv';p.write_text('epoch_ms,altitude,extra\n1000,100,unused\n2000,101,unused\n')
            report=analyze(p)
            self.assertIsNone(report['recordingSchemaVersion'])
            self.assertEqual(report['rows'],2)
            self.assertIsNone(report['speedOutputSaturation']['fraction'])
            p.with_suffix('.json').write_text('{"schemaVersion":5}')
            self.assertEqual(analyze(p)['recordingSchemaVersion'],5)

    def test_recorded_input_source_bundle_trace(self):
        persistence.PersistenceTests.setUpClass()
        profile=json.loads((project.ROOT/'tests/fixtures/plant-profile.json').read_text())
        traces=[]
        for bundled in [False,True]:
            lua=persistence.PersistenceTests().runtime(False)
            if bundled:
                packed=project.builder_module().bundling.pack({**persistence.PersistenceTests.sources,
                    '/avionics/main.lua':b"return require('avionics.flight')"},persistence.PersistenceTests.loader,role='replay',entry='/avionics/main.lua')
                lua.globals().Flight=lua.execute('return assert(load(...))()',packed.decode())
            else:lua.execute("Flight=require('avionics.flight')")
            lua.globals().CONFIG=table(lua,profile['recordingConfig'])
            lua.execute(r"""
local f=Flight.new(CONFIG);local run={phase='READY',dynamics={sampleSeconds=.5},responseLagSeconds=1}
local io={nodes={},nodeFresh=function()return true end,vessel={environment={gravity={y=-11}}}}
local gas,strength=next(f.config.verified_gas_lift_strengths)
function replay(row,dt)
 io.vessel.altitude=row.altitude;io.vessel.verticalSpeed=row.verticalSpeed;io.vessel.mass=row.mass
 io.vessel.environment.airPressure=row.pressure;run.target=row.selectedAltitude
 for _,q in ipairs({'FL','FR','BL','BR'}) do
  io.nodes[q]={balloon={gasMixValid=true,gasMix={[gas]=row.rawLift/(4*strength)}},
   providers={bulk={controlRole='bulk',gasTypeValid=true,gasType=gas,gasOutputValid=true,
    gasOutput=row.appliedRawLift/(4*strength),targetAmount=row.appliedRawLift/(4*strength)}}}
 end
 local out,why=f:systemsAcquisitionControl(io,run,dt,row.rawLift*row.pressure/row.mass,row.at,dt)
 assert(out,why);return out,f.outer.i,f.inner.i,f.verticalTarget
end
""")
            previous=None;trace=[]
            for row in profile['replayRows']:
                dt=.5 if previous is None else row['at']-previous
                self.assertGreater(dt,0)
                result=lua.globals().replay(table(lua,row),dt)
                self.assertTrue(all(math.isfinite(x) for x in result))
                trace.append(result);previous=row['at']
            traces.append(trace)
        self.assertEqual(traces[0],traces[1])
        output=project.ROOT/'output/tests/recording-replay';output.mkdir(parents=True,exist_ok=True)
        (output/'trace.json').write_text(json.dumps({'recording':profile['recording'],'sha256':profile['sha256'],
            'pressureSource':profile['windows'][0]['pressureSource'],'trace':traces[0],
            'limitation':'component replay; full historical controller/supervisor state is unavailable'},indent=2)+'\n')

if __name__=='__main__':unittest.main()
