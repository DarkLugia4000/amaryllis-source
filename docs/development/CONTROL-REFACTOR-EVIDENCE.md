# Control refactoring evidence

The six Delivery 6 extractions retain the established control equations, branch order, command paths and provider-write routines. Before each extraction, the maintained test harness captured its outputs and state transitions in `tests/fixtures/control-stage-baseline.json`. The regression tests compare against that fixed baseline.

## Function boundaries

Line counts include each function's body and declaration. They measure the entry function, with its extracted helpers counted separately in the source.

| Entry function | Before | After | Extracted work |
|---|---:|---:|---|
| `Thrust:speedDriveRequest` | 296 | 67 | SEL 0 braking, output progression, speed feedback and learning |
| `IO:sampleVessel` | 363 | 72 | Bounded reads, attitude, velocity and environment resolution |
| `Flight:systemsControlTargets` | 328 | 10 | Support demand, braking budgets, motion progress and provider allocation |
| `Flight:systemsAcquisitionControl` | 521 | 70 | Vertical demand, speed effort, support demand and stall correction |
| `Flight:updateSystemsRecovery` | 347 | 192 | Retained-map verification, batch renewal and recovery completion |
| `Flight:updateSystems` | 493 | 103 | Command acknowledgement, startup verification, settling and active control |

`IO:sampleVessel` also has an existing eight-line wrapper; that wrapper remains. Each helper has a purpose summary. The scope correction for the missing-bulk-data acquisition fallback preceded these extractions and has its own regression test.

## Behavioral comparisons

`tests/test_control_stages.py` exercises the maintained functions with explicit synthetic hardware and transport:

- Five vessel-sampling cases compare resolved values, cache behavior and getter order.
- Fifty allocation steps compare provider maps, correction direction, capacity flags and fractional remainders.
- Thirty-six recovery transitions compare retained maps, command batches, lease renewal, delayed acknowledgements and reconciliation.
- Thirty systems-dispatch cases compare phases, pending commands, startup decisions, target changes and controller state.
- Aggregate acquisition/hold scenarios, selected-speed scenarios and an 80-row recorded-input replay compare source and generated-bundle results with the pre-extraction traces.

The Cobalt harness also executes the sampling, allocation, recovery and systems-dispatch fixtures. It compares finite numbers with a small numeric tolerance and compares the remaining values structurally. These fixtures isolate the relevant components. They do not simulate every Minecraft peripheral or a complete vessel.

## Offline cost measurements

Measurements use Lupa's Lua 5.2 engine, five repetitions and identical synthetic inputs. Allocation is measured with garbage collection paused. Checksums match before and after. The JSON records are under `output/tests/control-stages/`.

| Work per run | Before median | After median | Allocated KiB before / after |
|---|---:|---:|---:|
| 1,500 selected-speed calculations | 52.62 ms | 30.70 ms | 4,936.98 / 4,936.98 |
| 300 snapshot + heading-payload + CSV-row constructions | 109.90 ms | 107.78 ms | 24,145.66 / 24,145.66 |
| 1,000 provider-allocation calculations, including case setup | 54.78 ms | 57.72 ms | 4,628.33 / 5,933.09 |
| 1,000 acquisition calculations with fixed synthetic telemetry | 40.79 ms | 45.27 ms | 3,769.45 / 5,074.22 |

The two lift calculations each create one additional transient demand table, approximately 1.3 KiB per call in this engine. The other measured paths retain their allocation totals. Host timing varies, so the faster selected-speed result is not evidence of a corresponding flight-performance improvement. These measurements exclude Minecraft scheduling, peripheral waits, endpoint response and recording disk writes.

No output caching, sampling-rate change or controller retuning was introduced from these measurements.

## Acceptance boundary

Compilation, bundle round-trip checks, characterization fixtures and synthetic closed-loop scenarios provide offline evidence. Physical flight acceptance remains outstanding. The plant's slow high-altitude acquisition scenario remains recorded as a limitation; it was not retuned to pass a target-reaching assertion. Pressure-call integration remains a separate investigation documented in [pressure evidence](../diagnostics/PRESSURE-EVIDENCE.md).
