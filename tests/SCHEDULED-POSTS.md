# Scheduled posts migration

`20261015230000_create_scheduled_posts.sql` adds `scheduled_posts`, one row per
`POST /api/posts` call: a finished video and its copy to one connected account
on Instagram, X, LinkedIn or YouTube, published now or at `publish_at`
([recoupable/app#2241](https://github.com/recoupable/app/issues/2241); contract
published in recoupable/docs#375). The row doubles as the run record for the
publish workflow, like `music_generations`.

CHECKs hold the contract's shape: required copy per platform (YouTube `title`,
otherwise `description`), LinkedIn-only `sub_account_id`, YouTube-only
`privacy`/`tags`, no `cover_url` on YouTube, `scheduled` needs `publish_at`,
`posted` needs a non-blank `post_url`, `failed` needs `error_message`; a supplied `sub_account_id` cannot be blank. Length limits stay in
the API. RLS is on with no policies; browser roles have no grants; only
`service_role` reads and writes.

```sh
python3 -m unittest discover -s tests -p 'test_scheduled_posts.py'
```

Runs on a disposable local cluster (CI: PostgreSQL 15 and 16).

## artist_account_id

`20261019200000_scheduled_posts_artist_account_id.sql` adds `artist_account_id`, the artist whose
connected social account posts ([recoupable/app#2248](https://github.com/recoupable/app/issues/2248)).
`account_id` is the account the post is made in and charged to, never an artist; `NULL` artist means
the account's own connection posted. The artist column cascades on delete, like `account_id`.

```sh
python3 -m unittest discover -s tests -p 'test_scheduled_posts*.py'
```
