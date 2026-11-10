"""Lua quoting compatibility checks requiring only the Python standard library."""
from pathlib import Path
import importlib.util,unittest
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('compat_bundling',ROOT/'disk-builder/bundling.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
class QuotingTests(unittest.TestCase):
 def test_exact_escape_bytes(self):
  self.assertEqual(b.quote(b'\x00\t\n\r"\\\x1f\x7fAZ'),b'"\\000\\009\\010\\013\\"\\\\\\031\\127AZ"')
 def test_every_byte_roundtrips_and_matches_reference(self):
  data=bytes(range(256))*4;expected=bytearray(b'"')
  for n in data:
   if n<32 or n==127:expected.extend(('\\%03d'%n).encode('ascii'))
   elif n in (34,92):expected.extend(bytes([92,n]))
   else:expected.append(n)
  expected.append(34)
  self.assertEqual(b.quote(data),bytes(expected));self.assertEqual(b.unquote(b.quote(data)),data)
 def test_empty_and_utf8(self):
  for data in [b'','Amaryllis: é ß →'.encode('utf-8'),b'"\\'*1000]:
   self.assertEqual(b.unquote(b.quote(data)),data)
 def test_large_lua_repeated_pack_is_stable(self):
  data=(b'-- repeated realistic Lua source\r\nlocal s="text\\n"\n'*20000)+b'return true\n'
  expected=b.quote(data)
  for _ in range(12):self.assertEqual(b.quote(data),expected)
  self.assertEqual(b.unquote(expected),data)
class ReadableSourceTests(unittest.TestCase):
 def pack(self,data,**kw):
  return b.pack({'/avionics/main.lua':data},b'-- loader\n',role='test',entry='/avionics/main.lua',**kw)
 def test_readable_default_preserves_lines_and_literals(self):
  source=b'-- Section: purpose\nlocal function sample()\n    return "quoted" .. "\\\\path"\nend\nreturn sample()\n'
  packed=self.pack(source)
  self.assertIn(source,packed)
  self.assertNotIn(b'\\010',packed)
  self.assertEqual(b.unpack(packed,b'-- loader\n')[1]['/avionics/main.lua'],source)
 def test_newline_control_and_delimiter_roundtrips(self):
  for source in [b'',b'\n',b'\n\nreturn 1',b'return 1\n',b'return 1\r\n',b'\r\nreturn 1\r\n',
                 b'one\r\ntwo\nthree\rfour',b'-- ]=] ]==] ]===]\nreturn 1 -- ]=',b'-- nul\x00tab\tend\x7f\n',
                 'return "é ß →"\n'.encode('utf-8')]:
   with self.subTest(source=source):
    packed=self.pack(source)
    self.assertEqual(b.unpack(packed,b'-- loader\n')[1]['/avionics/main.lua'],source)
    self.assertEqual(packed,self.pack(source))
 def test_legacy_format_remains_exact_and_readable(self):
  source=b'-- legacy\r\nreturn "x"\n'
  packed=self.pack(source,source_format='escaped-v1')
  self.assertNotIn(b'"sourceFormat"',packed)
  self.assertIn(b.quote(source),packed)
  index,files=b.unpack(packed,b'-- loader\n')
  self.assertEqual(files['/avionics/main.lua'],source)
  self.assertNotIn('encoding',index['files'][0])
 def test_readable_source_tampering_is_rejected(self):
  packed=self.pack(b'-- source\nreturn 123\n')
  for damaged in [packed.replace(b'return 123',b'return 124'),packed.replace(b'"long-lf"',b'"unknown"'),
                  packed.replace(b'"readable-v1"',b'"unknown-v1"'),packed+b'\n']:
   with self.subTest(damaged=damaged[:80]):
    with self.assertRaises(ValueError):b.unpack(damaged,b'-- loader\n')
 def test_unknown_format_refused(self):
  with self.assertRaises(ValueError):self.pack(b'return 1',source_format='future')
if __name__=='__main__':unittest.main(verbosity=2)
