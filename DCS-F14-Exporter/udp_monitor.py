"""Monitor OpenFreq F-14A/B radio telemetry and native Heatblur PTT."""
import argparse
import json
import socket
import time


def describe(packet):
    aircraft = packet.get('aircraft') or {}
    radios = packet.get('radios') or []

    def hz(value):
        return f'{value / 1e6:.3f} MHz' if isinstance(value, (int, float)) and not isinstance(value, bool) else 'UNKNOWN'

    states = []
    for radio in radios:
        power = radio.get('power_on')
        power_s = 'ON' if power is True else ('OFF' if power is False else '?')
        vol = radio.get('volume')
        vol_s = f' VOL={vol * 100:.0f}%' if isinstance(vol, (int, float)) and not isinstance(vol, bool) else ''
        states.append(f"{radio.get('name')}: {hz(radio.get('frequency_hz'))} {radio.get('modulation') or '?'} [{power_s}]{vol_s}")
    if not states:
        states = [packet.get('radio_export_status', 'unknown')]

    tx = packet.get('selected_tx_radio')
    ptt = packet.get('ptt_pressed')
    source = (packet.get('cockpit') or {}).get('ptt_source', 'unavailable')
    tx_name = {0: 'ICS', 1: 'UHF1', 2: 'UHF2'}.get(tx, 'None')
    suffix = f'TX={tx_name} PTT={ptt} ({source})'
    native = (packet.get('cockpit') or {}).get('native_ptt')
    if isinstance(native, dict):
        suffix += f" | PTT_STATE[UHF1={native.get('uhf1')}, UHF2={native.get('uhf2')}, ICS={native.get('ics')}]"
        if native.get('ics_hot_mic') is True:
            suffix += ' | ICS HOT MIC'
    if ptt is True and tx in (1, 2):
        radio = next((r for r in radios if r.get('id') == tx), None)
        if radio is None or radio.get('power_on') is not True:
            suffix += ' [WARNING: selected radio OFF/UNKNOWN]'
    return f"{aircraft.get('name') or 'NO AIRCRAFT'} | " + ' | '.join(states) + ' | ' + suffix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=29340)
    parser.add_argument('--json', action='store_true', help='Print packets including diagnostic argument values')
    args = parser.parse_args()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(('127.0.0.1', args.port))
        sock.settimeout(1)
        print(f'Listening for DCS telemetry at 127.0.0.1:{args.port}')
        last_state = None
        last_print_at = 0.0
        last_rx_at = time.monotonic()
        while True:
            try:
                raw, _peer = sock.recvfrom(65535)
            except socket.timeout:
                if time.monotonic() - last_rx_at >= 5:
                    print('No DCS telemetry received in the past 5 seconds.')
                    last_rx_at = time.monotonic()
                continue
            try:
                packet = json.loads(raw.decode('utf8'))
            except (ValueError, UnicodeError):
                continue
            if packet.get('schema') != 'openfreq.dcs.telemetry.v1':
                continue
            last_rx_at = time.monotonic()
            if args.json:
                print(json.dumps(packet, sort_keys=True))
                continue
            rendered = describe(packet)
            now = time.monotonic()
            if rendered != last_state or now - last_print_at > 5:
                print(rendered)
                last_state = rendered
                last_print_at = now


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nStopped.')
