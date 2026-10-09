# Research without roster enrollment

`python3 -m unittest discover -s tests -p 'test_research_roster.py'` uses a disposable
cluster, synthetic provider payloads and the real Context foundation, guest,
canonical release and forward roster-isolation migrations. It also runs the
existing explicit-onboarding regressions through the inherited fixture. No
provider calls or hosted credentials are used. The existing onboarding CI
`test_*roster.py` pattern includes this suite.

`20261009190000` removes personal/organization roster inserts from research
completion. Accepted artist identities, recording/release credits, scoped source
versions and request output remain intact. Both guest-adoption timing paths share
this function, so they receive the same behavior without separate transport
flags. Explicit onboarding remains the enrollment operation and reuses the
researched identity. Existing roster rows are neither removed nor reinterpreted.

This correction does not change permissions, provider-spend gates or existing
HTTP/MCP authorization. Its fresh-connection SQL read verifies persistence, not
production authenticated transport parity. Revoked explicit enrollment is covered
by the inherited onboarding regressions; production membership/transport checks
still require approved deployment and supported readback.
