"""New parent transactions only. Parent owns Unix cluster; no hosted DSN accepted."""
import hashlib
import importlib.util
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
S = 'application_registration_proposal'
A = '00000000-0000-0000-0000-000000000001'
B = '00000000-0000-0000-0000-000000000002'

def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def payload():
    return {'name': 'Music', 'origins': [
        {'origin': 'https://music.example', 'hostname': 'music.example',
         'return_urls': ['https://music.example/return']},
        {'origin': 'https://preview.example', 'hostname': 'preview.example', 'return_urls': []}]}


class Registration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.socket, cls.bin = verify_worker_lease()
        clean_env = fixture_environment(Path(cls.socket).parent, cls.bin)
        cls.env = {**clean_env, 'PGHOST': cls.socket, 'PGPORT': '55473', 'PGDATABASE': 'postgres',
                   'PGOPTIONS': '-c statement_timeout=10000 -c lock_timeout=8000'}
        for filename in ['qualification-bootstrap.sql', 'parents.sql', 'registration.sql']:
            cls.sql((HERE / filename).read_text())
        spec = importlib.util.spec_from_file_location('composition', HERE / 'protocol-composition.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cls.sql(module.compose())
        cls.sql('CREATE ROLE qualification_browser NOLOGIN;')

    @classmethod
    def args(cls):
        return [str(cls.bin / 'psql'), '-XqAt', '-v', 'ON_ERROR_STOP=1']

    @classmethod
    def sql(cls, sql, name='registration-test'):
        r = subprocess.run(cls.args(), input=sql, env={**cls.env, 'PGAPPNAME': name},
                           capture_output=True, text=True, timeout=15)
        if r.returncode:
            raise AssertionError(r.stderr)
        return r.stdout.strip()

    def setUp(self):
        self.sql(f'TRUNCATE {S}.personal_principals CASCADE;')
        self.sql(f"INSERT INTO {S}.personal_principals(account_id) VALUES ('{A}'),('{B}');")
        self.sql(f"INSERT INTO {S}.create_entitlements(actor,workspace_id,environment) "
                 f"SELECT account_id,account_id,e FROM {S}.personal_principals CROSS JOIN "
                 "unnest(ARRAY['production','development']) e;")

    def statement(self, actor=A, workspace=A, env='production', key='create', rev=1, body=None):
        args = [quote(actor), quote(workspace), quote(env), quote(key), str(rev),
                quote(json.dumps(payload() if body is None else body)) + '::jsonb']
        return f"SELECT {S}.register_application(" + ','.join(args) + ');'

    def create(self, **kw):
        return json.loads(self.sql(self.statement(**kw)))

    def deny(self, sql, message='authority unavailable'):
        with self.assertRaisesRegex(AssertionError, message):
            self.sql(sql)

    def grant_management(self, app, ops, actor=A, env='production'):
        self.sql(f"INSERT INTO {S}.management_entitlements(actor,workspace_id,application_id,environment,operation) "
                 f"SELECT '{actor}','{actor}',{quote(app)},{quote(env)},op FROM unnest(ARRAY[" +
                 ','.join(quote(x) for x in ops) + ']) op;')

    def proof(self, app, operation='issue', key='proof', revisions=(1, 1, 1), data=None, **kw):
        values = [kw.get('actor', A), kw.get('workspace', A), app, kw.get('env', 'production'),
                  'https://music.example', operation, key]
        return 'SELECT application_proof_proposal.transact(' + ','.join(quote(x) for x in values) + ',' + \
            ','.join(str(x) for x in revisions) + ',' + quote(json.dumps(data or {'digest': 'a' * 64})) + '::jsonb);'

    def read_receipt(self, r, **kw):
        return f"SELECT {S}.read_registration(" + ','.join(quote(x) for x in [
            kw.get('actor', A), kw.get('workspace', A), kw.get('app', r['application_id']),
            kw.get('env', 'production'), r['receipt_id']]) + ');'

    def test_create_disabled_isolated_and_no_implicit_management(self):
        r = self.create()
        for flag in ['origins_verified', 'bootstrap_enabled', 'access_activated', 'runtime_enabled', 'production_persisted']:
            self.assertIs(r[flag], False)
        self.assertEqual(r['policy_status'], 'proposed_unadopted')
        self.assertEqual(r['billing_owner_id'], A)
        self.assertEqual(r['snapshot']['allowed_origins'], [x['origin'] for x in payload()['origins']])
        self.assertEqual(self.sql(f'SELECT count(*) FROM {S}.management_entitlements'), '0')
        self.deny(self.proof(r['application_id']))
        self.deny(self.read_receipt(r))
        other = self.create(actor=B, workspace=B)
        dev = self.create(env='development', key='dev')
        self.assertEqual(len({r['application_id'], other['application_id'], dev['application_id']}), 3)
        self.assertEqual(self.sql(f'SELECT count(*) FROM {S}.environments'), '3')

    def test_denial_actor_workspace_environment_operation_personal_classification(self):
        for kw in [{'actor': B}, {'workspace': B}, {'env': 'staging'}]:
            self.deny(self.statement(**kw), 'authority unavailable|invalid input')
        self.sql(f"DELETE FROM {S}.create_entitlements WHERE actor='{A}'")
        self.deny(self.statement())
        self.sql(f"UPDATE {S}.personal_principals SET enabled=false WHERE account_id='{B}'")
        self.deny(self.statement(actor=B, workspace=B))
        self.deny(self.statement(actor='00000000-0000-0000-0000-000000000099', workspace='00000000-0000-0000-0000-000000000099'))

    def test_revision_changed_key_lost_response_replay_and_revoked_replay(self):
        self.deny(self.statement(rev=2), 'revision conflict')
        r = self.create()
        self.assertEqual(self.create(), r)
        for kw in [{'rev': 2}, {'body': {**payload(), 'name': 'Changed'}}, {'env': 'development'}]:
            self.deny(self.statement(**kw), 'idempotency conflict')
        self.sql(f"UPDATE {S}.create_entitlements SET revision=2 WHERE actor='{A}'")
        self.assertEqual(self.create(), r)  # current authority, original exact input/history
        self.deny(self.statement(key='new'), 'revision conflict')
        self.sql(f"UPDATE {S}.create_entitlements SET enabled=false WHERE actor='{A}'")
        self.deny(self.statement())
        self.assertEqual(self.sql(f'SELECT count(*) FROM {S}.applications'), '1')
        self.deny(f"UPDATE {S}.receipts SET result='{{}}'::jsonb", 'immutable')
        self.deny(f'DELETE FROM {S}.requests', 'immutable')

    def test_receipt_read_binding_and_current_authority(self):
        r = self.create()
        other = self.create(key='other')
        self.grant_management(r['application_id'], ['read_registration'])
        self.assertEqual(json.loads(self.sql(self.read_receipt(r))), r)
        for kw in [{'actor': B}, {'workspace': B}, {'env': 'development'}, {'app': other['application_id']}]:
            self.deny(self.read_receipt(r, **kw))
        self.sql(f'UPDATE {S}.management_entitlements SET enabled=false')
        self.deny(self.read_receipt(r))

    def test_explicit_and_mid_parent_failure_rollback(self):
        self.sql('BEGIN;' + self.statement() + 'ROLLBACK;')
        self.assertEqual(self.sql(f'SELECT count(*) FROM {S}.applications'), '0')
        self.sql(f"""CREATE FUNCTION qualification_auth.fail_origin() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN IF NEW.origin='https://preview.example' THEN RAISE EXCEPTION 'forced second origin failure'; END IF; RETURN NEW; END $$;
        CREATE TRIGGER fail_second BEFORE INSERT ON {S}.origins FOR EACH ROW EXECUTE FUNCTION qualification_auth.fail_origin();""")
        try:
            self.deny(self.statement(), 'forced second origin')
            for table in ['applications', 'environments', 'origins', 'receipts', 'requests']:
                self.assertEqual(self.sql(f'SELECT count(*) FROM {S}.{table}'), '0')
        finally:
            self.sql(f'DROP TRIGGER fail_second ON {S}.origins; DROP FUNCTION qualification_auth.fail_origin();')

    def test_input_bounds_and_no_invented_authority_fields(self):
        for body in [{}, {**payload(), 'actor': A}, {**payload(), 'name': ''},
                     {**payload(), 'origins': []},
                     {**payload(), 'origins': [payload()['origins'][0]] * 2},
                     {**payload(), 'origins': [{**payload()['origins'][0], 'hostname': 'other.example'}]},
                     {**payload(), 'origins': [{**payload()['origins'][0], 'return_urls': ['https://evil.example/']}]}]:
            self.deny(self.statement(body=body), 'invalid')
        self.deny('BEGIN ISOLATION LEVEL REPEATABLE READ;' + self.statement(), 'read committed')

    def test_no_public_table_or_helper_privileges(self):
        for schema in [S, 'application_proof_proposal']:
            self.assertEqual(self.sql(f"SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid WHERE n.nspname={quote(schema)} AND has_function_privilege('qualification_browser',p.oid,'EXECUTE')"), '0')
            self.assertEqual(self.sql(f"SELECT count(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace=n.oid WHERE n.nspname={quote(schema)} AND c.relkind='r' AND has_table_privilege('qualification_browser',c.oid,'SELECT,INSERT,UPDATE,DELETE')"), '0')
        self.deny('SET ROLE qualification_browser;' + self.statement(), 'permission denied')
        self.deny(f"SET ROLE qualification_browser; SELECT {S}.authorize_create('{A}','{A}','production');", 'permission denied')

    def test_database_encoding_is_utf8(self):
        self.assertEqual(self.sql('SHOW server_encoding'), 'UTF8')
        self.assertEqual(self.create(body={**payload(), 'name': 'Música 音楽'})['snapshot']['name'], 'Música 音楽')

    def test_minimal_owned_environment_drops_synthetic_poison(self):
        from unittest.mock import patch
        socket = Path(self.socket)
        poison = {key: 'synthetic-poison-do-not-forward' for key in [
            'UNRELATED_SERVICE_SECRET', 'PGSERVICE', 'PGSERVICEFILE', 'PGPASSWORD',
            'PGPASSFILE', 'PGHOSTADDR', 'PYTHONPATH', 'PYTHONHOME', 'LD_PRELOAD',
            'DYLD_INSERT_LIBRARIES', 'NODE_OPTIONS', 'ENV', 'BASH_ENV']}
        with patch.dict(os.environ, poison):
            clean = fixture_environment(socket.parent, self.bin)
        self.assertTrue(set(poison).isdisjoint(clean))
        self.assertTrue(set(poison).isdisjoint(os.environ))
        self.assertEqual(clean['HOME'], str(socket.parent/'home'))
        self.assertEqual(clean['TMPDIR'], str(socket.parent/'tmp'))
        self.assertEqual(os.environ['HOME'], clean['HOME'])
        self.assertEqual(self.env['HOME'], clean['HOME'])
        self.assertEqual(self.env['PGHOST'], self.socket)
        self.assertEqual(set(self.env)-set(clean), {'PGHOST','PGPORT','PGDATABASE','PGOPTIONS'})
        probe = subprocess.run([str(Path(sys.executable).resolve()), '-I', '-c',
            'import json,os; print(json.dumps(dict(os.environ),sort_keys=True))'],
            env=clean, capture_output=True, text=True, check=True, timeout=5)
        actual = json.loads(probe.stdout)
        # macOS CoreFoundation may synthesize this runtime encoding entry after exec.
        self.assertLessEqual(set(actual)-set(clean), {'__CF_USER_TEXT_ENCODING'})
        self.assertTrue(set(poison).isdisjoint(actual))
        self.assertEqual({key: actual[key] for key in clean}, clean)

    def test_direct_remote_worker_target_rejected_before_sql(self):
        r = subprocess.run([str(Path(sys.executable).resolve()), '-I', str(Path(__file__).resolve()), '--worker'],
            env={**os.environ, 'REGISTRATION_QUALIFICATION_SOCKET': 'example.invalid', 'PGPASSWORD': 'synthetic-unusable'},
            capture_output=True, text=True, timeout=5)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Owned absolute Unix socket directory required', r.stderr)
        self.assertNotIn('synthetic-unusable', r.stderr)

    def test_synthetic_auth_boundary_not_a_database_credential_verifier(self):
        self.assertEqual(self.sql("SELECT qualification_auth.original_actor('current-key')"), A)
        for token in ['missing', 'revoked-key', 'wrong-actor-key', 'changed-key']:
            self.deny(f"SELECT qualification_auth.original_actor({quote(token)})", 'verification unavailable')
        # Only the qualification stub has credential observations; proposed tables store none.
        self.assertEqual(self.sql(f"SELECT count(*) FROM information_schema.columns WHERE table_schema='{S}' AND column_name ~ '(token|credential|key_hash)'"), '0')

    def test_composition_issue_configure_cas_and_disabled_history(self):
        r = self.create(); app = r['application_id']
        self.grant_management(app, ['issue', 'read', 'replace_existing_origin_return_urls'])
        issued = json.loads(self.sql(self.proof(app)))
        expected = json.loads(self.sql(f"SELECT application_proof_proposal.configuration_snapshot('{A}',{quote(app)},'production')"))
        changes = [{'origin': 'https://music.example', 'expected': {'config_revision': 1, 'proof_revision': 1, 'cas_revision': 2},
                    'next': {'config_revision': 2, 'proof_revision': 1, 'cas_revision': 3}, 'return_urls': ['https://music.example/new']}]
        stmt = f"SELECT application_proof_proposal.configure_return_urls('{A}','{A}',{quote(app)},'production','config',{quote(json.dumps(expected))}::jsonb,{quote(json.dumps(changes))}::jsonb);"
        configured = json.loads(self.sql(stmt)); self.assertEqual(json.loads(self.sql(stmt)), configured)
        self.assertFalse(configured['access_activated']); self.assertFalse(configured['bootstrap_enabled'])
        self.assertEqual(self.sql('SELECT state FROM application_proof_proposal.challenges WHERE id='+quote(issued['challenge_id'])), 'superseded')
        self.deny(stmt.replace("'config'", "'different'"), 'snapshot conflict')
        for kw in [{'env': 'development'}, {'workspace': B}, {'actor': B}]:
            self.deny(self.proof(app, **kw))
        self.deny(self.proof(app, key='stale'), 'revision conflict')

    def holder(self, sql):
        p = subprocess.Popen(self.args(), env={**self.env, 'PGAPPNAME': 'registration-holder'},
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        p.stdin.write('BEGIN;'+sql+"SELECT 'held';\n"); p.stdin.flush()
        # Reading marker is bounded by PostgreSQL statement_timeout and select readiness.
        import select
        deadline = time.monotonic()+12
        output = ''
        while time.monotonic()<deadline:
            if select.select([p.stdout], [], [], .1)[0]:
                line = os.read(p.stdout.fileno(), 65536).decode(); output += line
                if 'held' in output.splitlines(): return p
                if p.poll() is not None: break
        p.kill(); _, err = p.communicate(timeout=5)
        raise AssertionError('holder failed: '+output+err)

    def wait_locked(self):
        deadline = time.monotonic()+5
        while time.monotonic()<deadline:
            if self.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='registration-waiter' AND wait_event_type='Lock'") == '1':
                return
            time.sleep(.02)
        raise AssertionError('No actual PostgreSQL lock wait observed')

    def release(self, p):
        p.stdin.write('COMMIT;\n'); p.stdin.flush(); p.stdin.close(); p.stdin = None
        out, err = p.communicate(timeout=12)
        self.assertEqual(p.returncode, 0, err)
        return out

    def race(self, held, waiting, before_release=None):
        p = self.holder(held)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(self.sql, waiting, 'registration-waiter')
            try:
                self.wait_locked()
                if before_release: before_release()
            finally:
                self.release(p)
            return future.result(timeout=12)

    def test_concurrent_exact_replay_creates_once(self):
        result = json.loads(self.race(self.statement(), self.statement()))
        self.assertEqual(result, self.create())
        self.assertEqual(self.sql(f'SELECT count(*) FROM {S}.applications'), '1')

    def test_revocation_first_denies_waiting_create(self):
        with self.assertRaisesRegex(AssertionError, 'authority unavailable'):
            self.race(f"UPDATE {S}.create_entitlements SET enabled=false,revision=revision+1 WHERE actor='{A}';", self.statement())
        self.assertEqual(self.sql(f'SELECT count(*) FROM {S}.applications'), '0')

    def test_create_first_revocation_waits_then_replay_denies(self):
        self.race(self.statement(), f"UPDATE {S}.create_entitlements SET enabled=false,revision=revision+1 WHERE actor='{A}';")
        self.assertEqual(self.sql(f'SELECT count(*) FROM {S}.applications'), '1')
        self.deny(self.statement())

    def test_expiry_after_observed_authority_lock_wait(self):
        with self.assertRaisesRegex(AssertionError, 'authority unavailable'):
            self.race(f"UPDATE {S}.create_entitlements SET expires_at=clock_timestamp()+interval '350 milliseconds' WHERE actor='{A}';",
                      self.statement(), lambda: time.sleep(.5))
        self.assertEqual(self.sql(f'SELECT count(*) FROM {S}.applications'), '0')

    def test_expiry_after_observed_idempotency_lock_wait(self):
        self.sql(f"UPDATE {S}.create_entitlements SET expires_at=clock_timestamp()+interval '700 milliseconds' WHERE actor='{A}'")
        advisory = f"SELECT pg_advisory_xact_lock(hashtextextended(jsonb_build_array('{A}'::uuid,'{A}'::uuid,'create_application'::text,'create'::text)::text,0));"
        with self.assertRaisesRegex(AssertionError, 'authority unavailable'):
            self.race(advisory, self.statement(), lambda: time.sleep(.8))
        self.assertEqual(self.sql(f'SELECT count(*) FROM {S}.applications'), '0')


def fixture_environment(root, pg_bin, fault=None):
    """Allowlist only owned paths and fixed controls; never copy ambient values."""
    metadata = json.loads((root/'fixture-owner.json').read_text())
    socket = Path(metadata['socket'])
    if not root.is_absolute() or root.resolve() != root or socket.parent != root:
        raise RuntimeError('Owned absolute fixture root required')
    for directory in [root/'home', root/'tmp']:
        if directory.is_symlink() or not directory.is_dir() or directory.stat().st_uid != os.getuid():
            raise RuntimeError('Owned fixture home/tmp directory required')
    if fault not in (None, 'signal', 'timeout', 'worker-exit'):
        raise RuntimeError('Unknown qualification fault')
    env = {'HOME': str(root/'home'), 'TMPDIR': str(root/'tmp'),
           'PATH': os.pathsep.join([str(pg_bin), str(Path(sys.executable).resolve().parent), '/usr/bin', '/bin']),
           'LANG': 'C', 'LC_ALL': 'C', 'TZ': 'UTC',
           'REGISTRATION_QUALIFICATION_BIN': str(pg_bin),
           'REGISTRATION_QUALIFICATION_SOCKET': str(socket)}
    if fault is not None: env['REGISTRATION_QUALIFICATION_FAULT'] = fault
    return env


def prepare_worker_environment():
    """Scrub before even lease-check subprocesses; then validate the registered owner."""
    socket = Path(os.environ['REGISTRATION_QUALIFICATION_SOCKET'])
    if not socket.is_absolute() or socket.is_symlink() or socket.resolve() != socket:
        raise RuntimeError('Owned absolute Unix socket directory required')
    pg_bin = Path(os.environ['REGISTRATION_QUALIFICATION_BIN'])
    fault = os.environ.get('REGISTRATION_QUALIFICATION_FAULT')
    env = fixture_environment(socket.parent, pg_bin, fault)
    os.environ.clear()
    os.environ.update(env)
    return verify_worker_lease()


def verify_worker_lease():
    """Reject direct/remote worker targets before any SQL or environment forwarding."""
    import stat
    socket = Path(os.environ['REGISTRATION_QUALIFICATION_SOCKET'])
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
    if str(pg_bin) != os.environ['REGISTRATION_QUALIFICATION_BIN'] or pg_bin.resolve() != pg_bin:
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
    fault = os.environ.get('REGISTRATION_QUALIFICATION_FAULT')
    root = Path(tempfile.mkdtemp(prefix='registration-qual-', dir='/private/tmp' if Path('/private/tmp').exists() else '/tmp')).resolve()
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
        subprocess.run([str(pg_bin/'initdb'), '-D', str(cluster), '-A', 'trust', '-E', 'UTF8'], env=env, check=True, capture_output=True, timeout=30)
        subprocess.run([str(pg_bin/'pg_ctl'), '-D', str(cluster), '-l', str(root/'postgres.log'), '-w', '-t', '10',
                        '-o', f"-k {socket} -p 55473 -c listen_addresses=''", 'start'], env=env, check=True, capture_output=True, timeout=15)
        worker = subprocess.Popen([str(Path(sys.executable).resolve()), '-I', str(Path(__file__).resolve()), '--worker'], env=env, start_new_session=True)
        if env.get('REGISTRATION_QUALIFICATION_FAULT') == 'signal':
            os.kill(os.getpid(), signal.SIGTERM)
        return worker.wait(timeout=.3 if env.get('REGISTRATION_QUALIFICATION_FAULT') == 'timeout' else 120)
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
        finally:
            for sig, handler in old_handlers.items(): signal.signal(sig, handler)

# The following reviewed directory/PID-bound cleanup implementation is copied byte-for-byte
# from the source recorded in sources.json. No generic PID scan or unrelated deletion.
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
    return {'cluster_created': True, 'registered_socket': str(socket), 'registered_cluster': str(cluster),
            'postmaster_pid': pid, 'discovered_postmasters': discovered,
            'postmaster_absent': True, 'socket_absent': True}

# Reviewed group cleanup, copied byte-for-byte; provenance in sources.json.
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


def quiesce_worker(worker):
    """Signal only the session/group created for this exact Popen child."""
    group = worker.pid  # start_new_session=True establishes PID == PGID == SID.
    if _group_exists(group):
        os.killpg(group, signal.SIGTERM)
        try:
            worker.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
    if _group_exists(group):
        os.killpg(group, signal.SIGKILL)
    worker.wait(timeout=5)
    deadline = time.monotonic() + 5
    while _group_exists(group) and time.monotonic() < deadline:
        time.sleep(0.05)
    if _group_exists(group):
        raise RuntimeError('Fixture process group not quiescent; preserve owned files')
    return {'worker_pid': worker.pid, 'worker_group_absent': True, 'worker_returncode': worker.returncode}

if __name__ == '__main__':
    if sys.argv[1:] == ['--worker']:
        socket, pg_bin = prepare_worker_environment()
        fault = os.environ.get('REGISTRATION_QUALIFICATION_FAULT')
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
