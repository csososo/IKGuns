--[[
	Aim -- turns the chest and head toward wherever the camera is pointing.

	The torso is done by offsetting spine Motor6D C0s rather than their
	Transforms. C0 is the bind pose, so the animation's Transform composes on
	top of it instead of being overwritten, and the change lands before the
	engine's animation and IK step in the same frame rather than a frame late.

	The rotation is split across several spine joints by weight, so the turn
	reads as the whole torso rather than one joint shearing. The head is an
	IKControl of type LookAt, so the neck solves itself.
]]

local Config = require(script.Parent.Config)
local Util = require(script.Parent.Util)

local Aim = {}
Aim.__index = Aim

function Aim.new(rig)
	local self = setmetatable({}, Aim)
	self.rig = rig
	self.yaw = 0
	self.pitch = 0
	self.weight = 0   -- fades the whole upper-body aim in and out
	self.aiming = false
	return self
end

function Aim:SetAiming(aiming: boolean)
	self.aiming = aiming
end

-- 0 relaxes the chest back to the animation, 1 is full aim.
function Aim:SetWeight(weight: number)
	self.targetWeight = math.clamp(weight, 0, 1)
end

function Aim:_turnBodyToCamera(camLook: Vector3, dt: number)
	local humanoid, root = self.rig.humanoid, self.rig.parts.Root
	if not (humanoid and root) then
		return
	end

	if not (self.aiming and Config.Aim.TurnWithCameraWhenAiming) then
		if self.tookAutoRotate then
			humanoid.AutoRotate = true
			self.tookAutoRotate = false
		end
		return
	end

	humanoid.AutoRotate = false
	self.tookAutoRotate = true

	local flat = Vector3.new(camLook.X, 0, camLook.Z)
	if flat.Magnitude < 1e-4 then
		return
	end

	local wanted = CFrame.lookAt(root.Position, root.Position + flat.Unit)
	root.CFrame = root.CFrame:Lerp(wanted, math.clamp(dt / 0.05, 0, 1))
end

function Aim:Update(dt: number)
	local rig = self.rig
	if not rig.features.aim then
		return
	end

	local cfg = Config.Aim
	local camera = workspace.CurrentCamera
	local root = rig.parts.Root
	if not (camera and root) then
		return
	end

	local camCF = camera.CFrame
	self:_turnBodyToCamera(camCF.LookVector, dt)

	-- Express the aim direction in the root's own axes: forward is -Z, up is
	-- +Y, right is +X.
	local rel = root.CFrame:VectorToObjectSpace(camCF.LookVector)

	--[[
		atan2 wraps at +/-pi. When the aim direction is roughly BEHIND the
		character, the raw yaw sits right on that seam, so a sub-degree camera
		wobble flips it between +pi and -pi. Clamping then turns that flip into
		a full-width snap between +MaxYaw and -MaxYaw, every frame, and the
		torso whips back and forth fast enough to blur.

		Past a quarter turn there is no meaningful "which way" answer anyway,
		so hold whichever side we are already twisted toward.
	]]
	local rawYaw = math.atan2(-rel.X, -rel.Z)
	local wantedYaw
	if math.abs(rawYaw) > math.pi * 0.5 then
		wantedYaw = (self.yaw >= 0) and cfg.MaxYaw or -cfg.MaxYaw
	else
		wantedYaw = math.clamp(rawYaw, -cfg.MaxYaw, cfg.MaxYaw)
	end

	local wantedPitch = math.clamp(math.asin(math.clamp(rel.Y, -1, 1)), -cfg.MaxPitch, cfg.MaxPitch)

	self.yaw = Util.damp(self.yaw, wantedYaw, cfg.Responsiveness, dt)
	self.pitch = Util.damp(self.pitch, wantedPitch, cfg.Responsiveness, dt)
	self.weight = Util.damp(self.weight, self.targetWeight or 1, cfg.Responsiveness, dt)

	local pitch = self.pitch * self.weight
	local yaw = self.yaw * self.weight
	for _, joint in rig.spine do
		joint.motor.C0 = Util.rotateAboutPivot(joint.baseC0,
			CFrame.Angles(pitch * joint.weight, yaw * joint.weight, 0))
	end

	local lookTarget = rig.attachments.Look
	local lookControl = rig.controls.HeadLookIK
	if lookTarget and lookControl then
		lookTarget.WorldPosition = camCF.Position + camCF.LookVector * cfg.AimDistance
		lookControl.Weight = cfg.HeadWeight * self.weight
	end

	if Config.Debug then
		local character = rig.character
		character:SetAttribute("IK_AimYaw", math.deg(self.yaw))
		character:SetAttribute("IK_AimPitch", math.deg(self.pitch))
		character:SetAttribute("IK_AimRawYaw", math.deg(rawYaw))
	end
end

function Aim:Reset()
	local rig = self.rig
	for _, joint in rig.spine do
		if joint.motor.Parent then
			joint.motor.C0 = joint.baseC0
		end
	end
	if self.tookAutoRotate and rig.humanoid then
		rig.humanoid.AutoRotate = true
		self.tookAutoRotate = false
	end
end

return Aim
