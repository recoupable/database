# Catalog vector port map

Source: API #1187 `b185ea9ded070cd6d621d2bf13843bf9df6e5a8f`, adopted merge
`08f62b7474e52b2bd0114d2d2c62c642c17ef6bf`,
[all 31 vectors](https://github.com/recoupable/api/blob/08f62b7474e52b2bd0114d2d2c62c642c17ef6bf/docs/contracts/catalog-stream-evidence-2207/vectors.json).
Every live mapping remains unsupported. These ports qualify evidence only; they
never claim that the vectors' comparison outputs or production intake are shipped.

| Catalog vector IDs                                                                   | Executable proof / remaining boundary                                                                                                                     |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| exact_bound_bundle; disabled_tracking_retains_evidence                               | Exact expanded member, stable source/version/result; disable remains readable.                                                                            |
| known_zero_baseline; null_correction_bound; absent_date_bound; all_stored_nulls      | Null/zero/missing evidence kept distinct; comparison arithmetic remains unqualified.                                                                      |
| new_correction_bound; old_version_after_correction; correction_not_yet_context_bound | Explicit corrected version accepted with existing CAS; old tuple/version refuses.                                                                         |
| mixed_provider_ids; all_dates_changed_provider                                       | Full matching tuple set refuses mixed identity; new result differing from earlier accepted source identity refuses.                                       |
| workspace_revoked; member_removed; unresolved_recording                              | Actor/membership/expanded-edge refusal, including real competing revocation locks.                                                                        |
| cross_owner_version; unrelated_metadata_version; forged_hash_only                    | Wrong owner/version, missing/extra lineage and exact source scope refuse. UUIDs remain stored references, never hashes.                                   |
| unsupported_field_relabel                                                            | Wrong metric/scope and extra content refuse. No comparison/financial field authorization exists.                                                          |
| source_withdrawn; version_removed; attempted_recreation_after_withdrawal             | Existing withdrawal clears pointer; removed version and active replacement with withdrawn locator history refuse.                                         |
| different_current_window                                                             | New window replaces one current document; old binding stale. Additional cross-catalog replacement proof enforces same stable topic/document.              |
| unstable_chunked_read; arbitrary_caller_tuple                                        | Exact retained tuple mismatch, malformed run/date lineage and bad retained fields refuse. Direct phantom inserts remain outside cooperative writer proof. |
| result_not_accepted                                                                  | Stale result refuses.                                                                                                                                     |
| customer_correction_blocks_refresh                                                   | Reader refuses customer_assertion as provider observation; preservation by the future retention writer is not proven.                                     |
| entirely_absent                                                                      | Reader requires at least one retained row; broader no-row intake behavior remains a writer obligation.                                                    |
| identical_collection_no_new_rows                                                     | Unchanged retained tuples stay identical by construction; production dedup/replay not implemented.                                                        |
| late_writer_cas_lost                                                                 | Existing CAS used by fixture acceptance; concurrent production retention writer not implemented.                                                          |
| unsafe_retained_count                                                                | Existing table CHECK constrains rows; derived safe-total overflow and full ingestion validator remain unqualified.                                        |
| storage_failure                                                                      | Operational errors propagate; real transport failure behavior is not implemented by this SQL-only proof.                                                  |

Additional executable boundaries: 12-run/732-date snapshot, >732 refusal, retained
retrieval max, malformed hash/provider/timestamp/run range, multi-byte UTF-8 overflow,
READ COMMITTED requirement, mutation locks and reverse-order lineage insertion.
