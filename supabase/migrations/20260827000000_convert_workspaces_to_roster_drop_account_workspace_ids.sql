-- chat#1979: workspaces removed as an account type; organizations supersede them.
--
-- Owner decisions (2026-08-21, amended 2026-08-26): of the 46 prod workspaces,
-- the 37 that are named "Untitled" or have no chat room are deleted outright,
-- and the 9 named workspaces with chat history are converted to roster rows.
-- Workspaces behave as pseudo-artists (rooms hang off artist_id), so each kept
-- (account_id, workspace_id) pair becomes an account_artist_ids
-- (account_id, artist_id) row: owners keep those workspaces and chats through
-- the normal artist path. The join table is then dropped.
--
-- Snapshots on the issue (recoverability record): the 46 join rows
-- https://github.com/recoupable/app/issues/1979#issuecomment-5432260065 and,
-- for the 37 deleted workspaces, their accounts / account_info / rooms /
-- memories rows (see the 2026-08-26 deletion-snapshot comment).
--
-- Deleting an accounts row cascades account_info, rooms and memories
-- (ON DELETE CASCADE on each). None of the 37 is referenced by
-- account_artist_ids, sessions, scheduled_actions, account_socials, credits or
-- organizations (verified 2026-08-26); the NOT EXISTS guard below keeps it that
-- way if anything changes before this runs.
--
-- Dropping account_workspace_ids takes its own PK, both outbound FKs to
-- accounts, its set_updated_at trigger, its two indexes, and its RLS state
-- with it; nothing else in the schema references the table (audit 2026-08-19).
--
-- Idempotent: the deletes are no-ops once the rows are gone, the INSERT is
-- guarded by a to_regclass existence check and dedupes via the
-- account_artist_ids_account_id_artist_id_key UNIQUE constraint
-- (20260708200000), and the DROP is IF EXISTS.

-- 1) Delete the empty workspaces (explicit ids from the snapshot) ---------------
DO $$
BEGIN
    IF to_regclass('public.account_workspace_ids') IS NOT NULL THEN
        DELETE FROM public.account_workspace_ids
        WHERE workspace_id IN (
        '0084a2e8-97d0-4107-b2b2-5f03f80a4bb0',
        '043327e7-9d6d-4ff5-923e-08c751554531',
        '07389e03-e6c3-4b68-85ea-0a5642a29ac3',
        '0c75d957-ea96-476c-a020-75773115f811',
        '21a1bedc-95d5-4765-9e88-f0c0ca2508cc',
        '260f9c9a-51be-48df-b0d2-aa0a0e396913',
        '2e3c1d69-85ef-415c-a0b5-8c8449fb069e',
        '47cb1daa-909c-4363-afa7-ab93c25237da',
        '48d38f07-3641-451e-b358-32569f0e9c0b',
        '48eaaf4b-a875-4d6b-99cb-3d4319a129d1',
        '4d3079d6-cc91-4c6f-84ca-dd1852a9bd81',
        '544bb539-df55-4419-9dfe-75ada836b956',
        '60078d95-d38d-4126-ac17-a568fea80c78',
        '667a289e-220d-4050-a502-b841dcdfe7fa',
        '66f905c1-a882-4ddb-bf5a-04729b02c14c',
        '6b5bdb75-1499-4d8a-83a9-3978f4182db4',
        '7d1d2967-b5d7-4c6c-9656-db8d3df00688',
        '8184e2cb-f533-4124-8478-22d46a678819',
        '83b3a89f-96b6-4f51-9120-1241fbc88baa',
        '83de7209-5270-445c-bae6-e94d014bb354',
        '86429786-1a72-463d-aa4c-70fd0ebe6fa1',
        '87efd970-5d01-4b7d-bb49-918608edc158',
        '8cd4e7a1-d784-41dd-bb63-d46aafe457fa',
        '9d0c4686-9fa0-4a97-ba23-41e96c71ace9',
        '9e06dc23-745e-4e22-a1c9-08a73de61d47',
        'b8ed4a56-9be7-49ce-829a-873b00f54cdf',
        'bbf01d59-3d6a-492c-a4c6-cf7aa40d241f',
        'bdb3a530-c37b-4e3a-bd9e-e8310694bcd9',
        'c79d5fc0-c1b8-4b2b-8f23-a58094ad2446',
        'c7ede6de-e07b-4b14-be96-d394c143b486',
        'd46273cd-927d-4a4f-bedc-414503944291',
        'd8b91657-dc64-49d9-bbb4-18f47dc1a732',
        'df4a3675-11be-415a-a47a-83470f1f3c67',
        'ec41d76b-5a5f-4001-9ee4-c886b2beebd9',
        'ee8916e0-1a2e-42fb-8fdf-732a44580853',
        'f91a15e4-2f3a-4dcf-88ea-3ee37655664e',
        'fc82d6bb-3581-46ce-869f-17073036c80c'
        );
    END IF;
