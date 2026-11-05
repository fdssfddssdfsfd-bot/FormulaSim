--!strict
--[[
	TelemetryController  (Client, UI only - reads the telemetry table, never writes physics)

	Milestone A: minimal HUD - speed (km/h), gear, throttle / brake bars, steering input,
	plus a physics debug panel (toggle T): speed, steering, pedals, torques, yaw rate,
	sideslip and per-wheel load / slip ratio / slip angle / grip use / wheel speed.
]]

local Players = game:GetService("Players")

local TelemetryController = {}
TelemetryController.__index = TelemetryController

local PANEL_BG = Color3.fromRGB(14, 16, 20)
local TEXT = Color3.fromRGB(240, 240, 240)
local DIM = Color3.fromRGB(150, 155, 165)

local function create(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for k, v in props do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(parent: Instance, px: number)
	create("UICorner", { CornerRadius = UDim.new(0, px) }, parent)
end

local function verticalBar(parent: Instance, x: number, color: Color3, label: string): Frame
	local track = create("Frame", {
		Position = UDim2.fromOffset(x, 14),
		Size = UDim2.fromOffset(14, 92),
		BackgroundColor3 = Color3.fromRGB(40, 44, 52),
		BorderSizePixel = 0,
	}, parent)
	corner(track, 4)
	local fill = create("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	}, track)
	corner(fill, 4)
	create("TextLabel", {
		Position = UDim2.fromOffset(x - 4, 108),
		Size = UDim2.fromOffset(22, 14),
		BackgroundTransparency = 1,
		Text = label,
		TextColor3 = DIM,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
	}, parent)
	return fill
end

function TelemetryController.new()
	local self = setmetatable({}, TelemetryController)
	local player = Players.LocalPlayer
	local gui = create("ScreenGui", {
		Name = "FormulaSimHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})

	local panel = create("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -20),
		Size = UDim2.fromOffset(340, 132),
		BackgroundColor3 = PANEL_BG,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
	}, gui)
	corner(panel, 10)

	self.throttleFill = verticalBar(panel, 14, Color3.fromRGB(60, 200, 90), "THR")
	self.brakeFill = verticalBar(panel, 38, Color3.fromRGB(230, 60, 60), "BRK")

	self.speedLabel = create("TextLabel", {
		Position = UDim2.fromOffset(64, 4),
		Size = UDim2.fromOffset(170, 70),
		BackgroundTransparency = 1,
		Text = "0",
		TextColor3 = TEXT,
		Font = Enum.Font.GothamBold,
		TextSize = 60,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, panel)
	create("TextLabel", {
		Position = UDim2.fromOffset(64, 70),
		Size = UDim2.fromOffset(170, 16),
		BackgroundTransparency = 1,
		Text = "km/h",
		TextColor3 = DIM,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, panel)

	self.gearLabel = create("TextLabel", {
		Position = UDim2.fromOffset(250, 4),
		Size = UDim2.fromOffset(76, 82),
		BackgroundTransparency = 1,
		Text = "N",
		TextColor3 = Color3.fromRGB(255, 170, 40),
		Font = Enum.Font.GothamBlack,
		TextSize = 72,
	}, panel)

	local rpmTrack = create("Frame", {
		Position = UDim2.fromOffset(64, 88),
		Size = UDim2.fromOffset(170, 6),
		BackgroundColor3 = Color3.fromRGB(40, 44, 52),
		BorderSizePixel = 0,
	}, panel)
	self.rpmFill = create("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Color3.fromRGB(80, 170, 255),
		BorderSizePixel = 0,
	}, rpmTrack)
	self.rpmLabel = create("TextLabel", {
		Position = UDim2.fromOffset(250, 84),
		Size = UDim2.fromOffset(76, 14),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = DIM,
		Font = Enum.Font.GothamMedium,
		TextSize = 11,
	}, panel)

	local steerTrack = create("Frame", {
		Position = UDim2.fromOffset(70, 100),
		Size = UDim2.fromOffset(250, 8),
		BackgroundColor3 = Color3.fromRGB(40, 44, 52),
		BorderSizePixel = 0,
	}, panel)
	corner(steerTrack, 4)
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 2, 1, 6),
		BackgroundColor3 = DIM,
		BorderSizePixel = 0,
	}, steerTrack)
	self.steerMarker = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(10, 16),
		BackgroundColor3 = Color3.fromRGB(80, 170, 255),
		BorderSizePixel = 0,
	}, steerTrack)
	corner(self.steerMarker, 3)
	self.steerText = create("TextLabel", {
		Position = UDim2.fromOffset(70, 112),
		Size = UDim2.fromOffset(250, 14),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = DIM,
		Font = Enum.Font.GothamMedium,
		TextSize = 11,
	}, panel)

	-- Debug physics panel (toggle with ToggleDebug, default T). RichText, monospace.
	self.debugLabel = create("TextLabel", {
		Name = "PhysicsDebug",
		Position = UDim2.fromOffset(12, 64), -- below Roblox's top-left menu buttons
		Size = UDim2.fromOffset(660, 248),
		BackgroundColor3 = PANEL_BG,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Text = "",
		RichText = true,
		TextColor3 = TEXT,
		Font = Enum.Font.Code,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, gui)
	corner(self.debugLabel, 6)
	create("UIPadding", {
		PaddingLeft = UDim.new(0, 8),
		PaddingTop = UDim.new(0, 6),
	}, self.debugLabel)

	self.fps = 60
	gui.Parent = player:WaitForChild("PlayerGui")
	self.gui = gui
	return self
end

function TelemetryController:update(t: any, dt: number)
	if dt > 0 then
		self.fps += (1 / dt - self.fps) * math.min(1, dt * 4)
	end
	self.speedLabel.Text = string.format("%d", math.floor(t.speedKmh + 0.5))
	self.gearLabel.Text = t.gearLabel
	self.rpmLabel.Text = string.format("%5d rpm", math.floor(t.rpm + 0.5))
	self.rpmFill.Size = UDim2.fromScale(math.clamp((t.rpm - 4000) / 9000, 0, 1), 1)
	self.rpmFill.BackgroundColor3 = if t.rpm > 12300 then Color3.fromRGB(240, 60, 60) else Color3.fromRGB(80, 170, 255)
	self.throttleFill.Size = UDim2.fromScale(1, t.throttle)
	self.brakeFill.Size = UDim2.fromScale(1, t.brake)
	self.steerMarker.Position = UDim2.fromScale(0.5 + 0.5 * t.steer, 0.5)
	self.steerText.Text = string.format("steer %+.2f   road wheel %+.1f deg", t.steer, t.steerAngleDeg)
	if self.debugLabel.Visible then
		self.debugLabel.Text = self:_debugText(t)
	end
end

local function colorIf(text: string, warn: boolean, bad: boolean): string
	if bad then
		return '<font color="#ff5a5a">' .. text .. "</font>"
	elseif warn then
		return '<font color="#ffb43c">' .. text .. "</font>"
	end
	return text
end

function TelemetryController:toggleDebug()
	self.debugLabel.Visible = not self.debugLabel.Visible
end

function TelemetryController:_debugText(t: any): string
	local lines = {}
	table.insert(lines, string.format(
		"<b>SPEED</b> %6.1f km/h  <b>YAW</b> %+6.1f deg/s  <b>SIDESLIP</b> %+5.1f deg  <b>FPS</b> %d",
		t.speedKmh, t.yawRateDegS, t.sideslipDeg, math.floor(self.fps + 0.5)))
	table.insert(lines, string.format(
		"<b>STEER</b> in %+.2f -> road wheel %+5.2f deg   <b>THR</b> %.2f  <b>BRK</b> %.2f   <b>GEAR</b> %s",
		t.steer, t.steerAngleDeg, t.throttle, t.brake, t.gearLabel))
	table.insert(lines, string.format(
		"<b>RPM</b> %5.0f  <b>SHIFT</b> %s   <b>AXLE TORQUE</b> %6.0f N*m%s",
		t.rpm,
		if t.autoShift then "AUTO (G)" else "MANUAL (E/Q)",
		t.axleTorqueNm, if t.tcEnabled and t.tcFactor < 0.999 then string.format("  (TC cut %.0f%%)", (1 - t.tcFactor) * 100) else ""))
	table.insert(lines, string.format(
		"<b>BRAKE TORQUE</b> front %5.0f  rear %5.0f N*m   <b>ABS</b> %s  <b>TC</b> %s",
		t.frontBrakeTorqueNm, t.rearBrakeTorqueNm, if t.absEnabled then "ON" else "off", if t.tcEnabled then "ON" else "off"))
	table.insert(lines, string.format(
		"<b>G</b> long %+.2f  lat %+.2f   <b>DOWNFORCE</b> %5.0f N  <b>DRAG</b> %5.0f N   <b>MASS</b> %.0f kg  <b>FAULTS</b> %d",
		t.longG, t.latG, t.downforceN, t.dragN, t.massKg, t.faultCount))
	table.insert(lines, "")
	table.insert(lines, "<b>WHEEL  load N  susp mm  slip ratio  slip ang  grip used  omega r/s  brake N*m  contact</b>")
	for _, w in t.wheels do
		local pastPeak = w.combinedSlip > 1
		local locked = w.grounded and w.omega == 0 and math.abs(w.vLong) > 1
		table.insert(lines, string.format(
			"%-5s  %6.0f  %s   %s   %s   %s   %8.1f   %8.0f   %s",
			w.name,
			w.fz,
			colorIf(string.format("%+6.0f", (w.compressionM or 0) * 1000), (w.compressionM or 0) > 0.05, (w.compressionM or 0) >= 0.069),
			colorIf(string.format("%+9.3f", w.slipRatio), math.abs(w.slipRatio) > 0.1, locked or w.slipRatio > 0.3),
			colorIf(string.format("%+6.1f", math.deg(w.slipAngleRad)), math.abs(math.deg(w.slipAngleRad)) > 6, math.abs(math.deg(w.slipAngleRad)) > 12),
			colorIf(string.format("%6.0f%%", w.utilization * 100), pastPeak, pastPeak and w.combinedSlip > 2),
			w.omega,
			w.brakeTorqueNm,
			if w.grounded then "yes" else colorIf("AIR", false, true)))
	end
	table.insert(lines, "<font color=\"#9aa0aa\">orange = past grip peak, red = locked / heavy spin.  T hides this panel.</font>")
	return table.concat(lines, "\n")
end

function TelemetryController:destroy()
	self.gui:Destroy()
end

return TelemetryController
