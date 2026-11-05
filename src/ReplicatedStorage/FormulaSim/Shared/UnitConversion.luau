--!strict
--[[
	UnitConversion  (Shared: required by server and client)

	All simulation math runs in SI units (m, kg, s, N, N*m).
	Roblox engine units are used ONLY at the physics boundary
	(reading part velocities / positions, writing VectorForce values).

	Chosen length scale: 1 stud = 0.28 m (Roblox's avatar-scale convention).
	Workspace.Gravity is set to 9.81 m/s^2 expressed in studs: 35.036 stud/s^2.

	Derived engine units:
	  Length   1 stud                    = 0.28 m
	  Time     1 s                       = 1 s (no time scaling)
	  Mass     1 RMU (Roblox mass unit)  = mass of a Density-1 part of 1 stud^3.
	           Density 1 is water (1000 kg/m^3), so 1 RMU = 1000 * 0.28^3 = 21.952 kg
	  Velocity 1 stud/s                  = 0.28 m/s
	  Accel    1 stud/s^2                = 0.28 m/s^2
	  Force    1 RMU*stud/s^2            = 21.952 * 0.28   = 6.14656 N
	  Torque   1 RMU*stud^2/s^2          = 21.952 * 0.28^2 = 1.7210368 N*m

	Note: dynamics depend only on F/m ratios, so the kg-per-RMU value is a
	convention. What matters is that mass (read from the engine) and force
	(written to the engine) use the SAME convention, which this module guarantees.
]]

local METERS_PER_STUD = 0.28
local STUDS_PER_METER = 1 / METERS_PER_STUD
local KG_PER_RMU = 1000 * METERS_PER_STUD ^ 3
local NEWTONS_PER_FORCE_UNIT = KG_PER_RMU * METERS_PER_STUD
local NM_PER_TORQUE_UNIT = KG_PER_RMU * METERS_PER_STUD ^ 2
local GRAVITY_MS2 = 9.81

local UnitConversion = {
	METERS_PER_STUD = METERS_PER_STUD,
	STUDS_PER_METER = STUDS_PER_METER,
	KG_PER_RMU = KG_PER_RMU,
	NEWTONS_PER_FORCE_UNIT = NEWTONS_PER_FORCE_UNIT,
	NM_PER_TORQUE_UNIT = NM_PER_TORQUE_UNIT,
	GRAVITY_MS2 = GRAVITY_MS2,
	GRAVITY_STUDS_S2 = GRAVITY_MS2 * STUDS_PER_METER,
}

-- Length
function UnitConversion.metersToStuds(m: number): number
	return m * STUDS_PER_METER
end

function UnitConversion.studsToMeters(s: number): number
	return s * METERS_PER_STUD
end

function UnitConversion.vectorToStuds(v: Vector3): Vector3
	return v * STUDS_PER_METER
end

function UnitConversion.vectorToMeters(v: Vector3): Vector3
	return v * METERS_PER_STUD
end

-- Velocity (time is unscaled, so velocity scales like length)
function UnitConversion.velocityToMs(v: Vector3): Vector3
	return v * METERS_PER_STUD
end

function UnitConversion.velocityToStuds(v: Vector3): Vector3
	return v * STUDS_PER_METER
end

-- Mass
function UnitConversion.kgToRmu(kg: number): number
	return kg / KG_PER_RMU
end

function UnitConversion.rmuToKg(rmu: number): number
	return rmu * KG_PER_RMU
end

-- Force
function UnitConversion.forceToRoblox(newtons: Vector3): Vector3
	return newtons / NEWTONS_PER_FORCE_UNIT
end

function UnitConversion.forceToNewtons(force: Vector3): Vector3
	return force * NEWTONS_PER_FORCE_UNIT
end

-- Torque
function UnitConversion.torqueToRoblox(newtonMeters: Vector3): Vector3
	return newtonMeters / NM_PER_TORQUE_UNIT
end

function UnitConversion.torqueToNm(torque: Vector3): Vector3
	return torque * NM_PER_TORQUE_UNIT
end

-- Display
function UnitConversion.msToKmh(ms: number): number
	return ms * 3.6
end

--[[
	selfCheck: verifies the conversions are dimensionally consistent.
	Weight computed in SI and converted must equal weight computed natively in engine units.
	Returns (ok, message).
]]
function UnitConversion.selfCheck(): (boolean, string)
	-- Scalars (float64) are used here; Vector3 is float32 and would add ~1e-7 noise.
	local massKg = 798
	local weightEngineFromSI = (massKg * GRAVITY_MS2) / NEWTONS_PER_FORCE_UNIT
	local weightEngineNative = UnitConversion.kgToRmu(massKg) * UnitConversion.GRAVITY_STUDS_S2
	local err = math.abs(weightEngineFromSI - weightEngineNative) / weightEngineNative
	local ok = err < 1e-9
	return ok, string.format("weight SI->engine %.6f vs native %.6f (rel err %.2e)", weightEngineFromSI, weightEngineNative, err)
end

return UnitConversion
