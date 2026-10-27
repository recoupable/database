-- Disposable parent extension only. Not a registry migration or role policy.
ALTER TABLE proof_parent_fixture.applications ADD COLUMN name text NOT NULL DEFAULT 'Music';
ALTER TABLE proof_parent_fixture.origins ADD COLUMN return_urls text[] NOT NULL DEFAULT '{}';
