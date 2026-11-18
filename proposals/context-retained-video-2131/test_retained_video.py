"""Owned disposable SQL qualification only; no DSNs, credentials or hosted targets."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def export_sources(root, env):
    """Resolve only pinned local Git blobs before PostgreSQL starts."""
    manifest = json.loads((HERE/'sources.json').read_text())
    needed = manifest['qualification']['compatibility_prerequisites'] + [manifest['qualification']['unchanged_locator_regression_fixture']]
    target = root/'sources'
    target.mkdir(mode=0o700)
    for entry in needed:
        blob = subprocess.run(['/usr/bin/git', '-C', str(REPO), 'show', entry['commit']+':'+entry['path']], env={**env, 'GIT_CONFIG_NOSYSTEM':'1', 'GIT_CONFIG_GLOBAL':'/dev/null'}, check=True, capture_output=True, timeout=10).stdout
        if env.get('VIDEO_QUALIFICATION_FAULT') == 'source-export' or hashlib.sha256(blob).hexdigest() != entry['sha256']:
            raise RuntimeError('Pinned source hash mismatch: '+entry['path'])
        (target/Path(entry['path']).name).write_bytes(blob)


def fixture_environment(root, pg_bin, fault=None):
    """Allowlist only owned paths and fixed controls; never copy ambient values."""
    metadata = json.loads((root/'fixture-owner.json').read_text())
    socket = Path(metadata['socket'])
    if not root.is_absolute() or root.resolve() != root or socket.parent != root:
        raise RuntimeError('Owned absolute fixture root required')
    for directory in [root/'home', root/'tmp']:
        if directory.is_symlink() or not directory.is_dir() or directory.stat().st_uid != os.getuid():
            raise RuntimeError('Owned fixture home/tmp directory required')
    if fault not in (None, 'signal', 'timeout', 'worker-exit', 'source-export'):
        raise RuntimeError('Unknown qualification fault')
    env = {'HOME': str(root/'home'), 'TMPDIR': str(root/'tmp'),
           'PATH': os.pathsep.join([str(pg_bin), str(Path(sys.executable).resolve().parent), '/usr/bin', '/bin']),
           'LANG': 'C', 'LC_ALL': 'C', 'TZ': 'UTC',
           'VIDEO_QUALIFICATION_BIN': str(pg_bin),
           'VIDEO_QUALIFICATION_SOCKET': str(socket)}
    if fault is not None: env['VIDEO_QUALIFICATION_FAULT'] = fault
    return env


def prepare_worker_environment():
    """Scrub before even lease-check subprocesses; then validate the registered owner."""
    socket = Path(os.environ['VIDEO_QUALIFICATION_SOCKET'])
    if not socket.is_absolute() or socket.is_symlink() or socket.resolve() != socket:
        raise RuntimeError('Owned absolute Unix socket directory required')
    pg_bin = Path(os.environ['VIDEO_QUALIFICATION_BIN'])
    fault = os.environ.get('VIDEO_QUALIFICATION_FAULT')
    env = fixture_environment(socket.parent, pg_bin, fault)
    os.environ.clear()
    os.environ.update(env)
    return verify_worker_lease()


def verify_worker_lease():
    """Reject direct/remote worker targets before any SQL or environment forwarding."""
    import stat
    socket = Path(os.environ['VIDEO_QUALIFICATION_SOCKET'])
    if not socket.is_absolute() or socket.is_symlink() or socket.resolve() != socket:
        raise RuntimeError('Owned absolute Unix socket directory required')
    root = socket.parent
    metadata = json.loads((root/'fixture-owner.json').read_text())
    info = socket.stat()
    cluster = socket/'pg'
    if (metadata['socket'], metadata['cluster']) != (str(socket), str(cluster)) or cluster.is_symlink():
        raise RuntimeError('Worker lease path mismatch')
    if metadata['worker_pid'] != os.getppid() or (metadata['uid'], metadata['device'], metadata['inode']) != (info.st_uid, info.st_dev, info.st_ino) or info.st_uid != os.getuid():
        raise RuntimeError('Worker lease owner mismatch')
    pg_bin = Path(metadata['pg_bin'])
    if str(pg_bin) != os.environ['VIDEO_QUALIFICATION_BIN'] or pg_bin.resolve() != pg_bin:
        raise RuntimeError('Worker executable binding mismatch')
    if not stat.S_ISSOCK((socket/'.s.PGSQL.55473').stat().st_mode):
        raise RuntimeError('Owned Unix socket absent')
    lines = (cluster/'postmaster.pid').read_text().splitlines()
    if Path(lines[1]).resolve() != cluster or _owned_postmasters(cluster) != [int(lines[0])]:
        raise RuntimeError('Worker postmaster identity mismatch')
    return str(socket), pg_bin


def interrupted(_signum, _frame):
    raise InterruptedError('Qualification supervisor interrupted')


def supervise():
    """Own one random cluster; stop only after exact directory/process identity checks."""
    pg_bin = Path(os.environ.get('PG_BIN', '/opt/homebrew/opt/postgresql@15/bin')).resolve()
    fault = os.environ.get('VIDEO_QUALIFICATION_FAULT')
    root = Path(tempfile.mkdtemp(prefix='video-qual-', dir='/private/tmp' if Path('/private/tmp').exists() else '/tmp')).resolve()
    socket = Path(tempfile.mkdtemp(prefix='recoup-cases-', dir=root)).resolve()
    cluster = socket / 'pg'; info = socket.stat()
    (root/'fixture-owner.json').write_text(json.dumps({'socket': str(socket), 'cluster': str(cluster),
        'uid': info.st_uid, 'device': info.st_dev, 'inode': info.st_ino, 'worker_pid': os.getpid(), 'pg_bin': str(pg_bin)}))
    (root/'home').mkdir(mode=0o700)
    (root/'tmp').mkdir(mode=0o700)
    env = fixture_environment(root, pg_bin, fault)
    os.environ.clear()
    os.environ.update(env)
    worker = None
    old_handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        export_sources(root, env)
        subprocess.run([str(pg_bin/'initdb'), '-D', str(cluster), '-A', 'trust', '-E', 'UTF8'], env=env, check=True, capture_output=True, timeout=30)
        subprocess.run([str(pg_bin/'pg_ctl'), '-D', str(cluster), '-l', str(root/'postgres.log'), '-w', '-t', '10',
                        '-o', f"-k {socket} -p 55473 -c listen_addresses=''", 'start'], env=env, check=True, capture_output=True, timeout=15)
        worker = subprocess.Popen([str(Path(sys.executable).resolve()), '-I', str(Path(__file__).resolve()), '--worker'], env=env, start_new_session=True)
        metadata_path=root/'fixture-owner.json'
        metadata=json.loads(metadata_path.read_text())
        metadata['worker_group_pid']=worker.pid
        replacement=root/'fixture-owner.next.json'
        replacement.write_text(json.dumps(metadata))
        os.replace(replacement,metadata_path)
        if env.get('VIDEO_QUALIFICATION_FAULT') == 'signal':
            os.kill(os.getpid(), signal.SIGTERM)
        return worker.wait(timeout=.3 if env.get('VIDEO_QUALIFICATION_FAULT') == 'timeout' else 240)
    finally:
        # Ignore repeated termination while bounded cleanup owns the lease.
        for sig in old_handlers: signal.signal(sig, signal.SIG_IGN)
        try:
            if worker:
                print('OWNED_WORKER_CLEANUP '+json.dumps(quiesce_worker(worker)), flush=True)
            outcome = stop_owned_cluster(root, pg_bin, env, os.getpid())
            print('OWNED_CLUSTER_CLEANUP '+json.dumps(outcome), flush=True)
        except BaseException:
            print('PRESERVED_AMBIGUOUS_CLUSTER '+str(root), file=sys.stderr)
            raise
        else:
            shutil.rmtree(root)
            print('OWNED_ROOT_REMOVED '+str(root), flush=True)
        finally:
            for sig, handler in old_handlers.items(): signal.signal(sig, handler)

# Directory/PID-bound cleanup is copied from the pinned source with one receipt correction:
# cluster_created reports actual directory existence for pre-initdb source-export failure.
"""Verify and stop PostgreSQL bound to one registered directory lease."""
import json
import os
import pathlib
import shlex
import signal
import subprocess
import time


def _process_command(pid):
    result = subprocess.run(['/bin/ps', '-ww', '-p', str(pid), '-o', 'command='], capture_output=True, text=True, timeout=5)
    if result.returncode == 1 and not result.stdout.strip():
        return None
    if result.returncode:
        raise RuntimeError('Cannot verify fixture process identity')
    return result.stdout.strip() or None


def _owned_postmasters(cluster):
    # Read process metadata locally; expose only PIDs exactly bound to this lease.
    result = subprocess.run(['/bin/ps', '-ww', '-axo', 'pid=,command='], capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise RuntimeError('Cannot enumerate owned startup processes; preserve root')
    found = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or str(cluster) not in fields[1]:
            continue
        try:
            argv = shlex.split(fields[1])
        except ValueError:
            raise RuntimeError('Ambiguous owned startup process; preserve root')
        if not argv or pathlib.Path(argv[0]).name != 'postgres' or '-D' not in argv or argv[argv.index('-D') + 1] != str(cluster):
            raise RuntimeError('Unquiesced process references owned cluster; preserve root')
        found.append(int(fields[0]))
    return found


def stop_owned_cluster(root, pg_bin, env, worker_pid):
    metadata_path = root / 'fixture-owner.json'
    if not metadata_path.exists():
        if list(root.glob('recoup-cases-*')):
            raise RuntimeError('Unregistered fixture directory; preserve root')
        return {'cluster_created': False, 'socket_absent': True, 'postmaster_absent': True}
    metadata = json.loads(metadata_path.read_text())
    socket = pathlib.Path(metadata['socket'])
    cluster = pathlib.Path(metadata['cluster'])
    if socket.parent != root or socket.resolve() != socket or socket.is_symlink() or cluster != socket / 'pg' or cluster.is_symlink():
        raise RuntimeError('Fixture path ownership mismatch; preserve root')
    info = socket.stat()
    if (info.st_uid, info.st_dev, info.st_ino) != (metadata['uid'], metadata['device'], metadata['inode']) or info.st_uid != os.getuid() or metadata['worker_pid'] != worker_pid:
        raise RuntimeError('Fixture directory identity mismatch; preserve root')
    pidfile = cluster / 'postmaster.pid'
    discovered = _owned_postmasters(cluster)
    if len(discovered) > 1:
        raise RuntimeError('Multiple postmasters bound to lease; preserve root')
    pid = metadata.get('postmaster_pid')
    if pidfile.exists():
        lines = pidfile.read_text().splitlines()
        pid = int(lines[0])
        if pathlib.Path(lines[1]).resolve() != cluster:
            raise RuntimeError('Postmaster data directory mismatch; preserve root')
        if discovered and discovered != [pid]:
            raise RuntimeError('Postmaster PID identity mismatch; preserve root')
        if discovered:
            result = subprocess.run([str(pg_bin / 'pg_ctl'), '-D', str(cluster), '-m', 'immediate', '-w', '-t', '5', 'stop'], env=env, capture_output=True, text=True, timeout=8)
            if result.returncode:
                raise RuntimeError('Parent could not stop owned PostgreSQL: ' + result.stderr)
    elif discovered:
        # A detached postmaster can precede its PID/socket files. Independently
        # bind its command to the exact owned -D path before targeted immediate stop.
        pid = discovered[0]
        if _owned_postmasters(cluster) != [pid]:
            raise RuntimeError('Startup process identity changed; preserve root')
        os.kill(pid, signal.SIGQUIT)
    deadline = time.monotonic() + 8
    while _owned_postmasters(cluster) and time.monotonic() < deadline:
        time.sleep(0.05)
    if _owned_postmasters(cluster) or (pid and _process_command(pid)):
        raise RuntimeError('Recorded postmaster still present; preserve root')
    socket_file = socket / '.s.PGSQL.55473'
    if socket_file.exists():
        raise RuntimeError('Owned PostgreSQL socket still present; preserve root')
    return {'cluster_created': cluster.exists(), 'registered_socket': str(socket), 'registered_cluster': str(cluster),
            'postmaster_pid': pid, 'discovered_postmasters': discovered,
            'postmaster_absent': True, 'socket_absent': True}

# Reviewed group cleanup, with a narrow PermissionError enumeration adaptation; provenance in sources.json.
"""Quiesce only the dedicated fixture worker process group."""
import os
import signal
import subprocess
import time


def _group_exists(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # An actual exited-worker probe was denied by the host. Require independent
        # complete process metadata; never infer absence from a signal denial.
        result = subprocess.run(['/bin/ps', '-axo', 'pgid='], capture_output=True, text=True, timeout=5)
        if result.returncode:
            raise RuntimeError('Cannot enumerate worker groups; preserve owned files')
        groups = result.stdout.splitlines()
        if not groups or any(not line.strip().isascii() or not line.strip().isdigit() for line in groups):
            raise RuntimeError('Invalid worker group enumeration; preserve owned files')
        return group in {int(line.strip()) for line in groups}


def signal_owned_worker_group(group, sig):
    """A signal denial is never absence; require independent bounded absence proof."""
    try:
        os.killpg(group, sig)
    except ProcessLookupError:
        return
    except PermissionError:
        # macOS can deny signaling a just-exited adopted child group. Never
        # ignore a still-present group: wait only for checked enumeration absence.
        deadline = time.monotonic() + 5
        while _group_exists(group) and time.monotonic() < deadline:
            time.sleep(.05)
        if _group_exists(group):
            raise RuntimeError('Cannot signal present owned worker group; preserve owned files')


def quiesce_worker(worker):
    """Signal only the session/group created for this exact Popen child."""
    group = worker.pid  # start_new_session=True establishes PID == PGID == SID.
    if _group_exists(group):
        signal_owned_worker_group(group, signal.SIGTERM)
        try:
            worker.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
    if _group_exists(group):
        signal_owned_worker_group(group, signal.SIGKILL)
    worker.wait(timeout=5)
    deadline = time.monotonic() + 5
    while _group_exists(group) and time.monotonic() < deadline:
        time.sleep(0.05)
    if _group_exists(group):
        raise RuntimeError('Fixture process group not quiescent; preserve owned files')
    return {'worker_pid': worker.pid, 'worker_group_absent': True, 'worker_returncode': worker.returncode}



def quote(value):
    return "'"+str(value).replace("'", "''")+"'"


class SQLFailure(RuntimeError):
    """Only a completed psql command with nonzero exit status."""


class Video(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.socket, cls.bin = verify_worker_lease()
        cls.env = {**fixture_environment(Path(cls.socket).parent, cls.bin), 'PGHOST':cls.socket,
                   'PGPORT':'55473', 'PGDATABASE':'postgres', 'PGOPTIONS':'-c statement_timeout=12000 -c lock_timeout=10000'}
        # The owned cluster only; profiles use separate databases with identical bootstrap.
        cls.sql('CREATE DATABASE video_normal; CREATE DATABASE video_compat;')
        manifest = json.loads((HERE/'sources.json').read_text())
        for profile in ['normal','compatibility']:
            cls.database = 'video_normal' if profile=='normal' else 'video_compat'
            cls.sql((HERE/'qualification-bootstrap.sql').read_text()) if profile=='normal' else cls.sql((HERE/'qualification-bootstrap.sql').read_text().replace('CREATE ROLE service_role BYPASSRLS;','').replace('CREATE ROLE anon;','').replace('CREATE ROLE authenticated;',''))
            for entry in manifest['qualification'][profile+'_prerequisites']:
                cls.sql((Path(cls.socket).parent/'sources'/Path(entry['path']).name).read_text())
            cls.before_definitions = cls.sql("SELECT pg_get_functiondef('public.claim_context_enrichment(uuid,uuid,jsonb)'::regprocedure)||pg_get_functiondef('public.complete_context_enrichment(uuid,uuid,uuid,jsonb)'::regprocedure)")
            cls.sql((HERE/'retained-video.sql').read_text())
            after = cls.sql("SELECT pg_get_functiondef('public.claim_context_enrichment(uuid,uuid,jsonb)'::regprocedure)||pg_get_functiondef('public.complete_context_enrichment(uuid,uuid,uuid,jsonb)'::regprocedure)")
            if after != cls.before_definitions: raise AssertionError('Generic enrichment definitions changed')
            denied = cls.sql("SELECT has_schema_privilege('service_role','context_retained_video_2131','USAGE'),has_function_privilege('service_role','context_retained_video_2131.save_projection(uuid,uuid,uuid,uuid,text,bigint)','EXECUTE')")
            if denied != 'f|f': raise AssertionError('Proposal grants runtime access')
            # Execute actual role denials before fixture-only grants.
            result = cls.execute("SET ROLE service_role; SELECT context_retained_video_2131.read_projection(NULL,NULL,NULL)",check=False)
            if result.returncode==0: raise AssertionError('Default service invocation succeeded')
            cls.sql('GRANT USAGE ON SCHEMA context_retained_video_2131 TO service_role; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA context_retained_video_2131 TO service_role;')
            cls.sql((HERE/'fixtures.sql').read_text())
            regression=(Path(cls.socket).parent/'sources'/'context_video_entry.sql').read_text()
            result=cls.execute('BEGIN;\n'+regression+'\nROLLBACK;')
            if 'PASS: context_video_entry' not in result.stderr: raise AssertionError('Locator fixture did not run')
            if cls.sql('SELECT count(*) FROM public.accounts')!='0': raise AssertionError('Locator rollback not verified')
        cls.database='video_normal'

    @classmethod
    def args(cls):
        return [str(cls.bin/'psql'),'-XqAt','-h',cls.socket,'-p','55473','-d',getattr(cls,'database','postgres'),'-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose']

    @classmethod
    def execute(cls,sql,name='video-test',check=True):
        r=subprocess.run(cls.args(),input=sql,env={**cls.env,'PGAPPNAME':name},capture_output=True,text=True,timeout=18)
        if check and r.returncode: raise SQLFailure(r.stderr)
        return r

    @classmethod
    def sql(cls,sql,name='video-test'):
        return cls.execute(sql,name).stdout.strip()

    def setUp(self):
        self.__class__.database='video_normal'
        self.seed()

    def seed(self):
        self.f=json.loads(self.sql('SELECT video_fixture.seed()'))

    def save_sql(self,key='save',revision=0,**overrides):
        f={**self.f,**overrides}
        return 'SET ROLE service_role; SELECT context_retained_video_2131.save_projection('+','.join(quote(f[k]) for k in ['actor','owner','request','snapshot'])+','+quote(key)+','+str(revision)+');'

    def read_sql(self,**overrides):
        f={**self.f,**overrides}
        return 'SET ROLE service_role; SELECT context_retained_video_2131.read_projection('+','.join(quote(f[k]) for k in ['actor','owner','request'])+');'

    def save(self,**kwargs): return json.loads(self.sql(self.save_sql(**kwargs)))

    def deny(self,sql):
        r=self.execute(sql,check=False)
        self.assertNotEqual(r.returncode,0,r.stdout)
        self.assertEqual(r.stdout.strip(),'')
        return r.stderr

    def mutate(self,expression):
        self.sql("UPDATE public.context_source_versions SET content="+expression+" WHERE id="+quote(self.f['snapshot'])+"; UPDATE public.context_source_versions SET fingerprint=encode(sha256(convert_to(content::text,'UTF8')),'hex') WHERE id="+quote(self.f['snapshot']))

    def counts(self):
        return self.sql("SELECT jsonb_build_array((SELECT count(*) FROM public.context_attempts),(SELECT count(*) FROM public.context_results),(SELECT count(*) FROM public.context_documents),(SELECT count(*) FROM public.context_result_sources),(SELECT count(*) FROM public.context_sources),(SELECT count(*) FROM public.context_source_versions))")

    def test_roundtrip_replay_lineage_and_both_profiles(self):
        for database in ['video_normal','video_compat']:
            with self.subTest(database=database):
                self.__class__.database=database;self.seed()
                source_before=self.sql('SELECT jsonb_agg(id ORDER BY id) FROM public.context_source_versions')
                locator_before=self.sql("SELECT to_jsonb(d) FROM public.context_documents d WHERE topic='video_locator'")
                saved=self.save(); counts=self.counts()
                self.assertEqual(saved['evidence'],self.f['evidence'])
                self.assertEqual(saved,json.loads(self.sql(self.read_sql())))
                self.assertEqual(saved,self.save());self.assertEqual(counts,self.counts())
                self.assertEqual(source_before,self.sql('SELECT jsonb_agg(id ORDER BY id) FROM public.context_source_versions'))
                self.assertEqual(locator_before,self.sql("SELECT to_jsonb(d) FROM public.context_documents d WHERE topic='video_locator'"))
                self.assertEqual('t',self.sql("SELECT provider_cost_micros IS NULL AND provider_cost_status='unknown' AND settlement_reference IS NULL FROM public.context_attempts WHERE id="+quote(saved['attemptId'])))
                self.assertEqual(sorted([self.f['snapshot'],self.f['version']]),json.loads(self.sql('SELECT jsonb_agg(source_version_id ORDER BY source_version_id) FROM public.context_result_sources WHERE result_id='+quote(saved['resultId']))))
                self.assertEqual('0',self.sql("SELECT count(*) FROM public.context_documents WHERE topic NOT IN ('video_locator','video_narrative')"))
                self.deny(self.save_sql(revision=1));self.assertEqual(counts,self.counts())
                self.deny(self.save_sql(key='late',revision=0));self.assertEqual(counts,self.counts())
                module={'fingerprint':'a'*64,'subjectId':self.f['subject'],'topic':'video_narrative','evidenceKind':'interpretation'}
                self.deny('SET ROLE service_role; SELECT public.claim_context_enrichment('+quote(self.f['owner'])+','+quote(self.f['request'])+','+quote(json.dumps(module))+'::jsonb)')
                self.assertEqual(counts,self.counts())

    def test_withdrawal_removed_and_identity_lifecycle(self):
        changes=["SELECT public.withdraw_context_source({owner},{dependency})", "UPDATE public.context_source_versions SET removed_at=now() WHERE id={version}",
          "UPDATE public.context_resource_links SET status='rejected' WHERE id={link}","UPDATE public.context_resource_links SET status='candidate' WHERE id={link}","UPDATE public.context_resource_links SET status='conflict' WHERE id={link}","DELETE FROM public.context_resource_links WHERE id={link}",
          "UPDATE public.context_resources SET provider_id='OtherIdAB_2' WHERE id={resource}","UPDATE public.context_requests SET status='cancelled' WHERE id={request}","DELETE FROM public.account_organization_ids WHERE account_id={actor}"]
        for change in changes:
            with self.subTest(change=change):
                self.seed();self.save();self.sql(change.format(**{k:quote(v) for k,v in self.f.items() if k!='evidence'}));counts=self.counts()
                self.deny(self.read_sql());self.deny(self.save_sql());self.deny(self.save_sql(key='new',revision=1));self.assertEqual(counts,self.counts())
        self.seed();self.save()
        self.sql('UPDATE public.context_resource_links SET id=gen_random_uuid() WHERE id='+quote(self.f['link']))
        self.deny(self.read_sql());self.deny(self.save_sql())

    def test_scope_and_source_rejections(self):
        for args in [dict(actor=self.f['outsider']),dict(owner=self.f['outsider']),dict(request='20000000-0000-4000-8000-000000000000'),dict(snapshot=self.f['version'])]:
            before=self.counts();self.deny(self.save_sql(**args));self.assertEqual(before,self.counts())
        for change in ["UPDATE public.context_source_versions SET media_manifest='{{}}' WHERE id={version}",
                       "UPDATE public.context_source_versions SET retrieved_at=retrieved_at+interval '1 second' WHERE id={version}",
                       "UPDATE public.context_source_versions SET content=NULL WHERE id={version}"]:
            self.seed();self.sql(change.format(**{k:quote(v) for k,v in self.f.items() if k!='evidence'}));before=self.counts();self.deny(self.save_sql());self.assertEqual(before,self.counts())

    def test_envelope_negative_matrix(self):
        expressions=["content||'{\"extra\":true}'", "content-'title'", "jsonb_set(content,'{identity}','{\"state\":\"matched\"}')",
         "jsonb_set(content,'{title}','null')", "jsonb_set(content,'{title}',to_jsonb(repeat(' ',4)))", "jsonb_set(content,'{title}',to_jsonb(chr(8203)))",
         "jsonb_set(content,'{title}',to_jsonb(chr(7)))", "jsonb_set(content,'{title}',to_jsonb(repeat('🎵',2001)))",
         "jsonb_set(content,'{description}',to_jsonb(repeat('a',20001)))", "jsonb_set(content,'{durationSeconds}','0')",
         "jsonb_set(content,'{captions,segments,0,endSeconds}','121')", "jsonb_set(content,'{captions,segments,0,endSeconds}','0')",
         "jsonb_set(content,'{captions,segments,0,startSeconds}','-1')", "jsonb_set(content,'{captions,segments,0,text}','\"\"')",
         "jsonb_set(content,'{sources}',(content->'sources')||(content->'sources'->0))", "jsonb_set(content,'{sources}','[]')",
         "jsonb_set(content,'{sources,1,mediaVersion}','\"wrong\"')", "jsonb_set(content,'{performers,0,sourceVersionIds}','[]')",
         "jsonb_set(content,'{performers,0,sourceVersionIds}',jsonb_build_array(gen_random_uuid()))",
         "jsonb_set(content,'{ownerId}',to_jsonb(gen_random_uuid()))", "jsonb_set(content,'{videoSubjectId}',to_jsonb(gen_random_uuid()))",
         "jsonb_set(content,'{analysis}','{\"state\":\"unavailable\",\"reason\":\"ok\",\"extra\":1}')"]
        for expression in expressions:
            with self.subTest(expression=expression):
                self.seed();self.mutate(expression);before=self.counts();self.deny(self.save_sql());self.assertEqual(before,self.counts())
        self.seed();self.mutate("jsonb_set(jsonb_set(content,'{title}',to_jsonb(repeat('🎵',2000))),'{captions}','{\"state\":\"missing\",\"reason\":\"Not retained\"}')")
        self.assertEqual('missing',self.save()['evidence']['captions']['state'])

    def holder(self,sql):
        import select
        p=subprocess.Popen(self.args(),env={**self.env,'PGAPPNAME':'video-holder'},stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        p.stdin.write('BEGIN;'+sql+"SELECT 'held';\n");p.stdin.flush()
        deadline=time.monotonic()+14;output=''
        while time.monotonic()<deadline:
            if select.select([p.stdout],[],[],.1)[0]:
                output+=os.read(p.stdout.fileno(),65536).decode()
                if 'held' in output.splitlines(): return p
                if p.poll() is not None: break
        p.kill();_,error=p.communicate(timeout=5);raise AssertionError(output+error)

    def race(self,held,waiting):
        p=self.holder(held)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future=pool.submit(self.sql,waiting,'video-waiter')
            try:
                deadline=time.monotonic()+6
                while time.monotonic()<deadline:
                    blocked=self.sql("SELECT count(*) FROM pg_stat_activity w JOIN pg_stat_activity h ON h.pid=ANY(pg_blocking_pids(w.pid)) WHERE w.application_name='video-waiter' AND h.application_name='video-holder'")
                    if blocked=='1':break
                    if future.done():
                        outcome=future.exception() or future.result()
                        raise AssertionError('Waiter finished without observed blocker: '+str(outcome))
                    time.sleep(.02)
                else:raise AssertionError('No actual blocking PID observed')
            finally:
                p.stdin.write('COMMIT;\n');p.stdin.flush();p.stdin.close();p.stdin=None
                _,error=p.communicate(timeout=15);self.assertEqual(p.returncode,0,error)
            return future.result(timeout=15)

    def test_locator_two_connection_both_orders_all_operations(self):
        for mutation in ["UPDATE public.context_resource_links SET status='rejected' WHERE id=",'DELETE FROM public.context_resource_links WHERE id=']:
            for operation in ['save','read','replay']:
                for first in ['operation','rejection']:
                    with self.subTest(mutation=mutation,operation=operation,first=first):
                        self.seed()
                        if operation!='save':self.save()
                        op=self.read_sql() if operation=='read' else self.save_sql()
                        change=mutation+quote(self.f['link'])+';'
                        if first=='operation':self.race(op,change)
                        else:
                            before=self.counts()
                            with self.assertRaisesRegex(SQLFailure,'42501'):self.race(change,op)
                            self.assertEqual(before,self.counts())
                        self.deny(self.read_sql());self.deny(self.save_sql())

    def test_concurrent_replay_cas_revocation_withdrawal_cancellation(self):
        self.race(self.save_sql(),self.save_sql());self.assertEqual('1',self.sql("SELECT count(*) FROM public.context_results WHERE topic='video_narrative'"))
        self.seed()
        with self.assertRaisesRegex(SQLFailure,'40001.*revision conflict'):self.race(self.save_sql(),self.save_sql(key='second'))
        for change in ["DELETE FROM public.account_organization_ids WHERE account_id={actor};", "SELECT public.withdraw_context_source({owner},{dependency});", "UPDATE public.context_requests SET status='cancelled' WHERE id={request};", "UPDATE public.context_resources SET provider_id='OtherIdAB_2' WHERE id={resource};"]:
            self.seed();sql=change.format(**{k:quote(v) for k,v in self.f.items() if k!='evidence'})
            self.race(self.save_sql(),sql);self.deny(self.read_sql())
            self.seed();sql=change.format(**{k:quote(v) for k,v in self.f.items() if k!='evidence'})
            with self.assertRaisesRegex(SQLFailure,'42501'):self.race(sql,self.save_sql())

    def test_cross_request_and_fault_rollback(self):
        saved=self.save()
        req=json.loads(self.sql('SELECT public.create_context_video_request('+quote(self.f['owner'])+','+quote(self.f['actor'])+",'AbCdEfGhI_1','second')"))
        self.deny(self.read_sql(request=req['id']));self.deny(self.save_sql(request=req['id']))
        for table in ['context_documents','context_attempts','context_results','context_result_sources']:
            self.seed();before=self.counts()
            self.sql('CREATE TRIGGER fail_write AFTER INSERT ON public.'+table+' FOR EACH ROW EXECUTE FUNCTION video_fixture.raise_fault()')
            try:self.assertIn('fixture write fault',self.deny(self.save_sql()));self.assertEqual(before,self.counts())
            finally:self.sql('DROP TRIGGER fail_write ON public.'+table)


    def test_strict_uuid_cf_analysis_and_replay_lineage(self):
        for expr in ["jsonb_set(content,'{ownerId}',to_jsonb(replace(content->>'ownerId','-','')))",
                     "jsonb_set(content,'{sources,0,versionId}',to_jsonb('{'||(content->'sources'->0->>'versionId')||'}'))",
                     "jsonb_set(content,'{title}',to_jsonb(chr(1536)))",
                     "jsonb_set(content,'{sources,0,retrievedAt}','\"2026-11-17T24:00:00Z\"')",
                     "jsonb_set(content,'{sources,0,retrievedAt}','\"2026-11-17T23:59:60Z\"')",
                     "jsonb_set(content,'{sources,0,retrievedAt}','\"2026-11-18T00:00:00.0000001Z\"')"]:
            self.seed();self.mutate(expr);self.assertIn('22023',self.deny(self.save_sql()))
        self.seed()
        analysis={'state':'available','sourceVersionIds':[self.f['version']], 'ranges':[{'startSeconds':0,'endSeconds':10,'observations':['Retained observation'],'interpretation':'Bounded interpretation'}]}
        self.mutate("jsonb_set(content,'{analysis}',"+quote(json.dumps(analysis))+"::jsonb)")
        saved=self.save();self.assertEqual(analysis,saved['evidence']['analysis']);self.assertEqual(saved,json.loads(self.sql(self.read_sql())))
        for mutation in ["DELETE FROM public.context_result_sources WHERE result_id={result} AND source_version_id={version}",
                         "UPDATE public.context_results SET normalized_response='{{}}' WHERE id={result}"]:
            self.seed();saved=self.save()
            self.sql(mutation.format(result=quote(saved['resultId']),version=quote(self.f['version'])))
            self.assertIn('42501',self.deny(self.read_sql()));self.assertIn('42501',self.deny(self.save_sql()))

    def test_missing_foreign_versions_subject_lock_and_supersession(self):
        self.sql('DELETE FROM public.context_source_versions WHERE id='+quote(self.f['version']))
        self.assertIn('42501',self.deny(self.save_sql()))
        self.seed()
        # Real foreign-owner source/version rows replace the referenced dependency.
        self.sql('DELETE FROM public.context_source_versions WHERE id='+quote(self.f['version'])+'; INSERT INTO public.context_sources(id,owner_id,kind) VALUES(gen_random_uuid(),'+quote(self.f['outsider'])+",'provider_metadata'); INSERT INTO public.context_source_versions(id,owner_id,source_id,fingerprint,content) SELECT "+quote(self.f['version'])+','+quote(self.f['outsider'])+",id,repeat('b',64),'{}' FROM public.context_sources WHERE owner_id="+quote(self.f['outsider']))
        self.assertIn('42501',self.deny(self.save_sql()))
        for first in ['operation','mutation']:
            self.seed()
            # A no-op still obtains UPDATE row locks, proving the subject lock exists.
            change='UPDATE public.context_subjects SET resource_id=resource_id WHERE id='+quote(self.f['subject'])+';'
            if first=='operation':self.race(self.save_sql(),change)
            else:self.race(change,self.save_sql())
        self.seed();original=self.save()
        replacement=self.save_sql(key='new',revision=1)
        self.race(self.read_sql(),replacement)
        self.assertNotEqual(original['resultId'],json.loads(self.sql(self.read_sql()))['resultId'])
        self.assertIn('42501',self.deny(self.save_sql()))

    def test_source_count_and_exact_byte_boundaries(self):
        # Add real retained rows, preserving the same owner/request/media binding.
        for n in [30,31]:
            self.seed()
            self.sql("INSERT INTO public.context_source_versions(owner_id,source_id,fingerprint,content,media_manifest,retrieved_at) SELECT owner_id,source_id,encode(sha256(convert_to(n::text,'UTF8')),'hex'),jsonb_build_object('observation',n),media_manifest,retrieved_at FROM public.context_source_versions CROSS JOIN generate_series(1,"+str(n)+") n WHERE id="+quote(self.f['version']))
            self.mutate("jsonb_set(content,'{sources}',(SELECT jsonb_agg(jsonb_build_object('versionId',v.id,'videoId','AbCdEfGhI_1','mediaVersion','upload-1','retrievedAt','2026-11-18T00:00:00Z') ORDER BY v.id) FROM public.context_source_versions v WHERE v.media_manifest ? 'contextVideo'))")
            if n==30:self.assertEqual(32,len(self.save()['evidence']['sources']))
            else:self.assertIn('22023',self.deny(self.save_sql()))
        self.seed()
        analysis={'state':'available','sourceVersionIds':[self.f['version']], 'ranges':[{'startSeconds':0,'endSeconds':10,'observations':['a']*11,'interpretation':'Known'} for _ in range(100)]}
        self.mutate("jsonb_set(content,'{analysis}',"+quote(json.dumps(analysis))+"::jsonb)")
        base=int(self.sql('SELECT octet_length(content::text) FROM public.context_source_versions WHERE id='+quote(self.f['snapshot'])))
        remaining=4194304-base
        for row in analysis['ranges']:
            for i in range(11):
                added=min(3999,remaining);row['observations'][i]='a'*(1+added);remaining-=added
        self.assertEqual(remaining,0)
        self.mutate("jsonb_set(content,'{analysis}',"+quote(json.dumps(analysis))+"::jsonb)")
        self.assertEqual('4194304',self.sql('SELECT octet_length(content::text) FROM public.context_source_versions WHERE id='+quote(self.f['snapshot'])))
        self.assertEqual('saved',self.save()['state'])
        # One ASCII byte in description changes only total size, within per-field bounds.
        self.mutate("jsonb_set(content,'{description}',to_jsonb((content->>'description')||'x'))")
        self.assertIn('22023',self.deny(self.save_sql(key='oversize',revision=1)))

    def test_numeric_video_id_and_upper_count_limits(self):
        self.sql("UPDATE public.context_resources SET provider_id='12345678901' WHERE id="+quote(self.f['resource'])+"; UPDATE public.context_requests SET input=jsonb_set(input,'{videoId}','\"12345678901\"') WHERE id="+quote(self.f['request'])+"; UPDATE public.context_source_versions SET media_manifest=jsonb_set(media_manifest,'{contextVideo,videoId}','\"12345678901\"') WHERE media_manifest ? 'contextVideo'")
        self.mutate("jsonb_set(jsonb_set(jsonb_set(content,'{videoId}','12345678901'),'{sources,0,videoId}','12345678901'),'{sources,1,videoId}','12345678901')")
        self.assertIn('22023',self.deny(self.save_sql()))
        self.seed()
        for path,count,item in [('performers',51,self.f['evidence']['performers'][0]),('captions.segments',501,self.f['evidence']['captions']['segments'][0])]:
            self.seed();self.mutate("jsonb_set(content,"+quote('{'+path.replace('.',',')+'}')+','+quote(json.dumps([item]*count))+"::jsonb)")
            self.assertIn('22023',self.deny(self.save_sql()))

    def test_signal_denial_never_substitutes_for_group_absence(self):
        from unittest.mock import patch
        with patch.object(os,'killpg',side_effect=PermissionError('synthetic')):
            with patch.dict(globals(),{'_group_exists':lambda group:False}):
                signal_owned_worker_group(4242,signal.SIGKILL)
            with patch.dict(globals(),{'_group_exists':lambda group:True}):
                with patch.object(time,'monotonic',side_effect=[0,6]):
                    with self.assertRaisesRegex(RuntimeError,'present owned worker group'):
                        signal_owned_worker_group(4242,signal.SIGKILL)
        # The enumeration fallback itself must reject failed or malformed output.
        with patch.object(os,'killpg',side_effect=PermissionError('synthetic')):
            for code,stdout in [(1,''),(0,''),(0,'not-a-group')]:
                with patch.object(subprocess,'run',return_value=subprocess.CompletedProcess([],code,stdout,'')):
                    with self.assertRaises(RuntimeError):_group_exists(4242)

    def test_browser_roles_and_poison_environment(self):
        for role in ['anon','authenticated']:
            self.deny('SET ROLE '+role+'; SELECT context_retained_video_2131.read_projection(NULL,NULL,NULL)')
        self.assertEqual('UTF8',self.sql('SHOW server_encoding'))
        forbidden=['PGSERVICE','PGSERVICEFILE','PGPASSWORD','PGPASSFILE','DATABASE_URL','SUPABASE_SERVICE_ROLE_KEY','DYLD_INSERT_LIBRARIES','LD_PRELOAD','PYTHONPATH','GIT_CONFIG_GLOBAL']
        for name in forbidden:self.assertNotIn(name,os.environ)
        root=Path(self.socket).parent
        self.assertEqual(str(root/'home'),os.environ['HOME'])
        self.assertEqual(str(root/'tmp'),os.environ['TMPDIR'])
        from unittest.mock import patch
        with patch.dict(os.environ,{name:'synthetic-poison' for name in forbidden}):
            clean=fixture_environment(root,self.bin)
            observed=subprocess.run([sys.executable,'-I','-c','import os,json;print(json.dumps(dict(os.environ)))'],env=clean,capture_output=True,text=True,check=True,timeout=5)
        child=json.loads(observed.stdout)
        for name in forbidden:self.assertNotIn(name,child)
        self.assertEqual(str(root/'home'),child['HOME'])


if __name__ == '__main__':
    if sys.argv[1:] == ['--worker']:
        socket, pg_bin = prepare_worker_environment()
        fault = os.environ.get('VIDEO_QUALIFICATION_FAULT')
        if fault == 'timeout': time.sleep(30)
        if fault == 'worker-exit':
            subprocess.Popen([str(pg_bin/'psql'), '-XqAt', '-h', socket, '-p', '55473', '-d', 'postgres', '-c', 'SELECT pg_sleep(30)'], env=fixture_environment(Path(socket).parent, pg_bin))
            time.sleep(.1)
            raise SystemExit(86)
        unittest.main(argv=[sys.argv[0]], verbosity=2)
    elif len(sys.argv) == 1:
        raise SystemExit(supervise())
    else:
        raise SystemExit('No connection strings or external targets accepted')
