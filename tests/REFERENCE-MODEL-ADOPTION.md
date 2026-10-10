# Reference model adoption map

`reference_model_adoption.json` records which music-business distinctions the
migration files on `main` already enforce, which are only in open PRs, and which
are not adopted. It holds only what migration files can show. The canonical
field-by-field reference model, its relationships and scenarios stay in the
private Business workspace: that reference is canonical for intent, and this map
for what `main` migrations enforce. This map is not a proposed schema and not
approval for any migration.

```sh
python3 -m unittest discover -s tests -p 'test_reference_model_adoption.py'
```

The runner reuses the disposable release-case cluster, adds minimal catalog stubs
and applies the subject-entry, catalog-member and professional-roster migrations
listed in `EXTRA_MIGRATIONS`. CI runs it on PostgreSQL 15 and 16. Run locally, it
passes only when every `main` migration file matches the map. It does not show
what a hosted database has applied.

## Rows

Each row has a relationship group (`identity`, `recording_composition_release`,
`roster_catalog`, `scoped_evidence`), the tickets that own further adoption, and
one status:

- `main_migration`: defined by the named migrations. Structural checks (CHECK
  literals/columns, foreign keys, nullability, uniqueness, RLS and browser grants)
  run on the disposable database. `"exact": true` means the CHECK allows only the
  listed values, so a new subject or resource kind fails until it is mapped.
  Behaviour checks name a test in this file.
- `open_pr`: implemented on an unmerged database PR. The listed tables/functions
  must not be defined by any `main` migration.
- `not_adopted`: deferred by design. No `main` migration may define a matching
  table, function, column or string literal, and a named behaviour test can show
  the current limit (for example, recording subjects still require an ISRC).

## What fails

- A row's structural or behaviour check no longer holds on the migrations the
  runner applies.
- Any other migration alters, drops, indexes, adds or drops a trigger or policy
  on, or grants or revokes privileges on a table a `main_migration` row checks.
  Add it to `EXTRA_MIGRATIONS` so the structural checks run against it, then
  recheck the rows.
- A migration redefines a mapped CHECK constraint. Recheck the row and set its
  `defined_in` to that migration.
- A migration defines an `open_pr` or `not_adopted` object. Flip the row to
  `main_migration` with structural checks, or update it.

When this happens, update the private reference, relationships and scenarios as well.

## Paired changes and merge order

In pull-request CI the runner compares with the base branch:

- A mismatch caused by a migration the pull request adds fails, so the map changes
  in the same pull request.
- A mismatch caused by a migration already on the base branch (merged before this
  suite saw it) is printed as a warning, so it cannot turn `main` or an unrelated
  pull request red. Fix it with a map-only pull request.
- A pull request that edits the map, this runner or `test_release_cases.py` must
  match every migration.

Pushes to `main` report mismatches as warnings only.

## Limits

The static checks use simple patterns over migration text with comments removed.
They do not see dynamic SQL such as `execute format(...)`, `drop index` by index
name, or an equivalent structure under another name. They are guards, not proof.
