#!/usr/bin/env python3
"""Run real DEBUG app checks; reports go into verification. Requires a booted simulator."""
import argparse,json,subprocess,time,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('device');p.add_argument('--bundle',type=Path,default=ROOT/'build-validation/Build/Products/Debug-iphonesimulator/OfflineBrowser.app');p.add_argument('--checks',nargs='+',default=['architecture','integration']);args=p.parse_args()
def sim(*parts):return subprocess.check_output(['xcrun','simctl',*parts],text=True).strip()
sim('install',args.device,str(args.bundle))
container=Path(sim('get_app_container',args.device,'org.local.offlinebrowser','data'))
for name in args.checks:
    subprocess.run(['xcrun','simctl','terminate',args.device,'org.local.offlinebrowser'],capture_output=True)
    report=container/'Documents'/f'{name}-results.json';report.unlink(missing_ok=True)
    sim('launch',args.device,'org.local.offlinebrowser',f'--{name}-test','--ui-reset')
    until=time.monotonic()+240;last=0
    required={'architecture':'HTTPS system trust','integration':'no kit dynamic data offline'}[name]
    while time.monotonic()<until:
        data={}
        try:data=json.loads(report.read_text())
        except (FileNotFoundError,ValueError):pass
        if 'FAIL' in data.values() or 'error' in data:raise AssertionError(data)
        if data.get(required)=='PASS' or data.get(required) is True:
            dest=ROOT/'verification'/f'{name}-results.json';shutil.copyfile(report,dest)
            print(name, 'PASS',json.dumps(data,ensure_ascii=False),flush=True);break
        if time.monotonic()-last>40:print(name,'running',len(data),'checks reported',flush=True);last=time.monotonic()
        time.sleep(.5)
    else:raise TimeoutError(f'{name}: no completed report')
subprocess.run(['xcrun','simctl','terminate',args.device,'org.local.offlinebrowser'],capture_output=True)
