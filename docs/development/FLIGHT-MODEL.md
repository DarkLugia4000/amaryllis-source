# Offline flight plant

`tools/flight_model.py` models aggregate raw lift, vertical motion and longitudinal speed. It receives applied commands, integrates deterministic substeps of at most 0.05 s and returns synthetic measurements. It adds no runtime modules to the ship.

Vertical acceleration is `g * (rawLift * pressure / mass - 1 - verticalDrag * verticalSpeed)`. Raw lift follows a delayed first-order response to the bounded target. Longitudinal speed follows applied drive acceleration with linear drag. The pressure implementation reproduces Sable default cubic segments and the upper taper.

The checked-in JSON profile identifies the calibration recording by SHA-256, pressure-source window, ranges, fitting method and residual error. The 627-sample October 24 window selects SABLE AERO. A grid fit of aggregate applied target to filled volume estimates 1 s response and 0 s additional delay, with 362.23 m3 RMS error. These are coarse aggregate estimates limited by recording cadence and the tested grid. They exclude command/ACK delay. The default constructor and scenario overrides are explicit assumptions; controller fallback constants are not calibration evidence.

Prior drag estimates: 5.5 s longitudinal time constant and 0.019 weight per b/s vertical resistance. Their exact fitting windows remain unestablished. Drive acceleration and maximum raw lift are scenario assumptions. Pressure defaults assume standard Overworld settings; live overrides and sampling-height offsets require verification.

Tests check analytic drag, neutral support, constant imbalance, first-order fill, delay, capacity, pressure reference points and timestep convergence. Closed-loop tests execute maintained lift acquisition/hold and selected-speed control. Source and bundled lift traces match. Scenario results are written under `output/tests/flight-model/`.

The 300 to 306, 5 s lag scenario remains below target after 300 simulated seconds; this is a characterization result. The harness transitions to READY at a simplified near-target criterion and supplies aggregate applied-output telemetry directly. It does not exercise the full supervisor, startup sequence, provider allocation, endpoint leases/ramps or vessel rotation. Those require integration tests and physical-flight validation. No gains were changed to improve the model result.
