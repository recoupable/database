"""Disposable-only mechanical parent/authority binding. No fixture authority imported."""
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent


def compose():
    manifest = json.loads((HERE / 'sources.json').read_text())
    chunks = []
    for source in manifest['composition']:
        raw = (HERE.parent.parent / source['path']).read_bytes()
        if hashlib.sha256(raw).hexdigest() != source['sha256']:
            raise ValueError('Unexpected protocol source: '+source['path'])
        text = raw.decode()
        for binding in source['bindings']:
            if text.count(binding['from']) != binding['count']:
                raise ValueError('Unexpected binding count: '+source['path'])
            text = text.replace(binding['from'], binding['to'])
        chunks.append(text)
    # Same five-argument management contract, now using the proposed exact entitlement table.
    # This is the sole adapter body; its expected digest is included in the manifest below.
    adapter = '''CREATE OR REPLACE FUNCTION application_proof_proposal.authorize_management(
 p_actor uuid,p_workspace uuid,p_application uuid,p_environment text,p_operation text
) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 PERFORM application_registration_proposal.authorize_management(p_actor,p_workspace,p_application,p_environment,p_operation);
END $$;
REVOKE ALL ON FUNCTION application_proof_proposal.authorize_management(uuid,uuid,uuid,text,text) FROM PUBLIC;
'''
    if hashlib.sha256(adapter.encode()).hexdigest() != manifest['authorityAdapterSha256']:
        raise ValueError('Unexpected management adapter')
    return '\n'.join(chunks) + '\n' + adapter


if __name__ == '__main__':
    print(compose())
