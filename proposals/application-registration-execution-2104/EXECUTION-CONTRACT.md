# Inactive create/read execution contract

This is a **local disposable privilege qualification**, outside migrations. It adds two fixed entry functions over unchanged Database D `f507a77696f20429f977df9885d6c8c11a5f304b`; API provenance is merged `ec284cba127d73d0c3e7e74deceabac5c6a145f1`. It does not supply a production connection, role name, enrollment policy, migration, route/tool registration or storage factory. Database138 remains draft and unapplied. D1 personal enrollment, D2 pilot operation/policy and D4 retention/deletion remain unadopted.

Only these five files belong to this proposal. `sources.json` pins the D supervisor, loaded SQL, parent contract and API provenance. The runner hashes all five D files before importing the supervisor or issuing SQL; source drift fails closed. API hashes record the reviewed handoff source, not a locally executed credential verifier. No proof/configuration composition is loaded. D's synthetic bootstrap defines `qualification_auth.original_actor`, but this runner never invokes it or uses its result as authority.

## Identity and trust

All `qualification_registration_*` names are **synthetic fixture labels**, not production recommendations:

| Role | Capability |
| --- | --- |
| `data_owner` | NOLOGIN; owns D schemas/tables/internal functions, distinct from executor |
| `executor` | NOLOGIN; owns exactly the two entry functions; bounded column and helper privileges; no table ownership, schema CREATE, superuser or BYPASSRLS |
| `runtime` | NOLOGIN; entry-schema USAGE and two application entry EXECUTE grants only |
| `client` | Separate NOINHERIT LOGIN; member of runtime only, no ADMIN option; explicitly SET ROLE runtime |
| `browser` | Separate NOINHERIT LOGIN; unrelated, no memberships or application grants |

All five lack SUPERUSER, CREATEDB, CREATEROLE, REPLICATION and BYPASSRLS. Positive calls connect with `psql -U qualification_registration_client` on the controller's owned Unix trust socket; they are not SET ROLE inside an original superuser login. RESET ROLE and SET SESSION AUTHORIZATION DEFAULT return to that unprivileged client. Attempts to become the executor, data owner or installer are denied. The disposable controller installs fixtures and inspects state; its administrative success is never counted as runtime access.

NOLOGIN is not an isolation proof: function ownership and the ability to alter roles/grants remain administrative trust. No login is a member of the executor/data owner, and catalogs plus forbidden switching tests establish the fixture boundary. The fixture controller can alter anything; this proposal does not constrain that controller.

Database PUBLIC CONNECT remains available inside the private socket fixture. PUBLIC CREATE and TEMP are explicitly revoked; runtime/client/browser/executor have neither. Trusted schemas deny runtime/executor CREATE after installation. A single shadow-object test temporarily grants TEMP to runtime, creates temporary objects, then revokes TEMP and proves denial again. That separate reversible profile is not a retained runtime privilege. “Two EXECUTE grants” refers to application entry points; ordinary PostgreSQL built-ins remain available.

## Exact call graph and installation

`application_registration_execution_proposal.create_registration(uuid,uuid,text,text,bigint,jsonb)` calls D's `register_application` once. `read_registration(uuid,uuid,uuid,text,uuid)` calls D's `read_registration` once. Both return jsonb, are SECURITY DEFINER owned by executor, and fix `search_path=pg_catalog,pg_temp` and `row_security=on`. Their bodies contain only the fully qualified invocation; no dynamic SQL, role switch, retry, exception remapping, claims parser or transaction control.

D remains SECURITY INVOKER with its original empty search path. Create calls authorize_create → authorize_principal; read calls authorize_management → authorize_principal. The executor gets exactly those five D function EXECUTE grants and D/public schema USAGE. Runtime cannot call the D entries/helpers directly. `immutable_history` is not granted to executor/runtime; existing triggers continue to enforce history immutability. The tests inspect both trigger bindings and function owners/configuration, and exercise the original immutable-history failures.

`execution.sql` creates entry functions, revokes PUBLIC EXECUTE and grants the two signatures in one transaction. Default EXECUTE is globally revoked for each actual creator: fixture installer, data owner and executor. New probe functions created as each role verify the defaults; schema-only revocation or ownership transfer is not treated as sufficient. A marker and fixture prerequisites reject accidental standalone loading; the marker is not authentication or permission to use a live database.

## Measured privilege matrix

All relations are synthetic. No production RLS or database ACL is changed.

| Relation | Executor SELECT | Executor INSERT | Row-lock UPDATE column |
| --- | --- | --- | --- |
| public.accounts | id | none | id |
| personal_principals | account_id, enabled, policy_version | none | account_id |
| create_entitlements | all 7 D columns | none | actor |
| management_entitlements | all 8 D columns | none | actor |
| requests | all 5 D columns | all 5 D columns | none |
| receipts | id, result, workspace_id, application_id, environment | all 7 D columns | none |
| applications | none | workspace_id, id, billing_owner_id, name | none |
| environments | none | workspace_id, application_id, environment | none |
| origins | none | workspace_id, application_id, environment, origin, hostname, return_urls | none |

No sequence, DELETE, TRUNCATE, REFERENCES or TRIGGER grant is added. Tests compare catalog column privileges to this exact matrix, verify runtime/client/browser have no table/column privileges, and remove every SELECT/INSERT column separately to require a real 42501 denial with all five result tables unchanged. They remove each of the four UPDATE-column grants separately too. No broader grant is substituted for a failure.

