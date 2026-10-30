#!/usr/bin/env python3
"""Test shell argument/error contracts with a strict xcrun fixture, not real LLVM."""
import hashlib, json, os, re, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
with open(os.environ['CHECK_LOG'], 'a') as f: f.write(json.dumps(a)+'\n')
if a[:2] == ['--sdk','iphoneos']: a=a[2:]
if a == ['--show-sdk-path']: print('/fixture/sdk'); sys.exit(0)
if a[0] == 'clang++':
    Path(a[a.index('-o')+1]).write_bytes(b'fixture object'); sys.exit(0)
if a[0] == 'lipo':
    a=a[1:]
    if a[0]=='-info': sys.exit(0 if Path(a[1]).is_file() else 1)
    if len(a)<3 or not Path(a[0]).is_file() or a[1]!='-verify_arch': sys.exit(64)
    if any(x not in ('arm64','arm64e') for x in a[2:]): sys.exit(64)
    if os.environ.get('CHECK_REJECT') in a[2:]: sys.exit(1)
    sys.exit(0)
sys.exit(65)
'''
class Contracts(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='om-contract-')
        self.base=Path(self.tmp.name); self.kit=self.base/'kit'; b=self.base/'bin'; b.mkdir()
        self.x=b/'xcrun'; self.x.write_text(MOCK); self.x.chmod(0o755)
        self.log=self.base/'log'
        self.env={**os.environ,'PATH':str(b)+os.pathsep+os.environ.get('PATH',''),'CHECK_LOG':str(self.log)}
        archs=['arm64','arm64e']; arts={}
        for a in archs: arts[f'libomllvm-{a}.a']={**self.put(f'libomllvm-{a}.a'),'arch':a}
        arts['libomld64.a']=self.put('libomld64.a')
        trees={'clang-resource':['include/'+x for x in ['stddef.h','stdarg.h','stdint.h','ptrauth.h','arm_neon.h']],
               'dev-headers/common/include':['llvm/ADT/ArrayRef.h','clang/Frontend/CompilerInstance.h'],
               'dev-headers/licenses':['LLVM-LICENSE.txt','Clang-LICENSE.txt']}
        gen={a:f'dev-headers/{a}/include' for a in archs}
        for a in archs:
            trees[gen[a]]=['llvm/Config/'+x for x in ['config.h','llvm-config.h','abi-breaking.h']]+[
                'llvm/IR/IntrinsicEnums.inc','llvm/IR/IntrinsicImpl.inc','clang/Basic/Version.inc','clang/Config/config.h']
        records={t:{f:self.put(t+'/'+f) for f in fs} for t,fs in trees.items()}
        m={'schema':2,'architectures':archs,'artifacts':arts,'clang_resource_dir':'clang-resource','header_trees':records,
           'llvm_commit':'40f30ea173b50c130c01d843b612f9563ca63930','minimum_ios':'14.0',
           'development_headers':{'common_include':'dev-headers/common/include','generated_include':gen,
                                 'include_order':['generated_include[host_architecture]','common_include']}}
        (self.kit/'toolchain.json').write_text(json.dumps(m))
    def tearDown(self): self.tmp.cleanup()
    def put(self,name):
        p=self.kit/name; p.parent.mkdir(parents=True,exist_ok=True); data=('fixture:'+name).encode(); p.write_bytes(data)
        return {'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
    def run_script(self,p,extra=None):
        return subprocess.run(['bash',str(ROOT/p),str(self.kit)],env={**self.env,**(extra or {})},capture_output=True,text=True)
    def calls(self): return [a for a in map(json.loads,self.log.read_text().splitlines()) if a[0]=='lipo' and '-verify_arch' in a]
    def test_archive_order(self):
        r=self.run_script('verify-artifacts.sh'); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual([a[3:] for a in self.calls()],[['arm64'],['arm64e'],['arm64','arm64e']])
    def test_probe_order(self):
        r=self.run_script('scripts/check-dev-headers.sh'); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual([a[3:] for a in self.calls()],[['arm64'],['arm64e']])
    def test_lipo_failure_propagates(self):
        for p in ['verify-artifacts.sh','scripts/check-dev-headers.sh']:
            self.assertNotEqual(self.run_script(p,{'CHECK_REJECT':'arm64'}).returncode,0,p)
    def test_fixture_rejects_run4_run5_bug(self):
        r=subprocess.run([str(self.x),'lipo','-verify_arch','arm64',str(self.kit/'libomllvm-arm64.a')],env=self.env)
        self.assertEqual(r.returncode,64)
    def test_hash_mismatch_fails_before_lipo(self):
        (self.kit/'libomllvm-arm64.a').write_bytes(b'wrong')
        self.assertNotEqual(self.run_script('verify-artifacts.sh').returncode,0); self.assertFalse(self.log.exists())
    def test_symlink_headers_fail(self):
        p=self.kit/'clang-resource/include/stddef.h'; p.unlink(); p.symlink_to(p.parent/'stdint.h')
        self.assertNotEqual(self.run_script('verify-artifacts.sh').returncode,0)
    def test_no_flag_first_lipo_in_scripts(self):
        for p in ROOT.rglob('*.sh'):
            if {'work','build'} & set(p.relative_to(ROOT).parts): continue
            self.assertIsNone(re.search(r'\blipo\s+-verify_arch\b',p.read_text()),str(p))
    def test_cc1_options_exclude_executable_name(self):
        source=(ROOT.parent/'src/ios/Vendor/OMToolchain/OMToolchain.mm').read_text()
        cc1=source[source.index('+ (OMToolchainStatus)runCC1:'):source.index('#pragma mark - Linker')]
        self.assertIn('ArgvStorage argv(frontendArguments, /*prependProgramName=*/false);', cc1)
        self.assertIn('/*Argv0=*/"clang"', cc1)
        self.assertIn('isEqualToString:@"-cc1"', cc1)
        self.assertNotIn('/*prependProgramName=*/true', cc1)

if __name__=='__main__':
    print('Fixture command-contract tests only; real Xcode compile/link and device tests still required.',flush=True)
    unittest.main(verbosity=2)
