# ShikiMusic performance scenarios

Use the same build mode, machine, OS, driver, fixtures, and app settings for
baseline and candidate runs. User-reported RAM values are context only; pass/fail
must come from schema v1 JSON and `evaluate.*`.

Required fixtures:

- H.264 MP4, 480p-or-lower source, 30 FPS.
- H.264 MP4, 480p-or-lower source, 60 FPS.
- Large MP3/MP4 download fixture for bounded-memory checks.

Required scenario ids:

1. `cold-start-server-offline`
2. `idle-home-five-minutes`
3. `audio-only-ten-minutes`
4. `local-video-30fps-ten-minutes`
5. `local-video-60fps-ten-minutes`
6. `minimize-video-five-minutes-restore`
7. `large-mp3-mp4-download`
8. `rapid-track-switch-20`
9. `lyrics-blur-five-minutes`
10. `video-enable-disable-30`

Required metrics, where applicable:

- `rssMiB`: required, compare `median`, max regression 5%.
- `cpuPercent`: required, compare `median`, max regression 10%.
- `missedFrameRatioPercent`: required for visible UI/video scenarios, compare `p95`, max absolute 1.
- `firstVideoFrameMs`: required for restore scenarios, compare `p95`, target 500, failure above 1000.
- `hiddenFlutterFrames`: required for hidden/minimized scenarios, max absolute 0.
- `decoderEvidence`: required for video scenarios when backend claims hardware decode.

Exit contract:

- `0`: pass.
- `1`: measured regression.
- `2`: infrastructure problem or missing mandatory metric.

Example:

```powershell
pwsh tool/perf/evaluate.ps1 -Baseline .omx/perf/baseline.json -Candidate .omx/perf/after-phase0.json -Platform windows
```

```bash
bash tool/perf/evaluate_linux.sh --baseline .omx/perf/baseline.json --candidate .omx/perf/after-phase0.json
```
