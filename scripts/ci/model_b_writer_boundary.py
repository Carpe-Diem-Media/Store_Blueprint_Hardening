"""Job-local OS and fixed-command proof. Never provisions workstation identities."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path('/opt/store-membership-writer-ci')
RUNTIME = 'model_b_runtime_os'
OPERATOR = 'model_b_operator_os'
WRITER = 'model_b_writer_os'


def install():
    # Trusted ephemeral CI bootstrap only. This is not an invocation interface.
    if os.geteuid() != 0:
        raise RuntimeError('job bootstrap requires root')
    data = json.load(sys.stdin)
    if ROOT.exists():
        raise RuntimeError('refusing to replace an existing boundary installation')
    for identity in (RUNTIME, OPERATOR, WRITER):
        subprocess.run(['/usr/sbin/useradd', '--system', '--user-group', '--no-create-home',
                        '--shell', '/usr/sbin/nologin', identity], check=True)
    import pwd
    writer = pwd.getpwnam(WRITER)
    ROOT.mkdir(mode=0o755)
    for library in Path('_build/test/lib').iterdir():
        if (library / 'ebin').is_dir():
            shutil.copytree(library / 'ebin', ROOT / 'lib' / library.name / 'ebin')
    for directory, _, files in os.walk(ROOT / 'lib'):
        os.chmod(directory, 0o555)
        for name in files:
            os.chmod(Path(directory) / name, 0o444)
    private = ROOT / 'private'
    private.mkdir(mode=0o750)
    os.chown(private, 0, writer.pw_gid)
    credential = private / 'connection.json'
    credential.write_text(json.dumps(dict(
        hostname='127.0.0.1', port=55433, database='model_b_role_proof',
        username='model_b_allocation_writer', password=data['password'],
        writer_uid=writer.pw_uid,
    )))
    os.chown(credential, 0, writer.pw_gid)
    credential.chmod(0o440)
    # No shell input, caller command, arguments, environment or credential fallback.
    launcher = ROOT / 'launch'
    import shlex
    launcher.write_text(
        '#!/bin/sh\nset -eu\n'
        '[ "$#" -eq 0 ] || exit 23\n'
        f'[ "$(/usr/bin/id -u)" -eq {writer.pw_uid} ] || exit 23\n'
        'exec /usr/bin/env -i HOME=/nonexistent PATH=/usr/bin:/bin LANG=C.UTF-8 '
        + 'ERTS_BIN=' + shlex.quote(str(Path(data['erl']).parent) + '/') + ' '
        '/usr/bin/timeout --signal=KILL 15s '
        + shlex.quote(data['elixir'])
        + " --erl '+S 2:2' -pa '/opt/store-membership-writer-ci/lib/*/ebin' "
        + "-e 'case Store.Release.membership_writer_boundary_probe() do "
        + ":ok -> :ok; _ -> System.halt(23) end' </dev/null\n"
    )
    launcher.chmod(0o755)
    rule = Path('/etc/sudoers.d/model-b-writer-ci')
    rule.write_text(f'{OPERATOR} ALL=({WRITER}) NOPASSWD:NOSETENV: {launcher} ""\n')
    rule.chmod(0o440)
    subprocess.run(['/usr/sbin/visudo', '-cf', str(rule)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def verify_writer_boundary(h):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('MODEL_B_CI_DISPOSABLE') != 'true':
        raise RuntimeError('OS boundary proof requires the disposable CI job')
    if not Path('_build/test/lib/store/ebin/Elixir.Store.Orders.MembershipWriterBoundary.beam').is_file():
        raise RuntimeError('fixed isolated writer boundary is not implemented')
    bootstrap = subprocess.run(
        ['sudo', '-n', sys.executable, __file__, '--install'],
        input=json.dumps(dict(password=h.PASSWORDS[h.WRITER], elixir=shutil.which('elixir'), erl=shutil.which('erl'))),
        text=True, capture_output=True, timeout=30,
    )
    if bootstrap.returncode:
        raise RuntimeError('job-local OS boundary bootstrap failed')

    def run(identity, command, expected=0, env=None):
        # The harness has bootstrap authority. The tested command itself runs
        # under the real unprivileged identity, with none of that authority.
        result = subprocess.run(['sudo', '-n', '-u', identity, '--'] + command,
            text=True, capture_output=True, timeout=20, env=env)
        if (expected == 0 and result.returncode != 0) or (expected != 0 and result.returncode == 0):
            diagnostic = result.stderr[-2000:]
            for secret in list(h.PASSWORDS.values()) + [h.ADMIN_PASSWORD]:
                if secret:
                    diagnostic = diagnostic.replace(secret, '[REDACTED]')
            print(f'Boundary diagnostic returncode={result.returncode}: {diagnostic}', flush=True)
            raise RuntimeError(f'OS boundary assertion failed for {identity}')
        return result

    launch = ['/usr/bin/sudo', '-n', '-u', WRITER, '--', str(ROOT / 'launch')]
    result = run(OPERATOR, launch)
    report = json.loads(result.stdout)
    if (report.get('database_role') != h.WRITER or report.get('session_role') != h.WRITER
            or report.get('store_started') is not False or report.get('privileged_membership') is not False):
        raise RuntimeError('writer process attestation failed')
    print('PASS operator_fixed_invocation ' + json.dumps(report, sort_keys=True), flush=True)
    for identity in (RUNTIME,):
        run(identity, launch, expected=1)
        run(identity, ['/usr/bin/sudo', '-n', '-u', OPERATOR, '--', str(ROOT / 'launch')], expected=1)
        run(identity, [str(ROOT / 'launch')], expected=1)
        run(identity, ['/usr/bin/cat', str(ROOT / 'private/connection.json')], expected=1)
        run(identity, ['/usr/bin/test', '-w', str(ROOT / 'launch')], expected=1)
        run(identity, ['/usr/bin/test', '-w', str(ROOT / 'lib/store/ebin/Elixir.Store.Release.beam')], expected=1)
    print('PASS runtime_launch_impersonation_credentials_and_code_write_denied', flush=True)
    # Missing OS authentication and supplied actor/environment claims do not
    # create authority. Even the authorized operator cannot change the command.
    run(OPERATOR, [str(ROOT / 'launch')], expected=1)
    run(OPERATOR, launch + ['system=true'], expected=1)
    run(RUNTIME, ['/usr/bin/env', 'SUDO_USER='+OPERATOR, 'STORE_SYSTEM=true'] + launch, expected=1)
    print('PASS missing_forged_authentication_and_arbitrary_arguments_denied', flush=True)
    # Exercise the exported release function inside an ordinary-runtime BEAM.
    denied = run(RUNTIME, ['/usr/bin/env', '-i', 'HOME=/nonexistent', 'PATH=/usr/bin:/bin',
        'ERTS_BIN='+str(Path(shutil.which('erl')).parent)+'/', shutil.which('elixir'), '--erl', '+S 2:2', '-pa',
        str(ROOT / 'lib/*/ebin'), '-e',
        'case Store.Release.membership_writer_boundary_probe() do '
        '{:error, :writer_boundary_denied} -> System.halt(23); _ -> System.halt(1) end'], expected=1)
    if denied.returncode != 23:
        raise RuntimeError('ordinary runtime BEAM did not reject direct invocation')
    print('PASS actual_runtime_BEAM_direct_entrypoint_denied', flush=True)
    # Cross-UID /proc isolation is tested with a harmless writer-UID process.
    # It contains no database secret, and is not an alternate writer entrypoint.
    child = subprocess.Popen(['sudo', '-n', '-u', WRITER, '--', '/usr/bin/sleep', '10'])
    try:
        import time
        for _ in range(50):
            pid = subprocess.run(['pgrep', '-u', WRITER, '-x', 'sleep'],
                text=True, capture_output=True, check=False).stdout.strip()
            if pid.isdigit():
                break
            time.sleep(.02)
        else:
            raise RuntimeError('writer OS process could not be observed')
        run(RUNTIME, ['/usr/bin/cat', f'/proc/{pid}/environ'], expected=1)
        run(RUNTIME, ['/usr/bin/kill', '-0', pid], expected=1)
        print('PASS runtime_cross_UID_environment_read_and_process_control_denied', flush=True)
    finally:
        subprocess.run(['sudo', '-n', '/usr/bin/pkill', '-u', WRITER, '-x', 'sleep'],
                       capture_output=True, check=False)
        child.communicate(timeout=5)


if __name__ == '__main__':
    if sys.argv != [__file__, '--install']:
        raise SystemExit(23)
    install()
