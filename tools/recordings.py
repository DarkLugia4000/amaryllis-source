"""Column-name recording analysis with explicit thresholds and missing-data reporting."""
import csv
import json
import math
from pathlib import Path
import statistics


def number(row,key):
    """Read a finite measurement while preserving unavailable cells as missing."""
    try:
        v=float(row.get(key,''));return v if math.isfinite(v) else None
    except (TypeError,ValueError):return None


def distribution(values):
    """Summarize a measured distribution using linearly interpolated quantiles."""
    values=sorted(values)
    if not values:return None
    def percentile(q):
        i=(len(values)-1)*q;lo=int(i);hi=min(lo+1,len(values)-1)
        return values[lo]+(values[hi]-values[lo])*(i-lo)
    return {'count':len(values),'min':values[0],'median':percentile(.5),'p95':percentile(.95),'max':values[-1]}


def analyze(selection,gap_seconds=3,error_blocks=2,stall_seconds=20):
    """Report timing, source changes, output limits and sustained low-motion altitude error."""
    path=Path(selection)
    if path.is_dir():
        candidates=[p for p in path.glob('*.csv') if not p.name.endswith('.events.csv')]
        if len(candidates)!=1:raise ValueError('Select one recording CSV; directory has '+str(len(candidates)))
        path=candidates[0]
    with path.open(encoding='utf-8-sig',newline='') as f:
        reader=csv.DictReader(f);columns=reader.fieldnames or [];rows=list(reader)
    metadata={};meta=path.with_suffix('.json')
    if meta.exists():metadata=json.loads(meta.read_text(encoding='utf-8-sig'))
    fields=['sample_dt','core_event_lag_s','command_ack_wait_s','sensor_age','core_snapshot_ms',
            'core_propulsion_ms','core_lift_ms','core_display_send_ms']
    metrics={k:distribution([x for row in rows if (x:=number(row,k)) is not None]) for k in fields}
    windows=[];stalls=[];since=None;last_at=None;previous_sign=None;turns=0;duplicates=0;gaps=[];saturated=0;drive_samples=0
    for i,row in enumerate(rows):
        at=number(row,'epoch_ms');at=at/1000 if at is not None else None
        if at is not None and last_at is not None:
            if at<=last_at:duplicates+=1;continue
            if at-last_at>gap_seconds:gaps.append({'row':i,'seconds':at-last_at});since=None;previous_sign=None
        source=row.get('air_pressure_source') or 'UNKNOWN'
        if not windows or windows[-1]['source']!=source:windows.append({'source':source,'firstRow':i,'lastRow':i})
        else:windows[-1]['lastRow']=i
        speed=number(row,'vertical_speed');altitude=number(row,'altitude');target=number(row,'systems_target_altitude')
        if speed is not None and abs(speed)>=.1:
            sign=1 if speed>0 else -1
            if previous_sign is not None and sign!=previous_sign:turns+=1
            previous_sign=sign
        if at is not None and speed is not None and altitude is not None and target is not None and abs(target-altitude)>error_blocks and abs(speed)<.1:
            if since is None:since=at
            if at-since>=stall_seconds:
                if stalls and stalls[-1]['startSeconds']==since:stalls[-1]['endSeconds']=at
                else:stalls.append({'startSeconds':since,'endSeconds':at,'row':i,'errorBlocks':target-altitude})
        else:since=None
        output=number(row,'speed_output')
        if output is not None:drive_samples+=1;saturated+=abs(output)>=.99
        if at is not None:last_at=at
    required=set(fields+['epoch_ms','air_pressure_source','vertical_speed','altitude','systems_target_altitude','speed_output'])
    return {'schemaVersion':1,'recording':str(path),'recordingSchemaVersion':metadata.get('schemaVersion'),
        'rows':len(rows),'columns':columns,'missingColumns':sorted(required-set(columns)),
        'thresholds':{'gapSeconds':gap_seconds,'altitudeErrorBlocks':error_blocks,'stallSeconds':stall_seconds,
                      'motionDeadbandBps':.1,'speedOutputSaturation':.99},'distributions':metrics,
        'gaps':gaps,'duplicateOrReorderedSamples':duplicates,'pressureWindows':windows,
        'verticalVelocitySignChanges':turns,'altitudeStalls':stalls,
        'speedOutputSaturation':{'samples':drive_samples,'saturated':saturated,'fraction':saturated/drive_samples if drive_samples else None}}


def write_report(selection,output,**thresholds):
    """Write machine-readable metrics and a concise report with their measurement limits."""
    report=analyze(selection,**thresholds);out=Path(output);out.mkdir(parents=True,exist_ok=True)
    (out/'analysis.json').write_text(json.dumps(report,indent=2,allow_nan=False)+'\n',encoding='utf-8')
    lines=['# Recording analysis','',report['recording'],'',f"Samples: {report['rows']}. Schema: {report['recordingSchemaVersion']}.",
        '',f"Gaps: {len(report['gaps'])}; duplicate/reordered samples: {report['duplicateOrReorderedSamples']}.",
        f"Low-motion altitude-error intervals: {len(report['altitudeStalls'])}.",
        f"Vertical-velocity sign changes outside 0.1 b/s deadband: {report['verticalVelocitySignChanges']}.",
        '', 'Sign changes identify possible oscillation; the report retains their count without inferring a cause.',
        '', '| Measurement | Median | p95 | Maximum |','| --- | ---: | ---: | ---: |']
    for key,value in report['distributions'].items():
        if value:lines.append(f"| {key} | {value['median']:.4g} | {value['p95']:.4g} | {value['max']:.4g} |")
        else:lines.append(f'| {key} | unavailable | unavailable | unavailable |')
    lines+=['','Thresholds: `'+json.dumps(report['thresholds'])+'`.',
        '', 'Missing columns: '+(', '.join(report['missingColumns']) or 'none')+'.',
        '', 'Pressure windows: `'+json.dumps(report['pressureWindows'])+'`.',
        '', 'Timing is taken from recorded fields. Saturation counts refer to speed_output only. Physical-flight validation is separate.']
    (out/'report.md').write_text('\n'.join(lines)+'\n',encoding='utf-8');return report
