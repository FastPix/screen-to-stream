#!/bin/bash
# Records a matrix of short clips through the MCP control channel and verifies every produced
# file with ffprobe: video present, and every audio track's duration matches the video's
# (the mic-track N× duplication bug made audio tracks multiples of the real length).
#
# Needs: the app running with "Allow AI agents to control recording" ON, Screen Recording
# permission granted, and ffprobe on PATH. Recordings are saved to the library (no upload)
# and cleaned up afterwards unless --keep is passed.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MCP=".build/ScreenToStream.app/Contents/MacOS/mcp-server"
MOVIES="$HOME/Movies/ScreenToStream"
RECORD_SECONDS="${RECORD_SECONDS:-3}"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

command -v ffprobe >/dev/null || { echo "ffprobe not found (brew install ffmpeg)"; exit 1; }
[[ -x "$MCP" ]] || { echo "mcp-server missing — run ./run.sh first"; exit 1; }

call() { # prints the tool's inner JSON text (e.g. {"accepted":true,...}) or {} on failure
    local tool="$1" args="$2"
    printf '%s\n%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}" \
      | "$MCP" | tail -1 \
      | python3 -c "import sys,json
try: print(json.load(sys.stdin)['result']['content'][0]['text'])
except Exception: print('{}')"
}

accepted() { # accepted <call-output>
    python3 -c "import sys,json
try: sys.exit(0 if json.loads(sys.argv[1]).get('accepted') else 1)
except Exception: sys.exit(1)" "$1"
}

PASS=0; FAIL=0; NEW_FILES=()

run_case() {
    local name="$1" args="$2" expect_audio="$3"   # expect_audio: number of audio tracks
    echo "── case: $name  (args: $args, expect $expect_audio audio track(s))"

    local before; before=$(ls -1 "$MOVIES"/*.mov 2>/dev/null | sort)
    local out; out=$(call start_recording "$args")
    if ! accepted "$out"; then
        echo "   START FAILED: $(echo "$out" | head -c 300)"; FAIL=$((FAIL+1)); return
    fi

    # Wait out warmup+countdown until actually recording, then record for RECORD_SECONDS.
    local state="" tries=0
    while [[ "$state" != "recording" && $tries -lt 40 ]]; do
        sleep 1; tries=$((tries+1))
        state=$(call get_recording_status '{}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
    done
    if [[ "$state" != "recording" ]]; then
        echo "   never reached recording (state=$state)"; FAIL=$((FAIL+1)); return
    fi
    sleep "$RECORD_SECONDS"

    out=$(call stop_recording '{"upload":false}')
    if ! accepted "$out"; then
        echo "   STOP FAILED: $(echo "$out" | head -c 300)"; FAIL=$((FAIL+1)); return
    fi
    sleep 1

    local after; after=$(ls -1 "$MOVIES"/*.mov 2>/dev/null | sort)
    local file; file=$(comm -13 <(echo "$before") <(echo "$after") | head -1)
    if [[ -z "$file" ]]; then
        echo "   NO FILE PRODUCED"; FAIL=$((FAIL+1)); return
    fi
    NEW_FILES+=("$file")

    # Verify with ffprobe. Audio devices spin up ~1s after video starts, so a track may
    # legitimately START late; what must hold is that no track is INFLATED past the video
    # (the N-times mic bug) and no track ENDS early (lost tail). Check end alignment.
    python3 - "$file" "$expect_audio" <<'PY'
import subprocess, sys
file, expect_audio = sys.argv[1], int(sys.argv[2])
out = subprocess.run(["ffprobe","-v","error","-show_entries","stream=codec_type,start_time,duration",
                      "-of","csv=p=0", file], capture_output=True, text=True).stdout
video, audio = [], []
for line in out.strip().splitlines():
    kind, start, dur = line.split(",")
    (video if kind=="video" else audio).append((float(start), float(dur)))
problems = []
if not video: problems.append("no video track")
elif video[0][1] < 1: problems.append(f"video too short ({video[0][1]:.2f}s)")
if len(audio) != expect_audio:
    problems.append(f"expected {expect_audio} audio track(s), found {len(audio)}")
if video:
    v_end = video[0][0] + video[0][1]
    for i, (a_start, a_dur) in enumerate(audio):
        if a_dur > video[0][1] + 1.5:
            problems.append(f"audio[{i}] inflated: {a_dur:.2f}s vs video {video[0][1]:.2f}s ({a_dur/video[0][1]:.2f}x)")
        if abs((a_start + a_dur) - v_end) > 1.5:
            problems.append(f"audio[{i}] end {a_start+a_dur:.2f}s vs video end {v_end:.2f}s (truncated or overlong)")
if problems:
    print("   FAIL: " + "; ".join(problems)); sys.exit(1)
detail = ", ".join(f"start {a:.2f} dur {d:.2f}" for a, d in audio)
print(f"   ok: video {video[0][1]:.2f}s; audio [{detail}]")
PY
    if [[ $? -eq 0 ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}

# The matrix: every toggle combination that changes the pipeline, then repeats for state bugs.
run_case "bare (video only)"        '{"camera":false,"microphone":false,"system_audio":false}' 0
run_case "mic only"                 '{"camera":false,"microphone":true,"system_audio":false}'  1
run_case "system audio only"        '{"camera":false,"microphone":false,"system_audio":true}'  1
run_case "mic + system"             '{"camera":false,"microphone":true,"system_audio":true}'   2
run_case "camera + mic + system"    '{"camera":true,"microphone":true,"system_audio":true}'    2
run_case "repeat 1: mic + system"   '{"camera":false,"microphone":true,"system_audio":true}'   2
run_case "repeat 2: mic + system"   '{"camera":false,"microphone":true,"system_audio":true}'   2
run_case "repeat 3: camera all-on"  '{"camera":true,"microphone":true,"system_audio":true}'    2

echo "──────────────────────────────"
echo "RESULT: $PASS passed, $FAIL failed"

if [[ "$KEEP" -eq 0 && ${#NEW_FILES[@]} -gt 0 ]]; then
    echo "Cleaning up ${#NEW_FILES[@]} test recording(s) (pass --keep to keep them)"
    for f in "${NEW_FILES[@]}"; do rm -f "$f"; done
fi

[[ "$FAIL" -eq 0 ]]
