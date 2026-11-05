--!strict
--[[
	TireModel  (Shared, pure maths - no Instances)

	Combined-slip tyre model, simplified "magic formula" style. Not fitted to any real tyre.

	Inputs per wheel: normal load Fz, contact-patch velocity (vLong along the wheel heading,
	vLat along its right axis) and wheel surface speed (omega * radius).

	  reference speed   Vref  = max(|vLong|, LowSpeedMs)
	  slip ratio        kappa = (omega*r - vLong) / Vref        (+ = wheelspin, -1 = locked)
	  slip angle        alpha = atan2(vLat, Vref)               (+ = patch sliding to the right)

	  normalised slips  sx = kappa / PeakSlipRatio,  sy = tan(alpha) / tan(PeakSlipAngle)
	  combined slip     s  = sqrt(sx^2 + sy^2)                  (s = 1 is the grip peak)
	  grip              mu = Mu * (1 - LoadSensitivity * (Fz/NominalLoad - 1))
	  force magnitude   F  = mu * Fz * sin(C * atan(B * s)),  B = tan(pi / (2C))
	  components        Fx = F * sx / s,  Fy = -F * sy / s

	Properties:
	  * Grip rises with slip, peaks at s = 1, then falls progressively to sin(C*pi/2) of peak
	    (85% with C = 1.35). Loss of grip is gradual, not a switch.
	  * Combined slip: force points along the slip vector, so a spinning or locked wheel loses
	    cornering force smoothly in proportion to how much it is sliding longitudinally.
	  * |F| <= mu * Fz always (friction ellipse).
	  * Lateral force opposes sideways sliding; longitudinal force opposes wheel/ground slip,
	    so braking (wheel slower than ground) always opposes motion.

	Numerical safeguards:
	  * Vref floor keeps kappa and alpha finite at standstill.
	  * Below LowSpeedMs lateral force blends into a velocity-damping hold.
	  * Forces are capped so one chassis step cannot more than cancel the slip velocity
	    (OvershootSafety); this prevents explicit-integration oscillation at low speed.
]]

export type AxleParams = {
	Mu: number,
	PeakSlipRatio: number,
	PeakSlipAngleDeg: number,
	RollingResistance: number,
	WheelInertiaKgM2: number,
}

export type SharedParams = {
	ShapeC: number,
	LoadSensitivity: number,
	NominalLoadN: number,
	LowSpeedMs: number,
	LowSpeedRelaxationS: number,
	OvershootSafety: number,
	WheelSubsteps: number,
}

export type Result = {
	fxN: number,
	fyN: number,
	slipRatio: number,
	slipAngleRad: number,
	combinedSlip: number, -- s; > 1 means past the grip peak
	utilization: number, -- |F| / (mu * Fz)
}

local TireModel = {}

function TireModel.evaluate(
	axle: AxleParams,
	shared: SharedParams,
	fz: number,
	vLong: number,
	vLat: number,
	wheelSurfaceMs: number,
	massShareKg: number,
	dt: number
): Result
	local vRef = math.max(math.abs(vLong), shared.LowSpeedMs)
	local slipVelX = wheelSurfaceMs - vLong
	local kappa = slipVelX / vRef
	local alpha = math.atan2(vLat, vRef)

	if fz <= 0 or dt <= 0 then
		return { fxN = 0, fyN = 0, slipRatio = kappa, slipAngleRad = alpha, combinedSlip = 0, utilization = 0 }
	end

	local sx = kappa / axle.PeakSlipRatio
	local sy = math.tan(alpha) / math.tan(math.rad(axle.PeakSlipAngleDeg))
	local s = math.sqrt(sx * sx + sy * sy)

	local loadFactor = math.clamp(1 - shared.LoadSensitivity * (fz / shared.NominalLoadN - 1), 0.6, 1.2)
	local fMax = axle.Mu * loadFactor * fz

	local fx, fy = 0, 0
	if s > 1e-9 then
		local c = shared.ShapeC
		local b = math.tan(math.pi / (2 * c))
		local f = fMax * math.sin(c * math.atan(b * s))
		fx = f * sx / s
		fy = -f * sy / s
	end

	-- Near standstill, blend lateral force into a damping hold so the car cannot creep sideways.
	local speed = math.sqrt(vLong * vLong + vLat * vLat)
	local blend = math.clamp(speed / shared.LowSpeedMs, 0, 1)
	local fyHold = -massShareKg * vLat / shared.LowSpeedRelaxationS
	fy = fyHold + (fy - fyHold) * blend

	-- No-overshoot caps (numerical safety, only active at small slip velocities / low speed).
	local capPerVelocity = shared.OvershootSafety * massShareKg / dt
	local capX = capPerVelocity * math.abs(slipVelX)
	local capY = capPerVelocity * math.abs(vLat)
	fx = math.clamp(fx, -capX, capX)
	fy = math.clamp(fy, -capY, capY)

	-- Friction ellipse (the hold blend can otherwise exceed it).
	local magnitude = math.sqrt(fx * fx + fy * fy)
	if magnitude > fMax then
		local k = fMax / magnitude
		fx *= k
		fy *= k
		magnitude = fMax
	end

	return {
		fxN = fx,
		fyN = fy,
		slipRatio = kappa,
		slipAngleRad = alpha,
		combinedSlip = s,
		utilization = magnitude / fMax,
	}
end

return TireModel
