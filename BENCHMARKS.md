# Benchmarks

EnaltCast (serial and parallel) compared with [SwiftCast](https://wally.run/package/ddust1n/swiftcast) across six projectile workloads.

## Summary

Average FPS at the heaviest load tested (16000 bullets alive at once):

| Scenario | EnaltCast | EnaltCast parallel | SwiftCast |
|---|---:|---:|---:|
| Open air | 119 | **201** | 101 |
| Impacts | 83 | **156** | 78 |
| Gravity arcs | 92 | **177** | 84 |
| Cluttered | 38 | **138** | 60 |
| Short range burst | 100 | **154** | 92 |
| Slow long-lived | 107 | **206** | 96 |

## Test machine

| | |
|---|---|
| CPU | AMD Ryzen 7 7800X3D (8 cores / 16 threads, 4.2 GHz base) |
| GPU | AMD Radeon RX 9070 XT |
| RAM | 32 GB |
| OS | Windows 11 Pro |
| Environment | Roblox Studio, benchmark run as a server script (`bench.project.json`) |

Studio caps the frame rate at 240 FPS, so a reading of 240 means "at the cap", not the true maximum.

## Libraries

| Name | Version | Configuration |
|---|---|---|
| EnaltCast | this repo | `ParallelProcessing = false`, `LagCompensation = false` |
| EnaltCast parallel | this repo | `ParallelProcessing = true`, `LagCompensation = false` |
| SwiftCast | `ddust1n/swiftcast@1.4.1` | default settings |

Every library gets the same speed, gravity, lifetime, max distance and `RaycastParams` (Exclude filter, empty list) for each scenario. No bullet visuals are rendered.

## Scenarios

| Scenario | Speed (studs/s) | Gravity | Lifetime | What it stresses |
|---|---:|---|---:|---|
| Open air | 300 | none | 2 s | Pure stepping cost |
| Impacts | 300 | 1/5 of world gravity | 5 s | Hit detection and cleanup on impact |
| Gravity arcs | 150 | full world gravity | 4 s | Curved trajectories ending in ground hits |
| Cluttered | 300 | 1/5 of world gravity | 5 s | Raycasting through dense geometry |
| Short range burst | 1500 | none | 0.25 s | Cost of creating and removing casts |
| Slow long-lived | 60 | none | 4 s | Per-bullet step cost with a low spawn rate |

## Results

### Open air

| Load | EnaltCast | EnaltCast parallel | SwiftCast |
|---:|---:|---:|---:|
| 250 | 240 / 153 / 0.00 ± 0.00 | 240 / 144 / 0.00 ± 0.00 | 240 / 154 / 0.00 ± 0.00 |
| 500 | 240 / 153 / 0.00 ± 0.00 | 240 / 153 / 0.00 ± 0.00 | 240 / 146 / 0.00 ± 0.00 |
| 1000 | 240 / 152 / 0.00 ± 0.00 | 240 / 156 / 0.00 ± 0.00 | 240 / 133 / 0.00 ± 0.00 |
| 2000 | 240 / 161 / 0.00 ± 0.00 | 240 / 155 / 0.00 ± 0.00 | 240 / 133 / 0.00 ± 0.00 |
| 4000 | 240 / 145 / 0.00 ± 0.00 | 240 / 155 / 0.00 ± 0.00 | 240 / 109 / 0.01 ± 0.00 |
| 8000 | 223 / 142 / 0.00 ± 0.00 | 240 / 141 / 0.00 ± 0.00 | 194 / 109 / 0.00 ± 0.00 |
| 16000 | 119 / 88 / 0.01 ± 0.00 | 201 / 120 / 0.00 ± 0.00 | 101 / 77 / 0.00 ± 0.00 |

Highest load held at ≥ 55 avg FPS across all runs:
- EnaltCast: 16000
- EnaltCast parallel: 16000
- SwiftCast: 16000

### Impacts

| Load | EnaltCast | EnaltCast parallel | SwiftCast |
|---:|---:|---:|---:|
| 250 | 240 / 148 / 0.00 ± 0.00 | 240 / 155 / 0.00 ± 0.00 | 240 / 158 / 0.00 ± 0.00 |
| 500 | 240 / 156 / 0.00 ± 0.00 | 240 / 148 / 0.00 ± 0.00 | 240 / 156 / 0.00 ± 0.00 |
| 1000 | 239 / 138 / 0.00 ± 0.00 | 240 / 150 / 0.00 ± 0.00 | 240 / 145 / 0.00 ± 0.00 |
| 2000 | 240 / 154 / 0.00 ± 0.00 | 240 / 142 / 0.00 ± 0.00 | 240 / 125 / 0.00 ± 0.00 |
| 4000 | 240 / 128 / 0.00 ± 0.00 | 240 / 147 / 0.00 ± 0.00 | 240 / 103 / 0.00 ± 0.00 |
| 8000 | 173 / 109 / 0.00 ± 0.00 | 240 / 139 / 0.00 ± 0.00 | 156 / 102 / 0.00 ± 0.00 |
| 16000 | 83 / 55 / 0.01 ± 0.00 | 156 / 99 / 0.00 ± 0.00 | 78 / 59 / 0.00 ± 0.00 |

Highest load held at ≥ 55 avg FPS across all runs:
- EnaltCast: 16000
- EnaltCast parallel: 16000
- SwiftCast: 16000

### Gravity arcs

| Load | EnaltCast | EnaltCast parallel | SwiftCast |
|---:|---:|---:|---:|
| 250 | 238 / 114 / 0.00 ± 0.00 | 240 / 142 / 0.00 ± 0.00 | 239 / 127 / 0.00 ± 0.00 |
| 500 | 240 / 159 / 0.00 ± 0.00 | 240 / 151 / 0.00 ± 0.00 | 240 / 155 / 0.00 ± 0.00 |
| 1000 | 240 / 152 / 0.00 ± 0.00 | 240 / 160 / 0.00 ± 0.00 | 240 / 140 / 0.00 ± 0.00 |
| 2000 | 240 / 148 / 0.00 ± 0.00 | 240 / 161 / 0.00 ± 0.00 | 240 / 131 / 0.00 ± 0.00 |
| 4000 | 240 / 130 / 0.00 ± 0.00 | 240 / 149 / 0.00 ± 0.00 | 239 / 102 / 0.00 ± 0.00 |
| 8000 | 178 / 109 / 0.00 ± 0.00 | 240 / 139 / 0.00 ± 0.00 | 162 / 103 / 0.00 ± 0.00 |
| 16000 | 92 / 65 / 0.00 ± 0.00 | 177 / 114 / 0.00 ± 0.00 | 84 / 61 / 0.00 ± 0.00 |

Highest load held at ≥ 55 avg FPS across all runs:
- EnaltCast: 16000
- EnaltCast parallel: 16000
- SwiftCast: 16000

### Cluttered

| Load | EnaltCast | EnaltCast parallel | SwiftCast |
|---:|---:|---:|---:|
| 250 | 240 / 156 / 0.00 ± 0.00 | 240 / 157 / 0.00 ± 0.00 | 240 / 162 / 0.00 ± 0.00 |
| 500 | 240 / 160 / 0.00 ± 0.00 | 240 / 158 / 0.00 ± 0.00 | 239 / 128 / 0.00 ± 0.00 |
| 1000 | 240 / 151 / 0.00 ± 0.00 | 240 / 146 / 0.00 ± 0.00 | 240 / 140 / 0.00 ± 0.00 |
| 2000 | 240 / 153 / 0.00 ± 0.00 | 240 / 154 / 0.00 ± 0.00 | 239 / 107 / 0.01 ± 0.00 |
| 4000 | 240 / 145 / 0.00 ± 0.00 | 239 / 128 / 0.00 ± 0.00 | 238 / 103 / 0.01 ± 0.00 |
| 8000 | 133 / 92 / 0.01 ± 0.00 | 240 / 141 / 0.00 ± 0.00 | 124 / 83 / 0.01 ± 0.00 |
| 16000 | 38 / 32 / 0.01 ± 0.00 | 138 / 101 / 0.00 ± 0.00 | 60 / 43 / 0.01 ± 0.00 |

Highest load held at ≥ 55 avg FPS across all runs:
- EnaltCast: 8000
- EnaltCast parallel: 16000
- SwiftCast: 16000

### Short range burst

| Load | EnaltCast | EnaltCast parallel | SwiftCast |
|---:|---:|---:|---:|
| 250 | 240 / 157 / 0.00 ± 0.00 | 239 / 149 / 0.00 ± 0.00 | 240 / 154 / 0.00 ± 0.00 |
| 500 | 240 / 158 / 0.00 ± 0.00 | 240 / 147 / 0.00 ± 0.00 | 237 / 106 / 0.00 ± 0.00 |
| 1000 | 239 / 134 / 0.00 ± 0.00 | 240 / 151 / 0.00 ± 0.00 | 240 / 131 / 0.00 ± 0.00 |
| 2000 | 240 / 150 / 0.00 ± 0.00 | 240 / 157 / 0.00 ± 0.00 | 240 / 133 / 0.00 ± 0.00 |
| 4000 | 240 / 137 / 0.00 ± 0.00 | 240 / 154 / 0.00 ± 0.00 | 240 / 105 / 0.00 ± 0.00 |
| 8000 | 201 / 115 / 0.00 ± 0.00 | 240 / 139 / 0.00 ± 0.00 | 178 / 106 / 0.00 ± 0.00 |
| 16000 | 100 / 66 / 0.01 ± 0.00 | 154 / 107 / 0.00 ± 0.00 | 92 / 67 / 0.00 ± 0.00 |

Highest load held at ≥ 55 avg FPS across all runs:
- EnaltCast: 16000
- EnaltCast parallel: 16000
- SwiftCast: 16000

### Slow long-lived

| Load | EnaltCast | EnaltCast parallel | SwiftCast |
|---:|---:|---:|---:|
| 250 | 240 / 156 / 0.00 ± 0.00 | 240 / 158 / 0.00 ± 0.00 | 240 / 156 / 0.00 ± 0.00 |
| 500 | 240 / 157 / 0.00 ± 0.00 | 240 / 154 / 0.00 ± 0.00 | 240 / 144 / 0.00 ± 0.00 |
| 1000 | 240 / 153 / 0.00 ± 0.00 | 239 / 137 / 0.00 ± 0.00 | 240 / 148 / 0.00 ± 0.00 |
| 2000 | 240 / 155 / 0.00 ± 0.00 | 240 / 146 / 0.00 ± 0.00 | 240 / 132 / 0.00 ± 0.00 |
| 4000 | 240 / 136 / 0.00 ± 0.00 | 240 / 145 / 0.00 ± 0.00 | 240 / 108 / 0.00 ± 0.00 |
| 8000 | 201 / 130 / 0.00 ± 0.00 | 240 / 145 / 0.00 ± 0.00 | 181 / 110 / 0.00 ± 0.00 |
| 16000 | 107 / 76 / 0.00 ± 0.00 | 206 / 140 / 0.00 ± 0.00 | 96 / 74 / 0.00 ± 0.00 |

Highest load held at ≥ 55 avg FPS across all runs:
- EnaltCast: 16000
- EnaltCast parallel: 16000
- SwiftCast: 16000

## Running it yourself

```sh
wally install
rojo serve bench.project.json
```

Connect Roblox Studio to the Rojo server and press **Run**. Results print to the output window when each scenario finishes. A full run takes roughly 30–45 minutes. To run a subset, set `OnlyScenarios`, `OnlyEntries` or `Runs` in `CONFIG` at the top of [bench/server/Benchmark.server.luau](bench/server/Benchmark.server.luau).
