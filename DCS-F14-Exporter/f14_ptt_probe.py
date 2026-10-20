"""Record five seconds of F-14 native (device-provided) UHF/ICS PTT telemetry.

Uses the v0.7.0 OpenFreq DCS exporter, not cockpit argument scanning.
"""
import argparse
import json
import socket
import time
from pathlib import Path


def extract(packet):
    aircraft = packet.get('aircraft') or {}
    cockpit = packet.get('cockpit') or {}
    if not str(aircraft.get('name', '')).startswith('F-14'):
        return None
    native = cockpit.get('native_ptt')
    if not isinstance(native, dict):
        return None
    return {
        'tx': packet.get('selected_tx_radio'),
        'ptt': packet.get('ptt_pressed'),
        'source': cockpit.get('ptt_source'),
        'uhf1': native.get('uhf1'),
        'uhf2': native.get('uhf2'),
        'ics': native.get('ics'),
        'ics_hot_mic': native.get('ics_hot_mic'),
        'pilot_ics_hot_mic_arg': native.get('ics_hot_mic_argument'),
    }


def changes(samples):
    events = []
    last = None
    for sample in samples:
        state = {k:v for k,v in sample.items() if k not in ('t_s', 'source')}
        if state != last:
            events.append(dict(sample))
            last = state
    return events


def label(s):
    trans = {0: 'ICS', 1: 'UHF1', 2: 'UHF2'}
    return f"TX={trans.get(s.get('tx'), 'none')} PTT={s.get('ptt')} | UHF1={s.get('uhf1')} UHF2={s.get('uhf2')} ICS={s.get('ics')} HOT_MIC={s.get('ics_hot_mic')} [{s.get('source')}]"


def record(port=29340, duration_s=5.0):
    counts = {'udp_packets_received':0,'invalid_packets':0,'non_f14_or_missing_native':0}
    samples = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(('127.0.0.1', port))
        sock.settimeout(0.25)
        print(f'Listening on 127.0.0.1:{port}. Enter the F-14 PILOT cockpit.')
        input('Press Enter when ready for 3-second countdown...')
        for remaining in (3, 2, 1):
            print(remaining, flush=True)
            time.sleep(1)
        start = time.monotonic()
        end = start + duration_s
        print(f'RECORDING {duration_s:g} seconds: UHF1, UHF2, ICS press/release!', flush=True)
        while time.monotonic() < end:
            try:
                raw, _ = sock.recvfrom(65535)
            except socket.timeout:
                continue
            counts['udp_packets_received'] += 1
            try:
                packet = json.loads(raw.decode('utf-8'))
            except (ValueError, UnicodeError):
                counts['invalid_packets'] += 1
                continue
            if packet.get('schema') != 'openfreq.dcs.telemetry.v1':
                counts['non_f14_or_missing_native'] += 1
                continue
            parsed = extract(packet)
            if parsed is None:
                counts['non_f14_or_missing_native'] += 1
                continue
            parsed['t_s'] = round(time.monotonic() - start, 3)
            samples.append(parsed)
            if len(samples) == 1 or any(parsed[k] != samples[-2][k] for k in ('tx','ptt','uhf1','uhf2','ics','ics_hot_mic','source')):
                print(f"{parsed['t_s']:.2f}s  {label(parsed)}", flush=True)
    events = changes(samples)
    return {'duration_s': duration_s, **counts, 'native_samples': samples, 'native_events': events}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=29340)
    parser.add_argument('--duration', type=float, default=5.0)
    parser.add_argument('--output', type=Path, default=Path('f14_native_ptt_capture.json'))
    args = parser.parse_args()
    if not (0 < args.duration <= 120):
        parser.error('duration must be between 0 and 120 seconds')
    capture = record(args.port, args.duration)
    args.output.write_text(json.dumps(capture, indent=2), encoding='utf-8')
    print(f"FINISHED: {len(capture['native_samples'])} snapshots, {len(capture['native_events'])} state transitions; saved {args.output}")
    if not capture['native_samples']:
        print('No F-14 native PTT telemetry received; check installed Lua exporter v0.7.0.')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nStopped.')