END $$;

DELETE FROM public.accounts a
WHERE a.id IN (
        '0084a2e8-97d0-4107-b2b2-5f03f80a4bb0',
        '043327e7-9d6d-4ff5-923e-08c751554531',
        '07389e03-e6c3-4b68-85ea-0a5642a29ac3',
        '0c75d957-ea96-476c-a020-75773115f811',
        '21a1bedc-95d5-4765-9e88-f0c0ca2508cc',
        '260f9c9a-51be-48df-b0d2-aa0a0e396913',
        '2e3c1d69-85ef-415c-a0b5-8c8449fb069e',
        '47cb1daa-909c-4363-afa7-ab93c25237da',
        '48d38f07-3641-451e-b358-32569f0e9c0b',
        '48eaaf4b-a875-4d6b-99cb-3d4319a129d1',
        '4d3079d6-cc91-4c6f-84ca-dd1852a9bd81',
        '544bb539-df55-4419-9dfe-75ada836b956',
        '60078d95-d38d-4126-ac17-a568fea80c78',
        '667a289e-220d-4050-a502-b841dcdfe7fa',
        '66f905c1-a882-4ddb-bf5a-04729b02c14c',
        '6b5bdb75-1499-4d8a-83a9-3978f4182db4',
        '7d1d2967-b5d7-4c6c-9656-db8d3df00688',
        '8184e2cb-f533-4124-8478-22d46a678819',
        '83b3a89f-96b6-4f51-9120-1241fbc88baa',
        '83de7209-5270-445c-bae6-e94d014bb354',
        '86429786-1a72-463d-aa4c-70fd0ebe6fa1',
        '87efd970-5d01-4b7d-bb49-918608edc158',
        '8cd4e7a1-d784-41dd-bb63-d46aafe457fa',
        '9d0c4686-9fa0-4a97-ba23-41e96c71ace9',
        '9e06dc23-745e-4e22-a1c9-08a73de61d47',
        'b8ed4a56-9be7-49ce-829a-873b00f54cdf',
        'bbf01d59-3d6a-492c-a4c6-cf7aa40d241f',
        'bdb3a530-c37b-4e3a-bd9e-e8310694bcd9',
        'c79d5fc0-c1b8-4b2b-8f23-a58094ad2446',
        'c7ede6de-e07b-4b14-be96-d394c143b486',
        'd46273cd-927d-4a4f-bedc-414503944291',
        'd8b91657-dc64-49d9-bbb4-18f47dc1a732',
        'df4a3675-11be-415a-a47a-83470f1f3c67',
        'ec41d76b-5a5f-4001-9ee4-c886b2beebd9',
        'ee8916e0-1a2e-42fb-8fdf-732a44580853',
        'f91a15e4-2f3a-4dcf-88ea-3ee37655664e',
        'fc82d6bb-3581-46ce-869f-17073036c80c'
)
  AND NOT EXISTS (
      SELECT 1 FROM public.account_artist_ids r WHERE r.artist_id = a.id
  );

-- 2) Roster every remaining workspace pair as a plain artist row --------------
DO $$
BEGIN
    IF to_regclass('public.account_workspace_ids') IS NOT NULL THEN
        INSERT INTO public.account_artist_ids (account_id, artist_id)
        SELECT account_id, workspace_id
        FROM public.account_workspace_ids
        WHERE account_id IS NOT NULL
          AND workspace_id IS NOT NULL
        ON CONFLICT (account_id, artist_id) DO NOTHING;
    END IF;
END $$;

-- 3) Drop the join table ------------------------------------------------------
DROP TABLE IF EXISTS public.account_workspace_ids;
