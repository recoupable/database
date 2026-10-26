"""Reproduce synthetic capture from pinned local API sources; no fetch or credentials."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

PIN = '4336582b848c5d7808597f5a3890f55013d13b1f'
GENERATOR = "import { captureFencedEditedTurn } from './lib/chat/fence/edit/captureFencedEditedTurn';\nimport { editFixture } from './lib/chat/fence/edit/__tests__/editFixture';\nimport { encodeStrictJson } from './lib/chat/fence/encodeStrictJson';\nconst input=editFixture();\ninput.workflowInput.sessionId='chat';\ninput.deletion.expectedEpoch=0;\nconst capture=captureFencedEditedTurn(input).read();\nconsole.log(JSON.stringify({capture,user_intent_canonical:encodeStrictJson({anchor_id:input.deletion.anchorId,edited_user_message:input.editedUserMessage,requested_options:{}}),history_witness:input.workflowInput.messages.map(message=>({id:message.id,role:message.role,message}))},null,2));\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('api_repository', type=Path)
    parser.add_argument('esbuild', type=Path, help='Installed node_modules/.bin/esbuild')
    parser.add_argument('--output', type=Path, default=Path(__file__).with_name('atomic-edit-vector.json'))
    args = parser.parse_args()
    repo, esbuild = args.api_repository.resolve(), args.esbuild.absolute()
    def git(*command):
        return subprocess.check_output(['git', '-C', str(repo), *command])
    assert git('rev-parse', PIN).decode().strip() == PIN
    with tempfile.TemporaryDirectory(prefix='atomic-edit-capture-') as directory:
        root = Path(directory)
        paths = git('ls-tree', '-r', '--name-only', PIN, 'lib/chat/fence',
                    'lib/intelligent-ui', 'lib/catalog').decode().splitlines() + ['tsconfig.json']
        for name in paths:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(git('show', PIN + ':' + name))
        (root / 'generate.ts').write_text(GENERATOR)
        env = {**os.environ, 'NODE_PATH': str(esbuild.parent.parent)}
        subprocess.run([str(esbuild), str(root / 'generate.ts'), '--bundle', '--platform=node',
                        '--outfile=' + str(root / 'capture.cjs')], env=env, check=True)
        result = subprocess.check_output(['node', str(root / 'capture.cjs')])
        json.loads(result)  # Refuse to replace the vector on invalid/failed generation.
        args.output.write_bytes(result)


if __name__ == '__main__':
    main()
