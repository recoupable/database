# Reference model adoption map

`reference_model_adoption.json` records which music-business distinctions the
migration files on `main` already enforce, which are only in open PRs, and which
are not adopted. The canonical reference model, its relationships and scenarios
stay in the private Business workspace. This map is not that reference, not a
proposed schema and not approval for any migration.

```sh
python3 -m unittest discover -s tests -p 'test_reference_model_adoption.py'
```

The runner reuses the disposable release-case cluster, adds minimal catalog stubs
and applies the actual subject-entry, catalog-member and professional-roster
migrations. CI runs it on PostgreSQL 15 and 16. Passing means `main` migration
files match the map. It does not show what a hosted database has applied.

## Rows

Each row has a relationship group (`identity`, `recording_composition_release`,
`roster_catalog`, `scoped_evidence`), the tickets that own further adoption, and
one status:

- `main_migration`: defined by the named migrations. Structural checks (CHECK
  literals/columns, foreign keys, nullability, uniqueness, RLS and browser grants)
  run on the disposable database. Behaviour checks name a test in this file.
- `open_pr`: implemented on an unmerged database PR. The listed tables/functions
  must not be defined by any `main` migration.
- `not_adopted`: deferred by design. No `main` migration may define a matching
  table, function or column, or a named behaviour test shows the current limit
  (for example, recording subjects still require an ISRC).

## Paired changes

A model correction changes the map in the same PR:

- A migration that redefines a mapped CHECK constraint fails until the row's
  `defined_in` names that migration and the expectation is rechecked.
- Merging an `open_pr` row's PR fails its absence check. Flip the row to
  `main_migration`, add structural checks and add the migrations to the runner.
- Adopting a `not_adopted` concept fails its absence check until the row is
  updated. Update the private reference, relationships and scenarios as well.

Absence checks scan migration text with simple patterns. They are guards, not
proof that no equivalent structure exists under another name.
