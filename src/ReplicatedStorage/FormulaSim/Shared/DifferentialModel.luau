--!strict
--[[
	DifferentialModel  (Shared, pure maths)

	Rear differential approximation. Input torque is split equally (open differential), then
	a limited-slip term moves torque from the faster wheel to the slower one:

	  transfer = clamp(Viscous * (omegaL - omegaR), +-(Preload + LockRatio * |T_in|))
	  T_left  = T_in/2 - transfer/2
	  T_right = T_in/2 + transfer/2

	Effect: an unloaded inside wheel cannot simply spin away (better traction), while the
	locking torque still gives some realistic power-on yaw.
]]

export type Params = {
	ViscousNmPerRadS: number,
	PreloadNm: number,
	LockRatio: number,
}

local DifferentialModel = {}

function DifferentialModel.split(p: Params, inputTorqueNm: number, omegaLeft: number, omegaRight: number): (number, number)
	local half = inputTorqueNm * 0.5
	local cap = p.PreloadNm + p.LockRatio * math.abs(inputTorqueNm)
	local transfer = math.clamp(p.ViscousNmPerRadS * (omegaLeft - omegaRight), -cap, cap)
	return half - transfer * 0.5, half + transfer * 0.5
end

return DifferentialModel
