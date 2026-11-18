# Migration source-history alignment

This change restores recorded migration identities without changing SQL. Five evidence files match the published source in PR #90 (head 74f7e3eb59c01ba4a48978e149faf22a2d1be88c). The atomic evidence release matches its preserved Git blob and the recorded applied statement byte-for-byte. Release-pack jobs (#119) and professional artist accounts (#121) retain their exact merged SQL under their recorded application timestamps.

| Recorded version | Source | SHA-256 of unchanged SQL |
| --- | --- | --- |
| 20261009180000 | PR #90 | `e8da77af97583862fc7ae083deab57c17708c0520fe4cd781b1424a92c3db5e1` |
| 20261009180001 | PR #90 | `6de9db119f8c3fca29376af6a52356a7c11b725114af9a34cc2294549de29662` |
| 20261009180002 | PR #90 | `3a990094055ada83aaf62410d359d23848174df2dd396cf2c8e9c8317d763140` |
| 20261009180003 | PR #90 | `30a25384bc726ef613ddafee16c9d76649d2b436033b5632dca42d3225ea84c4` |
| 20261009180004 | PR #90 | `27518a7a42bd3e92d3d357dc06119e190fd2ffe14685e4dfa351b00c9eb9eef5` |
| 20261020035229 | Preserved atomic release; recorded applied statement | `b5b46d803748432bb114bcd36a896d0f306df9b89b70b17de8a69e69929a615c` |
| 20261020154953 | PR #119; formerly 20261020150000 | `3605c64461a5aa5d7ef29fe0893c10d863b51f14044f0098a89ee6b7d1a16aed` |
| 20261024002432 | PR #121; formerly 20261023160000 | `1e3533414fc0101ab26258f1199370978f83395adf31b6c0c5aa9e9bfccea76d` |

The atomic release's preserved local source is b85a490b0b03803d052544c2445696fc3863e936. That local commit is not asserted to be a merged or remotely published commit; the independently read recorded migration statement is the authoritative byte comparison. No SQL was inferred from migration names and no empty migration was introduced.

## Merge hold: pending migration is not authorized by this repair

Read-only version comparison after alignment: 276 recorded remote versions, 277 unique local versions, zero remote-only versions. The sole local-only migration is `20261022120000_context_catalog_cases.sql` from merged PR #120. It is unchanged and absent from the observed remote history; it is not a renamed equivalent of these eight entries.

Fixing history can unblock the configured main-merge integration and allow that pending catalog-case migration to apply. **Keep this PR draft and do not merge without explicit migration approval or a proven non-applying review-only path.** Source-history repair is not migration-apply permission. No integration setting, remote history, schema or grant is changed here. Metadata comparison is not a live dry-run or hosted SQL qualification; environments with different recorded history require their own review.

Validation is bounded to byte equality against recorded statements/original Git blobs, unique timestamp identities, migration version-set comparison, unchanged catalog-case source, and updated fixture/document references. No remote migration repair, SQL apply or replay was executed.
