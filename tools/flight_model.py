"""Deterministic aggregate lift and longitudinal plant for offline control scenarios."""
from dataclasses import dataclass
from functools import lru_cache
import bisect
import csv
import hashlib
import json
import math
from pathlib import Path
import statistics


@lru_cache(maxsize=8)
def pressure_points(min_y=-64, logical_height=384, sea_level=63):
    """Construct the inspected Sable 2.0.5 default pressure interpolation knots."""
    end=min_y+logical_height; taper=end-40
    at=max(min_y,math.log(1.5)/-.004+sea_level); points=[]
    while True:
        value=math.exp(-.004*(at-sea_level));points.append((at,value,-.004*value))
        if at<sea_level and at+200>=sea_level: at=sea_level
        elif at<taper and at+200>=taper: at=taper
        elif at>=taper: break
        else: at+=200
    points.append((end,0,-2*points[-1][1]/40))
    return points


def pressure(y,min_y=-64,logical_height=384,sea_level=63):
    """Evaluate Sable's cubic pressure segments, including the upper 40-block taper."""
    points=pressure_points(min_y,logical_height,sea_level)
    i=bisect.bisect_right([p[0] for p in points],y)-1
    if i<0:return points[0][1]
    if i>=len(points)-1:return points[-1][1]
    x,a,m=points[i];nx,b,n=points[i+1];dx=nx-x;dy=b-a;t=(y-x)/dx
    return max(0,(((m+n)*dx-2*dy)*t+3*dy-(2*m+n)*dx)*t*t+dx*m*t+a)


@dataclass
class Plant:
    """Advance aggregate raw lift, altitude and speed under bounded applied commands."""
    mass: float=147739.375
    gravity: float=11.0
    altitude: float=250.0
    vertical_speed: float=0.0
    speed: float=0.0
    raw_lift: float=0.0
    maximum_raw_lift: float=1200000.0
    gas_lag: float=2.0
    gas_delay: float=0.0
    vertical_drag: float=.019
    drag_tau: float=5.5
    drive_acceleration: float=5.0
    pressure_offset: float=0.0
    constant_pressure: float=None
    time: float=0.0

    def __post_init__(self):
        self.history=[]
        self.acceleration=0.0
        if self.raw_lift==0:self.raw_lift=self.mass/max(self.air_pressure(),1e-9)

    def air_pressure(self):
        """Return the profile pressure at the modeled envelope sampling height."""
        return self.constant_pressure if self.constant_pressure is not None else pressure(self.altitude+self.pressure_offset)

    def step(self,raw_target,drive,dt):
        """Integrate delayed first-order fill and drag with at most 0.05-second substeps."""
        if not math.isfinite(dt) or dt<=0:raise ValueError('positive finite timestep required')
        raw_target=max(0,min(self.maximum_raw_lift,raw_target));drive=max(-1,min(1,drive))
        self.history.append((self.time,raw_target))
        n=max(1,math.ceil(dt/.05));h=dt/n
        for _ in range(n):
            eligible=self.time-self.gas_delay
            while len(self.history)>1 and self.history[1][0]<=eligible:self.history.pop(0)
            goal=self.history[0][1] if self.history[0][0]<=eligible else self.raw_lift
            self.raw_lift=goal+(self.raw_lift-goal)*math.exp(-h/max(self.gas_lag,1e-6))
            support=self.raw_lift*self.air_pressure()/self.mass
            k=self.gravity*self.vertical_drag
            forcing=self.gravity*(support-1)
            old=self.vertical_speed
            if k>0:
                equilibrium=forcing/k;decay=math.exp(-k*h)
                self.vertical_speed=equilibrium+(old-equilibrium)*decay
                self.altitude+=equilibrium*h+(old-equilibrium)*(1-decay)/k
            else:
                self.vertical_speed=old+forcing*h;self.altitude+=old*h+forcing*h*h/2
            self.acceleration=(self.vertical_speed-old)/h
            equilibrium=self.drive_acceleration*drive*(self.air_pressure()/.55)*self.drag_tau
            self.speed=equilibrium+(self.speed-equilibrium)*math.exp(-h/self.drag_tau)
            self.time+=h
        return self


