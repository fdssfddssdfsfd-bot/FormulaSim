--!strict
--[[
	EngineModel  (Shared, pure maths)

	Combined power-unit model (combustion engine + electric boost treated as one torque curve).
	  full-load torque  T_max(rpm): piecewise-linear TorqueCurve
	  engine braking    T_brake(rpm) = EngineBrakeNm * rpm / LimiterRpm
	  output torque     T = PedalMap(throttle) * T_max(rpm) - (1 - PedalMap(throttle)) * T_brake(rpm)
	  rev limiter       at or above LimiterRpm fuel is cut: T = -T_brake(rpm)

	PedalMap(x) = x ^ PedalMapExponent (progressive drive-by-wire map, like a real torque map).
	The curve is a plausible high-revving racing engine, not data from any real engine.
]]

export type Params = {
	IdleRpm: number,
	LimiterRpm: number,
	LaunchRpm: number,
	TorqueCurve: { { number } }, -- { {rpm, Nm}, ... } ascending rpm
	EngineBrakeNm: number,
	InertiaKgM2: number,
	PedalMapExponent: number,
}

local EngineModel = {}

function EngineModel.maxTorqueNm(p: Params, rpm: number): number
	local curve = p.TorqueCurve
	if rpm <= curve[1][1] then
		return curve[1][2]
	end
	for i = 2, #curve do
		local r1, t1 = curve[i][1], curve[i][2]
		if rpm <= r1 then
			local r0, t0 = curve[i - 1][1], curve[i - 1][2]
			return t0 + (t1 - t0) * (rpm - r0) / (r1 - r0)
		end
	end
	return curve[#curve][2]
end

function EngineModel.brakingTorqueNm(p: Params, rpm: number): number
	return p.EngineBrakeNm * math.clamp(rpm / p.LimiterRpm, 0, 1.2)
end

function EngineModel.torqueNm(p: Params, rpm: number, throttle: number): number
	local braking = EngineModel.brakingTorqueNm(p, rpm)
	if rpm >= p.LimiterRpm then
		return -braking -- fuel cut
	end
	local demand = math.clamp(throttle, 0, 1) ^ p.PedalMapExponent
	return demand * EngineModel.maxTorqueNm(p, rpm) - (1 - demand) * braking
end

function EngineModel.powerKw(p: Params, rpm: number): number
	return EngineModel.maxTorqueNm(p, rpm) * rpm * 2 * math.pi / 60 / 1000
end

return EngineModel
