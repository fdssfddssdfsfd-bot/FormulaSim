--!strict
--[[
	BrakeModel  (Shared, pure maths)

	Pedal (0..1) -> brake torque at each wheel. Torque acts on wheel rotation (it never pushes
	the car directly); the tyre then decides how much of it becomes deceleration. Too much
	torque for the available grip locks the wheel, exactly like a real car without ABS.

	FrontBias is the share of total torque at the front axle (equal tyre radii, so this is
	also the force bias).

	Optional ABS: per-wheel factor that releases pressure when the wheel's slip ratio goes
	beyond -AbsSlipTarget and re-applies it afterwards.
]]

export type Params = {
	MaxTotalTorqueNm: number,
	FrontBias: number,
}

local BrakeModel = {}

-- Returns (torque per front wheel, torque per rear wheel), N*m, before ABS modulation.
function BrakeModel.wheelTorquesNm(p: Params, pedal: number): (number, number)
	local total = math.clamp(pedal, 0, 1) * p.MaxTotalTorqueNm
	return total * p.FrontBias * 0.5, total * (1 - p.FrontBias) * 0.5
end

-- Advances one wheel's ABS pressure factor (0..1).
function BrakeModel.updateAbsFactor(assists: any, factor: number, slipRatio: number, braking: boolean, dt: number): number
	if braking and slipRatio < -assists.AbsSlipTarget then
		return math.max(0, factor - assists.AbsReleaseRate * dt)
	end
	return math.min(1, factor + assists.AbsApplyRate * dt)
end

return BrakeModel
