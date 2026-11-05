--!strict
--[[
	AeroModel  (Shared, pure maths)

	  q          = 0.5 * rho * v^2
	  drag       = -0.5 * rho * CdA * |v_air| * v_air      (opposes air-relative velocity)
	  downforce  = q_forward * ClA_front / ClA_rear        (front / rear axle)

	v_air is the car's velocity relative to the air (no wind yet, so v_air = v_car).
	Downforce uses only the forward airflow component (a car sliding sideways or reversing
	makes little downforce). Downforce is applied at the axles and added to the tyre normal
	loads, so it directly raises available grip.
	Initial coefficients are plausible estimates for calibration, not measured data.
]]

export type Params = {
	AirDensityKgM3: number,
	DragAreaCdA: number,
	DownforceAreaFront: number,
	DownforceAreaRear: number,
}

export type Result = {
	dragN: Vector3,
	downforceFrontN: number,
	downforceRearN: number,
}

local AeroModel = {}

function AeroModel.compute(p: Params, airVelocityMs: Vector3, forward: Vector3): Result
	local speed = airVelocityMs.Magnitude
	if speed < 1e-4 then
		return { dragN = Vector3.zero, downforceFrontN = 0, downforceRearN = 0 }
	end
	local drag = -airVelocityMs * (0.5 * p.AirDensityKgM3 * p.DragAreaCdA * speed)
	local vx = math.max(airVelocityMs:Dot(forward), 0)
	local q = 0.5 * p.AirDensityKgM3 * vx * vx
	return {
		dragN = drag,
		downforceFrontN = q * p.DownforceAreaFront,
		downforceRearN = q * p.DownforceAreaRear,
	}
end

return AeroModel
