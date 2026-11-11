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
if a[0] == 'nm':
    if os.environ.get('CHECK_NM_FAIL'): sys.exit(1)
    name=Path(a[-1]).name
    symbols=['_ZN3lld5macho4linkEfixture', '_ZN3lld5macho22createARM64eTargetInfoEv', '_ZN3lld13getLLDVersionEv']
    if name=='liblldMachO.a': symbols=symbols[:2]
    if name=='liblldCommon.a': symbols=symbols[2:]
    for s in symbols:
        if os.environ.get('CHECK_MISSING_SYMBOL') in (s, 'all'): continue
        print(('                 U ' if os.environ.get('CHECK_UNDEFINED_ONLY') else '0000000000000010 T ')+'_'+s)
    sys.exit(0)
if a[0] == 'libtool':
    if a[1:3]!=['-static','-o']: sys.exit(64)
    Path(a[3]).write_bytes(b''.join(Path(p).read_bytes() for p in a[4:])); sys.exit(0)
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
               'dev-headers/common/include':['llvm/ADT/ArrayRef.h','clang/Frontend/CompilerInstance.h']+[
                   'lld/Common/'+x for x in ['Driver.h','Version.h','ErrorHandler.h','CommonLinkerContext.h']],
               'dev-headers/licenses':['LLVM-LICENSE.txt','Clang-LICENSE.txt','LLD-LICENSE.txt']}
        gen={a:f'dev-headers/{a}/include' for a in archs}
        for a in archs:
            trees[gen[a]]=['llvm/Config/'+x for x in ['config.h','llvm-config.h','abi-breaking.h']]+[
                'llvm/IR/IntrinsicEnums.inc','llvm/IR/IntrinsicImpl.inc','clang/Basic/Version.inc','clang/Config/config.h',
                'lld/Common/Version.inc']
        records={t:{f:self.put(t+'/'+f) for f in fs} for t,fs in trees.items()}
        for a in archs:
            records[gen[a]]['llvm/Config/llvm-config.h']=self.put(gen[a]+'/llvm/Config/llvm-config.h',
                b'#define LLVM_VERSION_MAJOR 24\n#define LLVM_VERSION_MINOR 0\n#define LLVM_VERSION_PATCH 0\n')
        records['dev-headers/common/include']['lld/Common/Driver.h']=self.put(
            'dev-headers/common/include/lld/Common/Driver.h',
            b'#include "lld/Common/CommonLinkerContext.h"\n#include "llvm/ADT/ArrayRef.h"\n')
        records['dev-headers/common/include']['lld/Common/Version.h']=self.put(
            'dev-headers/common/include/lld/Common/Version.h',b'#include "lld/Common/Version.inc"\n')
        m={'schema':2,'architectures':archs,'artifacts':arts,'clang_resource_dir':'clang-resource','header_trees':records,
           'llvm_commit':'40f30ea173b50c130c01d843b612f9563ca63930','minimum_ios':'14.0',
           'llvm_patches':{'llvm-arm64e-twork.diff':hashlib.sha256((ROOT/'deps/patches/llvm-arm64e-twork.diff').read_bytes()).hexdigest()},
           'linker_backends':{'lld_macho':{'version':'24.0.0','tool_lld':4,'api':'lld::macho::link','arm64e':True,
               'llvm_commit':'40f30ea173b50c130c01d843b612f9563ca63930','component_libraries':['lldMachO','lldCommon'],
               'archive_by_architecture':{a:f'libomllvm-{a}.a' for a in archs}},
               'ld64':{'archive':'libomld64.a','cctools_commit':json.loads((ROOT/'deps/cctools-source.json').read_text())['commit'],'tapi_shim':True}},
           'development_headers':{'common_include':'dev-headers/common/include','generated_include':gen,
                                 'include_order':['generated_include[host_architecture]','common_include']}}
        (self.kit/'toolchain.json').write_text(json.dumps(m))
    def tearDown(self): self.tmp.cleanup()
    def put(self,name,data=None):
        p=self.kit/name; p.parent.mkdir(parents=True,exist_ok=True)
        data=data if data is not None else ('fixture:'+name).encode(); p.write_bytes(data)
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
    def mutate_manifest(self, change):
        path=self.kit/'toolchain.json'; m=json.loads(path.read_text()); change(m); path.write_text(json.dumps(m))
    def test_old_kit_has_no_lld_capability(self):
        self.mutate_manifest(lambda m: m.pop('linker_backends'))
        r = self.run_script('verify-artifacts.sh')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('LEGACY', r.stdout)
        r = subprocess.run(['bash', str(ROOT/'verify-artifacts.sh'), str(self.kit), '--require-lld'],
                           env=self.env, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('LLD', r.stderr)
    def test_legacy_kit_integrity_and_explicit_lld_requirement(self):
        self.mutate_manifest(lambda m: (m.pop('linker_backends'), m.pop('llvm_patches')))
        for header in ['Driver.h', 'Version.h', 'ErrorHandler.h', 'CommonLinkerContext.h']:
            self.remove_header_record('dev-headers/common/include', 'lld/Common/' + header)
        self.remove_header_record('dev-headers/licenses', 'LLD-LICENSE.txt')
        for arch in ['arm64', 'arm64e']:
            self.remove_header_record('dev-headers/' + arch + '/include', 'lld/Common/Version.inc')
        cmd = ['python3', str(ROOT/'scripts/verify-toolchain-manifest.py'), str(self.kit), '--integrity-only']
        legacy = subprocess.run(cmd, env=self.env, capture_output=True, text=True)
        self.assertEqual(legacy.returncode, 0, legacy.stdout + legacy.stderr)
        self.assertIn('ld64-only', legacy.stdout)
        self.assertIn('Not kit acceptance', legacy.stdout)
        strict = subprocess.run(cmd + ['--require-lld'], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(strict.returncode, 0)
    def test_wrong_lld_version_and_backend_are_rejected(self):
        for key,value in [('version','23.0.0'),('api','ld64'),('component_libraries',['lldMachO']),('tool_lld',3),('arm64e',False)]:
            with self.subTest(key=key):
                old=json.loads((self.kit/'toolchain.json').read_text())
                self.mutate_manifest(lambda m:m['linker_backends']['lld_macho'].__setitem__(key,value))
                self.assertNotEqual(self.run_script('verify-artifacts.sh').returncode,0)
                (self.kit/'toolchain.json').write_text(json.dumps(old))
    def test_unpinned_llvm_and_patch_are_rejected(self):
        for key,value in [('llvm_commit','0'*40),('llvm_patches',{'llvm-arm64e-twork.diff':'0'*64})]:
            old=json.loads((self.kit/'toolchain.json').read_text())
            self.mutate_manifest(lambda m:m.__setitem__(key,value))
            self.assertNotEqual(self.run_script('verify-artifacts.sh').returncode,0)
            (self.kit/'toolchain.json').write_text(json.dumps(old))
    def test_lld_symbols_required_in_each_merged_archive(self):
        for symbol in ['_ZN3lld5macho4linkEfixture','_ZN3lld5macho22createARM64eTargetInfoEv','_ZN3lld13getLLDVersionEv']:
            r=self.run_script('verify-artifacts.sh',{'CHECK_MISSING_SYMBOL':symbol})
            self.assertNotEqual(r.returncode,0); self.assertIn('missing defined LLD symbol',r.stderr)
    def test_undefined_references_are_not_lld_definitions(self):
        r=self.run_script('verify-artifacts.sh',{'CHECK_UNDEFINED_ONLY':'1'})
        self.assertNotEqual(r.returncode,0); self.assertIn('missing defined LLD symbol',r.stderr)
    def test_nm_failure_is_not_a_pass(self):
        r=self.run_script('verify-artifacts.sh',{'CHECK_NM_FAIL':'1'})
        self.assertNotEqual(r.returncode,0); self.assertIn('nm failed',r.stderr)
    def remove_header_record(self,tree,name):
        (self.kit/tree/name).unlink()
        self.mutate_manifest(lambda m:m['header_trees'][tree].pop(name))
    def test_lld_driver_header_required_even_with_consistent_inventory(self):
        self.remove_header_record('dev-headers/common/include','lld/Common/Driver.h')
        r=self.run_script('verify-artifacts.sh'); self.assertNotEqual(r.returncode,0); self.assertIn('Driver.h',r.stderr)
    def test_lld_generated_include_closure_required(self):
        self.remove_header_record('dev-headers/arm64/include','lld/Common/Version.inc')
        r=self.run_script('verify-artifacts.sh'); self.assertNotEqual(r.returncode,0); self.assertIn('transitive include',r.stderr)
    def test_generated_version_cannot_disagree_with_manifest(self):
        tree='dev-headers/arm64/include'; name='llvm/Config/llvm-config.h'
        record=self.put(tree+'/'+name,b'#define LLVM_VERSION_MAJOR 23\n#define LLVM_VERSION_MINOR 0\n#define LLVM_VERSION_PATCH 0\n')
        self.mutate_manifest(lambda m:m['header_trees'][tree].__setitem__(name,record))
        r=self.run_script('verify-artifacts.sh'); self.assertNotEqual(r.returncode,0); self.assertIn('version disagrees',r.stderr)
    def test_integrity_only_is_explicitly_not_kit_acceptance(self):
        r=subprocess.run(['python3',str(ROOT/'scripts/verify-toolchain-manifest.py'),str(self.kit),'--integrity-only'],env=self.env,capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr); self.assertIn('Not kit acceptance',r.stdout); self.assertFalse(self.log.exists())
    def test_lld_targets_and_cache_inputs_are_explicit(self):
        source=(ROOT/'scripts/build-ios-toolchain.sh').read_text()
        self.assertIn("'-DLLVM_ENABLE_PROJECTS=clang;lld'",source)
        self.assertIn('--target lldMachO lldCommon',source)
        self.assertIn('-DLLD_BUILD_TOOLS=OFF',source)
        workflow=(ROOT.parent/'.github/workflows/ios-toolchain.yml').read_text()
        self.assertIn('branches: [ios15-port, twork-parity-lld-20261111]',workflow)
        for value in ['om-kit-lld-v2-',"'toolchain-build/scripts/**'","'toolchain-build/src/**'","'toolchain-build/verify-artifacts.sh'"]:
            self.assertIn(value,workflow)
    def test_aggregate_requires_real_built_lld_components(self):
        import ast
        source=(ROOT/'scripts/build-ios-toolchain.sh').read_text().split("<<'PY'\n",1)[1].split('\nPY',1)[0]
        tree=ast.parse(source)
        node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='component_libs')
        checked=[]
        namespace={'os':os,'verifier':{'verify_lld_symbols':lambda *args:checked.append(args)}}
        exec(compile(ast.Module(body=[node],type_ignores=[]),'aggregate-contract','exec'),namespace)
        directory=self.base/'slice'; directory.mkdir()
        names=['libLLVMCore.a','libclangBasic.a','liblldCommon.a','liblldMachO.a']
        for name in names: (directory/name).write_bytes(('built:'+name).encode())
        libs=namespace['component_libs'](str(directory))
        self.assertEqual([Path(p).name for p in libs],['liblldMachO.a','liblldCommon.a','libclangBasic.a','libLLVMCore.a'])
        self.assertEqual([Path(args[0]).name for args in checked],['liblldMachO.a','liblldCommon.a'])
        (directory/'liblldCommon.a').unlink()
        with self.assertRaisesRegex(SystemExit,'missing/empty required LLD component'):
            namespace['component_libs'](str(directory))
        (directory/'liblldCommon.a').write_bytes(b'')
        with self.assertRaisesRegex(SystemExit,'missing/empty required LLD component'):
            namespace['component_libs'](str(directory))
    def test_old_production_lock_does_not_claim_lld(self):
        lock=json.loads((ROOT/'verified-toolchain-lock.json').read_text())
        self.assertNotIn('lld_macho',lock.get('linker_backends',{}))
    def test_runtime_evidence_matches_pinned_artifact_and_rejects_mutation(self):
        repo = ROOT.parent
        validator = repo/'scripts/ios15/verify-embedded-toolchain-runtime-evidence.py'
        evidence = ROOT/'runtime-validation-evidence.json'
        lock = ROOT/'verified-toolchain-lock.json'
        self.assertEqual(subprocess.run(['python3',str(validator),str(evidence),str(lock)],capture_output=True).returncode,0)
        record=json.loads(evidence.read_text())
        record['report']['required_steps']['compile_arm64_foundation_objective_c']='failed'
        mutated=Path(self.tmp.name)/'mutated-runtime-evidence.json'
        mutated.write_text(json.dumps(record))
        self.assertNotEqual(subprocess.run(['python3',str(validator),str(mutated),str(lock)],capture_output=True).returncode,0)
    def test_cc1_options_exclude_executable_name(self):
        source=(ROOT.parent/'src/ios/Vendor/OMToolchain/OMToolchain.mm').read_text()
        cc1=source[source.index('+ (OMToolchainStatus)runCC1:'):source.index('#pragma mark - Linker')]
        self.assertIn('ArgvStorage argv(frontendArguments, /*prependProgramName=*/false);', cc1)
        self.assertIn('/*Argv0=*/"clang"', cc1)
        self.assertIn('isEqualToString:@"-cc1"', cc1)
        self.assertNotIn('/*prependProgramName=*/true', cc1)

if __name__=='__main__':
    print('Fixture contracts and locked runtime-evidence policy only; real Xcode compile/link and device tests still required.',flush=True)
    unittest.main(verbosity=2)
