"""Sample an actual local file and verify Core policy separately from rendering."""
import argparse
import ctypes
import json
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--media', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--core', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    media = args.media.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    samples = []

    def sample(label, start, hardware):
        command = [str(args.probe.resolve(strict=True)), str(media), str(start), '8']
        if hardware:
            command.append('hardware')
        with (output / f'decode-{label}.log').open('w', encoding='utf-8') as log:
            process = subprocess.run(command, stdout=subprocess.PIPE, stderr=log,
                                     text=True, encoding='utf-8', timeout=120)
        (output / f'decode-{label}.json').write_text(process.stdout, encoding='utf-8')
        if process.returncode:
            raise RuntimeError(f'{label} decode failed: {process.returncode}')
        value = json.loads(process.stdout)
        if value['errors'] or value['emptyStreams']:
            raise RuntimeError(f'{label} returned failed/empty decode streams')
        expected_ids = {stream['index'] for stream in value['streams']
                        if stream['type'] in ('video', 'audio')}
        if {row['stream'] for row in value['decode']} != expected_ids:
            raise RuntimeError(f'{label} did not decode every audio/video stream')
        video_ids = {stream['index'] for stream in value['streams'] if stream['type'] == 'video'}
        if hardware and any(row['hardwareFrames'] != row['frames'] for row in value['decode']
                            if row['stream'] in video_ids):
            raise RuntimeError(f'{label} did not use hardware for every video frame')
        value['label'] = label
        samples.append(value)
        print(json.dumps({'sample': label, 'elapsed': value['elapsedSeconds'],
                          'decode': value['decode']}), flush=True)
        return value

    first = sample('start-software', 0, False)
    duration = first['durationSeconds']
    for label, start in [('start', 0), ('middle', duration / 2), ('end', max(0, duration - 8))]:
        sample(label + '-hardware', start, True)
        if label != 'start':
            sample(label + '-software', start, False)

    ffi = ctypes.CDLL(str(args.core.resolve(strict=True)))
    ffi.ocp_core_create.argtypes = [ctypes.c_char_p]
    ffi.ocp_core_create.restype = ctypes.c_void_p
    ffi.ocp_core_destroy.argtypes = [ctypes.c_void_p]
    ffi.ocp_call.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    ffi.ocp_call.restype = ctypes.c_void_p
    ffi.ocp_snapshot.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    ffi.ocp_snapshot.restype = ctypes.c_void_p
    ffi.ocp_string_free.argtypes = [ctypes.c_void_p]
    receipts = []
    with tempfile.TemporaryDirectory(prefix='ocp-real-video-') as temp:
        core = ffi.ocp_core_create(json.dumps({'dataDirectory': temp}).encode())
        if not core:
            raise RuntimeError('Core constructor failed')

        def take(pointer):
            if not pointer:
                raise RuntimeError('Core returned null')
            try:
                return json.loads(ctypes.string_at(pointer).decode('utf-8'))
            finally:
                ffi.ocp_string_free(pointer)

        def call(method, **arguments):
            result = take(ffi.ocp_call(core, method.encode(), json.dumps(arguments).encode()))
            receipts.append({'method': method, 'arguments': arguments, 'response': result})
            if not result['ok']:
                raise RuntimeError(f'{method} failed: {result}')
            return result['data']

        try:
            parsed = call('danmaku.parseFilename', fileName=media.name)
            call('playback.open', source=str(media))
            call('playback.ready', durationSeconds=duration)
            call('playback.play')
            for value in samples:
                video_ids = {stream['index'] for stream in value['streams'] if stream['type'] == 'video'}
                decoded_video = next(row for row in value['decode'] if row['stream'] in video_ids)
                call('playback.seek', positionSeconds=decoded_video['firstPTS'])
                call('playback.position', positionSeconds=decoded_video['lastPTS'])
                retained = take(ffi.ocp_snapshot(core, b'playback'))
                assert retained['source'] == str(media)
                assert abs(retained['positionSeconds'] - decoded_video['lastPTS']) < 1e-6
                assert retained['durationSeconds'] == duration
            call('playback.pause')
            paused = take(ffi.ocp_snapshot(core, b'playback'))
            assert paused['state'] == 'paused'
            for audio in (stream for stream in first['streams'] if stream['type'] == 'audio'):
                call('playback.selectAudio', trackId=str(audio['index']))
                retained = take(ffi.ocp_snapshot(core, b'playback'))
                assert retained['audioTrack'] == str(audio['index'])
            call('playback.play')
            call('progress.save', tenantId='local-video-test', itemId=media.name,
                 positionSeconds=paused['positionSeconds'], durationSeconds=duration,
                 played=False, recordedAt=time.time(), completed=False)
            progress = call('progress.get', tenantId='local-video-test', itemId=media.name)
            assert progress['progress']['positionSeconds'] == paused['positionSeconds']
            assert progress['progress']['durationSeconds'] == duration
            call('playback.stop')
            final = take(ffi.ocp_snapshot(core, b'playback'))
            assert final['state'] == 'stopped'
            ffi.ocp_core_destroy(core)
            core = None
            core = ffi.ocp_core_create(json.dumps({'dataDirectory': temp}).encode())
            if not core:
                raise RuntimeError('Core reopen failed')
            reopened = call('progress.get', tenantId='local-video-test', itemId=media.name)
            assert reopened == progress
        finally:
            if core:
                ffi.ocp_core_destroy(core)
            (output / 'core-sample-receipts.json').write_text(
                json.dumps(receipts, indent=2, ensure_ascii=False), encoding='utf-8')

    summary = {'media': str(media), 'durationSeconds': duration, 'streams': first['streams'],
               'samples': samples, 'core': {'commandsPassed': len(receipts),
                 'filename': parsed, 'progress': progress, 'finalSnapshot': final,
                 'scope': 'Core policy exercised after independent decoding; no integrated native/Core player'}}
    (output / 'sample-results.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding='utf-8')
    print(json.dumps({'samplesPassed': len(samples), 'coreCommandsPassed': len(receipts)}), flush=True)


if __name__ == '__main__':
    main()
