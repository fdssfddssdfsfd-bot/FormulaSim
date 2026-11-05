--!strict
--[[
	VehicleConfig  (Shared)
	Every tunable number for the car lives here, in SI units unless the name says otherwise.
	Nothing in this file is engine-specific; UnitConversion converts at the physics boundary.

	All major subsystems are physical models now (suspension, tyres, brakes, engine, gearbox,
	differential, aero). Steering is still parallel (Ackermann not yet modelled).
]]

local VehicleConfig = {
	Name = "FS-01 Prototype",

	Mass = {
		TotalKg = 798, -- car + driver
		FrontWeightFraction = 0.45, -- static share of weight on the front axle
		CgHeightM = 0.30, -- centre of mass height above ground at static ride height
		-- All mass is carried by one invisible box centred on the CoM. Its dimensions set the
		-- inertia tensor (I = m(b^2+c^2)/12): yaw ~1110, pitch ~970, roll ~160 kg*m^2.
		InertiaBoxM = Vector3.new(1.5, 0.4, 3.8), -- X width, Y height, Z length
	},

	Geometry = {
		WheelbaseM = 3.60,
		FrontTrackM = 1.60, -- wheel-centre to wheel-centre
		RearTrackM = 1.55,
		FrontTireRadiusM = 0.36,
		RearTireRadiusM = 0.36,
		FrontTireWidthM = 0.305,
		RearTireWidthM = 0.405,
	},

	Suspension = {
		-- Spherecast (tyre-shaped) suspension: the probe is a sphere of tyre radius, so the
		-- wheel rolls over curb and road edges instead of hitting them as vertical steps.
		-- Ride frequency ~3.3 Hz, chosen so the 60 Hz force update stays stable.
		Front = { SpringNPerM = 80000, BumpNsPerM = 4500, ReboundNsPerM = 5500, AntiRollNPerM = 60000 },
		Rear = { SpringNPerM = 90000, BumpNsPerM = 5000, ReboundNsPerM = 6000, AntiRollNPerM = 20000 },
		MaxCompressionM = 0.07, -- bump travel above static ride height
		MaxDroopM = 0.06, -- rebound travel below static ride height
		ProbeStartAboveM = 0.12, -- spherecast starts this far above the wheel centre (must exceed MaxCompression)
		DamperKneeMs = 0.25, -- above this shaft speed the damper is digressive (blow-off)
		DamperHighSpeedFactor = 0.3, -- slope above the knee, as a share of the low-speed slope
		MaxForceFactor = 4, -- spring+damper force limited to this multiple of static corner load
		DesignFrameRate = 60, -- damping is scaled down at lower frame rates to stay stable
	},

	Collision = {
		BodyClearanceM = 0.08, -- floor clearance at static ride height (bottoming = body contact)
		-- Parking pads: rigid spheres at the wheels that hold an UNOCCUPIED car. They are
		-- non-colliding while someone drives (the suspension carries the car then).
		ParkedPadFriction = 2,
	},

	Steering = {
		-- Full-input lock follows what the car can actually use at each speed:
		--   lock(v) = wheelbase * ReferenceLatG * g / v^2  +  slip margin
		-- (kinematic angle for a ReferenceLatG corner + room to reach peak tyre slip).
		-- ~21 deg at 55 km/h (hairpin), ~8 deg at 110 km/h, ~3 deg at 300 km/h.
		MaxRoadWheelAngleDeg = 22,
		MinRoadWheelAngleDeg = 2,
		WheelbaseM = 3.60,
		ReferenceLatG = 2.0,
		LowSpeedSlipMarginDeg = 4,
		HighSpeedSlipMarginDeg = 2,
		MarginBlendSpeedMs = 30,
	},

	Tire = {
		-- Combined-slip model with wheel spin dynamics (equations in TireModel).
		-- Peak grip occurs at PeakSlipRatio / PeakSlipAngleDeg; past the peak, grip falls
		-- progressively to the sliding level set by ShapeC.
		Front = {
			Mu = 1.60,
			PeakSlipRatio = 0.10,
			PeakSlipAngleDeg = 6.5,
			RollingResistance = 0.015,
			WheelInertiaKgM2 = 1.2, -- wheel + tyre + brake disc
		},
		Rear = {
			Mu = 1.65, -- wider rear tyre
			PeakSlipRatio = 0.10,
			PeakSlipAngleDeg = 6.0,
			RollingResistance = 0.015,
			WheelInertiaKgM2 = 1.3, -- wheel + tyre + brake disc (engine inertia is added via the gearbox)
		},
		ShapeC = 1.35, -- sliding grip = sin(C * pi/2) = 85% of peak
		LoadSensitivity = 0.08, -- grip coefficient falls 8% per +100% load above nominal
		NominalLoadN = 2000,
		LowSpeedMs = 5, -- slip maths uses max(|v|, this) as reference speed
		LowSpeedRelaxationS = 0.1, -- lateral velocity-damping hold time constant near standstill
		OvershootSafety = 0.5, -- a tyre force may cancel at most this share of slip velocity per step
		WheelSubsteps = 4, -- wheel spin integration substeps per physics step (implicit)
	},

	Telemetry = {
		AccelFilterS = 0.06, -- smoothing of the g-force estimate
	},

	Engine = {
		-- Combined power unit, peak ~700 kW (~940 hp) at 11,500-12,000 rpm.
		IdleRpm = 4000,
		LaunchRpm = 7000, -- clutch-slip engine speed at full throttle from standstill
		LimiterRpm = 13000,
		TorqueCurve = {
			{ 4000, 300 },
			{ 6000, 420 },
			{ 8000, 520 },
			{ 10000, 590 },
			{ 11000, 600 },
			{ 12000, 560 },
			{ 13000, 500 },
		},
		EngineBrakeNm = 60, -- closed-throttle drag torque at the limiter
		InertiaKgM2 = 0.05, -- crank + flywheel + clutch
		PedalMapExponent = 1.8, -- progressive torque map: 50% pedal = 29% torque, 100% = 100%
	},

	Transmission = {
		Ratios = { 6.20, 5.16, 4.30, 3.58, 2.98, 2.48, 2.07, 1.72 }, -- 1st ~95 km/h, 8th ~340 km/h at limiter
		ReverseRatio = 6.0,
		FinalDrive = 3.0,
		Efficiency = 0.92,
		ShiftTimeS = 0.05,
		AutoShift = true, -- pressing E/Q switches to manual; G toggles automatic
		AutoUpshiftRpm = 12500,
		AutoDownshiftRpm = 7500,
		AutoMinShiftIntervalS = 0.4,
	},

	Differential = {
		-- Limited-slip approximation: torque moves from the faster to the slower rear wheel.
		ViscousNmPerRadS = 25,
		PreloadNm = 50,
		LockRatio = 0.25, -- max transferred torque as a share of input torque (+ preload)
	},

	Brakes = {
		MaxTotalTorqueNm = 9000, -- all four wheels at 100% pedal
		FrontBias = 0.58,
	},

	Assists = {
		ABS = false, -- toggle in game (default B)
		-- TC defaults ON for keyboard play: a digital key cannot feather ~940 hp. With TC off
		-- (V), full throttle in gears 1-3 mid-corner spins the car, as it would in reality.
		TC = true, -- toggle in game (default V)
		AbsSlipTarget = 0.12,
		AbsReleaseRate = 25,
		AbsApplyRate = 8,
		TcSlipTarget = 0.12, -- allows wheelspin slightly past the grip peak
		TcRate = 6, -- torque cut per second per unit of normalised excess slip
		TcRecoverRate = 3, -- torque restored per second once slip is below target
	},

	Aero = {
		AirDensityKgM3 = 1.225,
		DragAreaCdA = 1.25, -- Cd * frontal area, m^2
		DownforceAreaFront = 1.35, -- Cl * A, m^2, applied at the front axle (aero balance ~40% front)
		DownforceAreaRear = 2.05, -- Cl * A, m^2, applied at the rear axle
	},

	Input = {
		Bindings = {
			Throttle = { Enum.KeyCode.W, Enum.KeyCode.Up },
			Brake = { Enum.KeyCode.S, Enum.KeyCode.Down },
			SteerLeft = { Enum.KeyCode.A, Enum.KeyCode.Left },
			SteerRight = { Enum.KeyCode.D, Enum.KeyCode.Right },
			BrakeFull = { Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift }, -- hold with Brake for 100%
			ShiftUp = { Enum.KeyCode.E },
			ShiftDown = { Enum.KeyCode.Q },
			Reset = { Enum.KeyCode.R },
			Camera = { Enum.KeyCode.C },
			ToggleDebug = { Enum.KeyCode.T },
			ToggleABS = { Enum.KeyCode.B },
			ToggleTC = { Enum.KeyCode.V },
			ToggleAutoShift = { Enum.KeyCode.G },
		},
		-- Keyboard smoothing, in full-scale units per second.
		ThrottleRiseRate = 1.5, -- 0.67 s to full throttle (a driver's foot, not a switch)
		ThrottleFallRate = 8,
		BrakeRiseRate = 5,
		BrakeFallRate = 10,
		KeyboardBrakeLevel = 0.28, -- pedal for Brake alone (no inside-front lock in a ~1 g corner); Brake + BrakeFull = 100%
		SteerRate = 2.5, -- at low speed
		SteerRateHighSpeed = 1.2, -- keyboard steering slows down as speed rises...
		SteerRateBlendSpeedMs = 60, -- ...reaching SteerRateHighSpeed at this speed (216 km/h)
		SteerReturnRate = 4,
	},

	Camera = {
		Chase = {
			DistanceM = 6.5,
			HeightM = 1.9,
			LookAheadM = 4,
			LookHeightM = 0.6,
			DirectionStiffness = 6, -- 1/s, how quickly the camera swings behind the car
			FovDeg = 70,
		},
		Cockpit = {
			OffsetM = Vector3.new(0, 0.58, -0.40), -- relative to the CoM, -Z is forward
			FovDeg = 80,
		},
	},

	Network = {
		ResetCooldownS = 2,
		FallResetHeightStuds = -60, -- server resets cars that fall below this height
	},
}

return VehicleConfig
