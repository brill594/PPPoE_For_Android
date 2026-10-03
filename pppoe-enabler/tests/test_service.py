"""Offline regressions: all generated paths and networking are isolated/mocked."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SERVICE = Path(__file__).resolve().parents[1] / 'service.sh'


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = SERVICE.read_text()
        functions = source[source.index('rotate_log()'):source.index('main_loop()')]
        functions = functions.replace('/data/local/tmp', str(self.root))
        self.script = self.root / 'functions.sh'
        self.script.write_text('''set -eu
umask 077
log() { printf '%s\\n' "$*" >&2; }
DEFAULT_MTU=1492; DEFAULT_MRU=1492
MTU_MIN=576; MTU_MAX=1492; MRU_MIN=576; MRU_MAX=1492
MODDIR="$TEST_ROOT"
LOG_FILE="$TEST_ROOT/pppoe.log"; PIDFILE="$TEST_ROOT/daemon.pid"
DAEMON_PID=""
PEER_ENV="$TEST_ROOT/peer.env"; LOCKDIR="$TEST_ROOT/lock"
MTU_FILE="$TEST_ROOT/mtu"; MRU_FILE="$TEST_ROOT/mru"
''' + functions)

    def run_shell(self, script, **env):
        return subprocess.run(['sh', '-c', '. "$TEST_ROOT/functions.sh"\n' + script],
                              env={**os.environ, 'TEST_ROOT': str(self.root), **env},
                              text=True, capture_output=True, check=True)

    def test_mtu_fallback_output_is_only_numbers(self):
        result = self.run_shell('resolve_mtu_mru')
        self.assertEqual(result.stdout, '1492 1492\n')
        self.assertEqual(result.stderr, '')

    def test_malformed_and_overflow_values_are_rejected(self):
        for value in ['14x00', '999999999999999999999999999999', '575']:
            (self.root / 'mtu').write_text(value)
            self.assertEqual(self.run_shell('resolve_mtu_mru').stdout, '1492 1492\n')

    def test_mru_is_clamped_without_polluting_result(self):
        (self.root / 'mtu').write_text('1400')
        (self.root / 'mru').write_text('1492')
        self.assertEqual(self.run_shell('resolve_mtu_mru').stdout, '1400 1400\n')

    def test_hooks_use_peer_dns_environment_and_preserve_main_routes(self):
        self.run_shell('make_hooks')
        ip = self.root / 'ip'
        ip.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$TEST_ROOT/ip.log"
case "$*" in
  'route show'*) echo 'default dev ppp0';;
  'rule show') echo '10000: from all lookup 10000';;
esac
''')
        ip.chmod(0o755)
        env = {**os.environ, 'TEST_ROOT': str(self.root), 'PATH': f'{self.root}:{os.environ["PATH"]}',
               'DNS1': '1.1.1.1', 'DNS2': '8.8.8.8'}
        subprocess.run(['sh', str(self.root / 'hooks/ip-up.sh'), 'ppp0', 'tty', '0',
                        '10.0.0.2', '10.0.0.1', 'not-dns-ipparam'], env=env, check=True)
        peer = (self.root / 'pppoe_peer.env').read_text()
        self.assertIn('event=peer_up iface=ppp0 local=10.0.0.2', (self.root / 'pppoe.log').read_text())
        self.assertIn('DNS1=1.1.1.1', peer)
        self.assertIn('DNS2=8.8.8.8', peer)
        self.assertNotIn('not-dns', peer)
        subprocess.run(['sh', str(self.root / 'hooks/ip-down.sh'), 'ppp0'], env=env, check=True)
        commands = (self.root / 'ip.log').read_text().splitlines()
        self.assertIn('route replace default dev ppp0 table 10000', commands)
        self.assertIn('route del default dev ppp0 table 10000', commands)
        self.assertIn('rule del pref 10000 lookup 10000', commands)
        self.assertNotIn('rule add pref 10000 lookup 10000', commands)
        self.assertTrue(all('table 10000' in line for line in commands if line.startswith('route del')))
        self.assertEqual((self.root / 'pppoe_peer.env').read_text(), 'IF=\n')

    def test_route_failure_never_publishes_peer_up(self):
        self.run_shell('make_hooks')
        ip = self.root / 'ip'
        ip.write_text('#!/bin/sh\nexit 1\n')
        ip.chmod(0o755)
        env = {**os.environ, 'TEST_ROOT': str(self.root),
               'PATH': f'{self.root}:{os.environ["PATH"]}'}
        result = subprocess.run(['sh', str(self.root / 'hooks/ip-up.sh'), 'ppp0', 'tty', '0',
                                 '10.0.0.2', '10.0.0.1'], env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'pppoe_peer.env').exists())
        log = (self.root / 'pppoe.log').read_text()
        self.assertIn('event=route_setup_failed step=route', log)
        self.assertNotIn('event=peer_up', log)

    def test_rule_failure_never_publishes_peer_up(self):
        self.run_shell('make_hooks')
        ip = self.root / 'ip'
        ip.write_text('#!/bin/sh\ncase "$*" in "rule add"*) exit 1;; esac\n')
        ip.chmod(0o755)
        env = {**os.environ, 'TEST_ROOT': str(self.root),
               'PATH': f'{self.root}:{os.environ["PATH"]}'}
        result = subprocess.run(['sh', str(self.root / 'hooks/ip-up.sh'), 'ppp0', 'tty', '0',
                                 '10.0.0.2', '10.0.0.1'], env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'pppoe_peer.env').exists())
        self.assertIn('event=route_setup_failed step=rule', (self.root / 'pppoe.log').read_text())

    def test_stop_never_reports_an_unexpected_daemon_exit(self):
        result = self.run_shell('''
owned_pid() { return 1; }
ip() { return 0; }
PEER_ENV="$TEST_ROOT/peer.env"; LOCKDIR="$TEST_ROOT/lock"
sh -c 'exit 0' &
DAEMON_PID=$!
printf '%s\\n' "$DAEMON_PID" > "$PIDFILE"
stop_pppoe
reap_daemon
''')
        self.assertIn('event=stopped', result.stderr)
        self.assertNotIn('event=daemon_exit', result.stderr)

    def test_daemon_exit_reports_actual_status_exactly_once(self):
        result = self.run_shell('''
owned_pid() { return 1; }
ip() { return 0; }
sh -c 'exit 19' &
DAEMON_PID=$!
reap_daemon
reap_daemon
''')
        self.assertEqual(result.stderr.count('event=daemon_exit'), 1)
        self.assertIn('exit=19', result.stderr)

    def test_unexpected_exit_clears_stale_connected_state_and_only_owned_routes(self):
        (self.root / 'peer.env').write_text('IF=ppp0\nIPLOCAL=10.0.0.2\n')
        (self.root / 'ppp.options').write_text('private daemon options')
        (self.root / 'lock').mkdir()
        result = self.run_shell('''
owned_pid() { return 1; }
ip() { printf '%s\\n' "$*" >> "$TEST_ROOT/ip.log"; }
kill() { echo unexpected-signal >&2; return 1; }
sh -c 'exit 9' &
DAEMON_PID=$!
printf '%s\\n' "$DAEMON_PID" > "$PIDFILE"
reap_daemon
reap_daemon
''')
        self.assertEqual(result.stderr.count('event=daemon_exit'), 1)
        self.assertIn('exit=9', result.stderr)
        self.assertNotIn('event=stopped', result.stderr)
        self.assertNotIn('unexpected-signal', result.stderr)
        self.assertEqual((self.root / 'peer.env').read_text(), 'IF=\n')
        self.assertFalse((self.root / 'daemon.pid').exists())
        self.assertFalse((self.root / 'ppp.options').exists())
        self.assertFalse((self.root / 'lock').exists())
        self.assertEqual((self.root / 'ip.log').read_text().splitlines(), [
            'route del default dev ppp0 table 10000',
            'rule del pref 10000 lookup 10000',
            'route flush cache',
        ])

    def test_log_rotation_preserves_open_append_descriptor(self):
        logfile = self.root / 'pppoe.log'
        logfile.write_text('x' * 1048577)
        inode = logfile.stat().st_ino
        self.run_shell('exec 3>> "$LOG_FILE"; rotate_log; echo after-rotation >&3')
        self.assertEqual(logfile.stat().st_ino, inode)
        self.assertEqual(logfile.read_text(), 'after-rotation\n')
        self.assertEqual((self.root / 'pppoe.log.1').stat().st_size, 1048577)

    def test_option_credentials_cannot_be_parsed_as_extra_options(self):
        source = SERVICE.read_text()
        start = source.index('  # pppd parses')
        end = source.index('  chmod 0600 "$OPTFILE"', start)
        writer = source[start:end].replace('/data/local/tmp', str(self.root))
        self.run_shell(
            'PPPOE_PLUGIN=plugin; IFACE=eth0; MTU=1492; MRU=1492; '
            'IP_UP=up; IP_DOWN=down; LOG_FILE=log\n' + writer,
            USERNAME='user "name" #comment', PASSWORD='a\\b "c" #debug')
        options = (self.root / 'ppp.options').read_text()
        self.assertIn('user "user \\"name\\" #comment"\n', options)
        self.assertIn('password "a\\\\b \\"c\\" #debug"\n', options)
        self.assertIn('logfd 2\n', options)
        self.assertNotIn('logfile ', options)
        self.assertNotIn('\ndebug\n', options)
        self.assertEqual((self.root / 'ppp.options').stat().st_mode & 0o777, 0o600)

    def test_invalid_pids_cannot_target_process_groups(self):
        for pid in ['', '0', '1', '-1', 'anything']:
            result = self.run_shell('if owned_pid "$BAD_PID"; then exit 1; fi', BAD_PID=pid)
            self.assertEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
