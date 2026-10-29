"""Package the current standalone builder version, preserving released ZIPs."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import zipfile

HERE = Path(__file__).resolve().parents[1]
UTILITY = HERE/'Amaryllis Installer Builder'
spec = importlib.util.spec_from_file_location('builder', UTILITY/'builder.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
assert re.fullmatch(r'\d+\.\d+\.\d+', builder.VERSION)
hashes = json.loads((UTILITY/'assets/asset-hashes.json').read_bytes())
for name, digest in hashes.items():
    assert hashlib.sha256((UTILITY/'assets'/name).read_bytes()).hexdigest() == digest
names = ['builder.py', 'bundling.py', 'presentation.py', 'information.py', 'source_notes.py', 'updater.py', 'cc_settings.py', 'Start Builder.cmd', 'README.md', 'assets/asset-hashes.json']
names += ['assets/'+name for name in hashes]
contents = {'Amaryllis Disk Builder/'+name: (UTILITY/name).read_bytes() for name in names}
release_dir = HERE/'releases'/'builders'
release_dir.mkdir(parents=True, exist_ok=True)
target = release_dir/('Amaryllis-Disk-Builder-v'+builder.VERSION+'.zip')
with zipfile.ZipFile(target, 'x', compression=zipfile.ZIP_DEFLATED) as bundle:
    for name, data in contents.items(): bundle.writestr(name, data)
with zipfile.ZipFile(target) as bundle:
    assert bundle.testzip() is None and set(bundle.namelist()) == set(contents)
    for name, data in contents.items(): assert bundle.read(name) == data
print(json.dumps({'path': str(target), 'files': len(contents), 'bytes': target.stat().st_size,
                  'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}, indent=2))