def calibrate(recording):
    """Fit applied-volume response and record the active pressure basis for every window."""
    path=Path(recording);rows=list(csv.DictReader(path.open(encoding='utf-8-sig',newline='')))
    def number(row,key):
        try:
            x=float(row[key]);return x if math.isfinite(x) else None
        except (KeyError,ValueError,TypeError):return None
    windows=[];current=None
    for index,row in enumerate(rows):
        source=row.get('air_pressure_source') or 'UNKNOWN'
        if current is None or current['pressureSource']!=source:
            current={'pressureSource':source,'firstRow':index,'lastRow':index};windows.append(current)
        current['lastRow']=index
    observations=[]
    for row in rows:
        keys=['epoch_ms']+[q+'_'+k for k in ['filled_volume','applied_target_total','lift'] for q in ['fl','fr','bl','br']]
        values={k:number(row,k) for k in keys}
        if all(v is not None for v in values.values()):
            observations.append((values['epoch_ms']/1000,sum(values[q+'_filled_volume'] for q in ['fl','fr','bl','br']),
                sum(values[q+'_applied_target_total'] for q in ['fl','fr','bl','br']),sum(values[q+'_lift'] for q in ['fl','fr','bl','br'])))
    fit=None
    # Fit physical response to applied targets; command transmission delay is excluded.
    if len(observations)>20 and len(windows)==1 and windows[0]['pressureSource']!='UNKNOWN':
        best=None;times=[x[0] for x in observations]
        for delay in [0,.25,.5,1,2,3]:
            for tau in [.1,.25,.5,1,2,3,5,8,12,20]:
                predicted=observations[0][1];errors=[]
                for i in range(1,len(observations)):
                    dt=times[i]-times[i-1]
                    j=max(0,bisect.bisect_right(times,times[i-1]-delay)-1)
                    goal=observations[j][2]
                    predicted=goal+(predicted-goal)*math.exp(-dt/tau)
                    errors.append((predicted-observations[i][1])**2)
                rmse=math.sqrt(statistics.mean(errors))
                if best is None or rmse<best[0]:best=(rmse,delay,tau)
        fit={'rmseVolume':best[0],'delaySeconds':best[1],'lagSeconds':best[2],
             'method':'grid-search full-window first-order applied-target response',
             'rawLiftPerVolume':statistics.median(x[3]/x[1] for x in observations if x[1]>0),
             'status':'estimated; aggregate approximation; grid and sampling resolution limit precision'}
    for window in windows:
        selected=rows[window['firstRow']:window['lastRow']+1]
        window['startEpochMs']=selected[0].get('epoch_ms');window['endEpochMs']=selected[-1].get('epoch_ms')
        for key in ['air_pressure','air_pressure_sensor','air_pressure_sable','altitude']:
            values=[v for row in selected if (v:=number(row,key)) is not None]
            window[key]={'samples':len(values),'min':min(values) if values else None,'max':max(values) if values else None}
        window['samplingLocation']='Sable pressure: reported vessel CoM; sensor height offset unverified'
    return {'schemaVersion':1,'recording':path.as_posix(),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
        'rows':len(rows),'windows':windows,'gasResponseFit':fit,
        'parameters':{'dragTauSeconds':{'value':5.5,'status':'prior measured estimate; exact fit window unestablished'},
         'verticalDragWeightPerBps':{'value':.019,'status':'prior measured estimate; exact fit window unestablished'},
         'pressureCurve':{'value':'Sable 2.0.5 default; minY -64, logicalHeight 384, seaLevel 63',
          'status':'inspected default; active-world override unverified'}},
        'limitations':['No rotational or lateral dynamics','Provider allocation and endpoint ramps are outside this aggregate plant',
         'Source transitions require separate fits','Fits do not establish physical-flight acceptance']}