FOR SHARE needs UPDATE privilege on at least one column. Each of the four authority/account relations therefore has executor SELECT USING true and UPDATE USING true **WITH CHECK false**. All nine account/proposal tables ENABLE and FORCE RLS. The five result tables have executor INSERT WITH CHECK true; requests/receipts also have SELECT policies. There are exactly fifteen policies, all executor-specific, with no permissive ALL/UPDATE policy that could OR away the false update check. Executor is neither table owner nor RLS bypass. Removing UPDATE USING access independently denies the lock-based operation; actual UPDATE of the granted column is rejected without row changes.

These policies constrain operations, **not caller identity**. D's explicit actor/workspace/operation checks and row locks remain the proposed tenant authority boundary. Hidden rows can produce different outcomes: if receipt SELECT visibility is removed, unchanged D's replay lookup returns SQL NULL, while its read function raises 42501. Qualification records that distinction and rejects NULL as a receipt. The API's receipt validation must remain after storage. A completed SQL statement alone is never sufficient success evidence.

## Original actor handoff and limits

A UUID argument is not authentication. The intentionally positive limitation test shows the **same runtime login successfully asserting either of two enrolled actors**. This capability is suitable only behind the reviewed trusted server boundary; it is not a browser/PostgREST end-user RPC contract.

Before real storage entry, the owning API must verify the original request with nonprovisioning existing-account/self/no-organization rules, pass the private server-derived actor/workspace to a fixed parameterized invocation and preserve receipt validation. Do not accept body account IDs, authInfo, caller JWT/GUC claims or role names as proof. The accepted API source rechecks admission/tool/domain observations and observes termination before entry; this SQL runner does not execute that authentication, call Privy, inspect credentials or close its races.

Credential-only change with the same actor at the third domain observation is not detectable by its actor/workspace storage guard. API-key/Privy revocation is not atomic with SQL. After storage entry, HTTP abort/deadline or SDK closure does not cancel/roll back SQL. Preserve one invocation, unknown-outcome handling and explicit original-key reconciliation; never auto-retry. The response-loss test discards output only after a real committed transaction, then explicitly replays the original key and checks the stored IDs/timestamp/full history.

D requires READ COMMITTED. Revocation writers must use account → enrollment → entitlement lock order. Create entitlement expiry is nullable; null means no expiry. D checks expiry after authority lookup, after its retry-key advisory wait and immediately before insertion. This is **not a commit-time deadline** or a check after every later wait. Management entitlements have no expiry column; this proposal adds no management TTL. Authority locks serialize those row changes, not external credential revocation. No organization/delegation, DNS proof, configuration, provider, spending or retention policy is added.

## Qualification and lifecycle

Run from this owning Database checkout, using a locally installed PostgreSQL bin directory:

```sh
PG_BIN=/opt/homebrew/opt/postgresql@15/bin /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 -I proposals/application-registration-execution-2104/test_privileges.py
PG_BIN=/opt/homebrew/opt/postgresql@17/bin /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 -I proposals/application-registration-execution-2104/test_privileges.py
```

No DSN arguments, env files, hosted account lookup or live connection is accepted. D's hash-pinned supervisor creates a random Unix-only cluster, allows only its fixed environment, binds the directory/PID/worker lease, bounds SQL/process timeouts, quiesces the dedicated worker process group and verifies the owned postmaster/socket before removal. The only dispatch adaptation sets the imported module's `__file__` to this runner so its child re-enters this suite. It does not replace cleanup functions, copy a lifecycle framework or alter D source. Its original signal/timeout/worker-exit faults are forwarded for focused trampoline-cleanup qualification.

The suite covers separate-login create/read and forbidden escalation; catalog ACL/default grants/owners/RLS; no implicit read grant; two actors/apps/environments; both P2101 conflicts and 42501-before-replay; replay after enabled revision advance; explicit rollback and injected second-origin failure; committed response loss; history immutability; controlled RLS NULL; temporary/public shadow boundaries; and observed two-connection locks for concurrent replay, both revocation orders and expiry after authority/advisory waits. Lock evidence is tied by pg_blocking_pids to the actual holder before the test releases it. Snapshot comparisons include complete rows of applications, environments, origins, receipts and requests.

Source qualification and review receipts remain local under Mono `.local/audits/sites2104-execution-contract-local-2026-11-18/`. The focused RED removes the two entry EXECUTE grants and runs the positive case: it must fail at create permission. Full passing results and exact runtime/cleanup facts are recorded in that receipt, not inferred from this specification. No source publication is authorized until root's separate gate.

## Later release prerequisites

Reuse existing DB-OBSERVATION-01 only after root verifies target/runner relevance: actual creator/default ACL, function owner, runtime connection/SET ROLE support, production RLS integration, transaction/pooling/timeouts and cancellation/unknown outcomes remain unproved. Catalog/reservation observations are not automatically Sites capability proof. No new credential request or duplicate human alert is warranted by this disposable work.

Plan seal: `852a8ff829bfc9b9a426ee32382435bede1cabd30ed8b3297e6c6eef7c0da4d7`; decision successor seal: `076754718f7aaa10278a322ef448fe0dff33fdc214b85634cb97554a30b14765`; independent OAuth plan review seal: `2c0bc1a0b08ce84218e2593edb9831e649b68bdb9b4931f0fccd1eb888905828`. Their local receipts are respectively `sites2104-create-read-privilege-plan-2026-11-18`, `sites2104-runtime-policy-decision-successor-2026-11-18`, and `oauth-sites2104-execution-plan-review-2026-11-18` under Mono `.local/audits/`.
