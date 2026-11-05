--[[
	FORMULA SIM - project notes (documentation only; requiring this returns nil)

	STATUS: Milestones A-D done (B suspension added in the second handling fix). Next: Milestone E
	(aero/telemetry tuning) and F (validation suite).

	LAYOUT
	  ReplicatedStorage.FormulaSim
	    Shared/   (server + client, pure maths and data)
	      VehicleConfig      every tunable number, SI units
	      UnitConversion     SI <-> engine units, used only at the physics boundary
	      TireModel          combined-slip tyre (slip ratio + slip angle, peak then falloff)
	      SteeringModel      speed-sensitive road-wheel angle (physics-based lock)
	      SuspensionModel    spring / digressive damper / anti-roll bar per corner
	      AeroModel          drag + front/rear downforce
	      BrakeModel         pedal -> brake torque per wheel, bias, optional ABS
	      DifferentialModel  limited-slip rear differential
	      EngineModel        torque curve, rev limiter, engine braking, pedal map
	      TransmissionModel  8 speeds + N + R, final drive, launch clutch, auto/manual shifting
	    Client/   (driver's machine only)
	      InputController     keyboard -> smoothed throttle/brake/steer, action bindings
	      VehicleController   per-step physics: loads, contact, wheel spin, tyre forces
	      CameraController    chase / cockpit
	      TelemetryController HUD + physics debug panel (T)
	    Dev/TestDriver        Studio-only automated driving tests (see its header)
	    Remotes/RequestReset  client asks, server decides
	  ServerStorage.FormulaSim
	    CarBuilder        builds the car from VehicleConfig
	    TestTrackBuilder  regenerates Workspace.FormulaSim.Track
	  ServerScriptService.FormulaSimServer   spawn, seat, ownership, reset, fall recovery
	  StarterPlayer.StarterPlayerScripts.FormulaSimClient  starts/stops a driving session

	CONTROLS
	  W throttle | S brake (28%) | Shift+S brake 100% | A/D steer | E/Q shift (switches to manual)
	  G auto-shift on/off | V traction control | B ABS | T debug panel | C camera | R reset

	UNITS: 1 stud = 0.28 m, 1 RMU = 21.952 kg, 1 force unit = 6.14656 N,
	       1 torque unit = 1.7210368 N*m, Workspace.Gravity = 35.036 stud/s^2 (9.81 m/s^2).

	AUTHORITY MODEL
	  * The seated owner gets network ownership of their car, so physics runs on their client
	    (no input lag). Trade-off: a modified client can alter its own car's motion, so
	    anything competitive (lap times, results, rewards) must be validated on the server
	    later, never taken from the client.
	  * The server owns: spawn slots, resets (rate-limited, owner-only), who may drive which car.

	HANDLING FIX (root causes found in the Milestone A placeholders)
	  1. Drive force requested 131% of rear grip at every speed -> every throttle press
	     saturated the rear tyres. Now: engine torque -> gearbox -> LSD -> wheel spin dynamics.
	  2. 50% brake requested 103% (100% = 206%) of front grip, and keyboard brake was always
	     100% -> braking erased steering. Now: brake torque on wheel spin, S = 35% pedal.
	  3. No wheel speed / slip ratio: forces saturated instantly. Now: implicit wheel spin
	     integration and a combined-slip tyre with progressive post-peak falloff.
	  4. No load transfer, no downforce. Now: quasi-static load transfer + downforce.

	HANDLING FIX 2 ("barely turning spins it")
	  Telemetry showed wheels leaving the ground at curbs / road edges (rigid pads, no
	  suspension) and an all-wheels-airborne launch at a 5 cm grass edge. Fixed with tyre-shaped
	  spherecast suspension (springs, dampers, anti-roll bars); grass edge reduced to 2 cm;
	  physics-based steering lock (enough for the hairpin); aero balance 44% -> 40% front;
	  keyboard steering slower at high speed; S = 28% pedal, brake bias 58%.
	  Pad_XX parts now only hold a parked (unoccupied) car.

	REMAINING SIMPLIFICATIONS
	  * Parallel steer (no Ackermann yet)
	  * Command-bar test tools: Dev/TestDriver (may need inlining if Studio blocks require)

	KNOWN ROBLOX LIMITATIONS
	  * Forces are updated once per PreSimulation step and held across the engine's internal
	    240 Hz substeps; wheel spin is substepped internally (WheelSubsteps).
	  * Workspace.PhysicsSteppingMethod cannot be set from scripts; set it to Fixed manually.
	  * StreamingEnabled is off so the ground under a fast car is always present on the client.
]]
return nil
