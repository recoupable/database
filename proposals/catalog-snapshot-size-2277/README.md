# Inactive Catalog snapshot size proposal (#2277)

Outside migrations; no runtime grants or activation. Requires Database main7708e337 plus original DB1253f2c849 accepted four-file bundle (composition tree4a611d840e1e04d2b6f7d5a50e7789c4940d3b07). The original Catalog migration and restored history remain untouched.

Replace only save_context_catalog_case in disposable fixtures. Dedicated SQLSTATE22001 / CATALOG_SNAPSHOT_TOO_LARGE follows exact replay and precedes mutation, checking incomingJSONB and final server-revision snapshot against the existing1MiB cap. Preserve original fingerprint, actor/owner access, CAS, tableCHECK, arbitrary JSON values and existing grants.

The fixture reuses the accepted four-file bootstrap and applies this proposal last. API tests read exact owning Git bytes; no SQL business logic is copied into API. Any future approved migration/release composition is a separate gate. Keep this PR draft and unmerged; no apply/dryrun/hosted preview or grants are authorized.
