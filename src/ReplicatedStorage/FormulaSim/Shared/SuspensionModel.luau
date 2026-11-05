--!strict
--[[
	SuspensionModel  (Shared, pure maths)

	Per-corner spring/damper, measured relative to static ride height:
	  x      compression beyond static ride height (m, + = compressed)
	  xdot   compression velocity (m/s, + = compressing)

	  spring   = StaticLoad + k * x          (preloaded so the car rests at design ride height)
	  damper   = c_bump * xdot  (xdot > 0)  or  c_rebound * xdot  (xdot < 0)
	             digressive above DamperKneeMs (real dampers blow off on sharp bumps)
	  anti-roll bar (per axle)  F_left += k_arb * (x_left - x_right), F_right -= same
	  normal   = clamp(spring + damper + arb, 0, MaxForceFactor * StaticLoad)

	The normal force is never negative (the tyre cannot pull the car down), and a wheel past
	full droop has no contact at all.

	Stability: forces are updated once per physics step and held for Roblox's internal
	substeps, so damping is scaled by min(1, DesignFrameRate * dt)^-1 at low frame rates
	(keeps c * dt bounded) - the car stays stable at 30 fps with slightly less damping.
]]

export type AxleParams = {
	SpringNPerM: number,
	BumpNsPerM: number,
	ReboundNsPerM: number,
	AntiRollNPerM: number,
}

export type SharedParams = {
	MaxCompressionM: number,
	MaxDroopM: number,
	ProbeStartAboveM: number,
	DamperKneeMs: number,
	DamperHighSpeedFactor: number,
	MaxForceFactor: number,
	DesignFrameRate: number,
}

local SuspensionModel = {}

function SuspensionModel.damperForceN(axle: AxleParams, shared: SharedParams, xdot: number, dt: number): number
	local c = if xdot >= 0 then axle.BumpNsPerM else axle.ReboundNsPerM
	local speed = math.abs(xdot)
	local knee = shared.DamperKneeMs
	local force
	if speed <= knee then
		force = c * speed
	else
		force = c * knee + c * shared.DamperHighSpeedFactor * (speed - knee)
	end
	-- keep c*dt bounded when the frame rate drops below the design rate
	local frameScale = math.min(1, 1 / (shared.DesignFrameRate * math.max(dt, 1e-4)))
	return math.sign(xdot) * force * frameScale
end

-- Spring + damper force (before anti-roll bar and clamping).
function SuspensionModel.cornerForceN(axle: AxleParams, shared: SharedParams, staticLoadN: number, x: number, xdot: number, dt: number): (number, number)
	local spring = staticLoadN + axle.SpringNPerM * x
	local damper = SuspensionModel.damperForceN(axle, shared, xdot, dt)
	return spring, damper
end

function SuspensionModel.antiRollN(axle: AxleParams, xLeft: number, xRight: number): number
	return axle.AntiRollNPerM * (xLeft - xRight)
end

function SuspensionModel.clampNormal(shared: SharedParams, staticLoadN: number, forceN: number): number
	return math.clamp(forceN, 0, shared.MaxForceFactor * staticLoadN)
end

return SuspensionModel
