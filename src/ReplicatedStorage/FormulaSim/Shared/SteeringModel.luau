--!strict
--[[
	SteeringModel  (Shared, pure maths)

	Maps a smoothed steering input (-1 left .. +1 right) to a road-wheel angle.
	Sign convention: positive angle = wheel heading rotated toward the car's right.

	Full-input lock depends on speed and follows what the car can use:
	  lock(v) = WheelbaseM * ReferenceLatG * g / v^2  +  slipMargin(v)
	  slipMargin(v) = High + (Low - High) / (1 + v / MarginBlendSpeedMs)
	clamped to [MinRoadWheelAngleDeg, MaxRoadWheelAngleDeg].
	The first term is the kinematic angle of a ReferenceLatG corner; the margin lets the
	front tyres reach (but not far exceed) their peak slip angle. This limits only how far a
	keyboard can steer; tyre slip, understeer and oversteer are untouched.

	Parallel steer (both fronts at the same angle); Ackermann is not modelled yet.
]]

export type Params = {
	MaxRoadWheelAngleDeg: number,
	MinRoadWheelAngleDeg: number,
	WheelbaseM: number,
	ReferenceLatG: number,
	LowSpeedSlipMarginDeg: number,
	HighSpeedSlipMarginDeg: number,
	MarginBlendSpeedMs: number,
}

local G = 9.81

local SteeringModel = {}

function SteeringModel.maxRoadWheelAngleRad(p: Params, speedMs: number): number
	local v = math.max(math.abs(speedMs), 1)
	local kinematic = p.WheelbaseM * p.ReferenceLatG * G / (v * v)
	local marginDeg = p.HighSpeedSlipMarginDeg + (p.LowSpeedSlipMarginDeg - p.HighSpeedSlipMarginDeg) / (1 + v / p.MarginBlendSpeedMs)
	return math.clamp(kinematic + math.rad(marginDeg), math.rad(p.MinRoadWheelAngleDeg), math.rad(p.MaxRoadWheelAngleDeg))
end

function SteeringModel.roadWheelAngleRad(p: Params, steerInput: number, speedMs: number): number
	return math.clamp(steerInput, -1, 1) * SteeringModel.maxRoadWheelAngleRad(p, speedMs)
end

return SteeringModel
