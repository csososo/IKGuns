--[[
	FootIK -- corrects an animated leg so the foot meets the real ground.

	The animation owns the pose: the stride, the timing, the lift, the weight.
	This only moves a foot the last inch, and on flat ground it does nothing
	at all.

	Two things make this work that earlier attempts got wrong:

	1. It runs on Stepped, AFTER the animation has been applied. Motor6D
	   .Transform written from RenderStepped is overwritten by the Animator
	   before the frame is drawn -- the write happens and simply never
	   survives, which is indistinguishable from doing nothing.

	2. The correction is RELATIVE: how much higher or lower the real ground is
	   than the flat floor the animation assumes. On level ground that is
	   zero, so the animation plays untouched. Setting an ABSOLUTE foot height
	   instead pins the foot to the floor and cancels the animation's own
	   vertical motion, which straightens the legs out.

	It also reads the animated pose by forward kinematics from the joints'
	Transform values rather than from the live parts. The live parts still
	carry last frame's correction, so measuring from them means measuring this
	system's own output -- which compounds frame over frame until the leg is
	pinned straight.
]]

local Config = require(script.Parent.Config)
local TwoBone = require(script.Parent.TwoBone)
local Util = require(script.Parent.Util)

local FootIK = {}
FootIK.__index = FootIK

local SIDES = { "Left", "Right" }

function FootIK.new(rig)
	local self = setmetatable({}, FootIK)
	self.rig = rig
	self.legs = {}
	self.hipDrop = 0
	self:_measure()

	local ready = {}
	for _, side in SIDES do
		if self.legs[side] then
			table.insert(ready, side)
		end
	end
	print(("[FootIK] %d legs ready: %s"):format(#ready,
		#ready > 0 and table.concat(ready, ", ") or "NONE"))

	return self
end

function FootIK:_measure()
	local rig = self.rig
	local cfg = Config.FootIK
	local forward = -Vector3.zAxis

	for _, side in SIDES do
		local hip = rig:FindMotor(cfg.HipJoint:format(side))
		local knee = rig:FindMotor(cfg.KneeJoint:format(side))
		local ankle = rig:FindMotor(cfg.AnkleJoint:format(side))
		if not (hip and knee and ankle and hip.Part0 and hip.Part1 and knee.Part1) then
			warn(("[FootIK] %s leg joints missing; skipping."):format(side))
			continue
		end

		local bone = TwoBone.measure(rig, hip, knee, ankle, forward)
		local bindAnkle = rig:GetBindOffset(ankle.Part1)
		if not (bone and bindAnkle) then
			warn(("[FootIK] %s leg geometry unreadable; skipping."):format(side))
			continue
		end

		self.legs[side] = {
			hip = hip,
			knee = knee,
			ankle = ankle,
			bone = bone,
			bindAnkleRot = bindAnkle.Rotation,
			ankleInPart = ankle.C1.Position,
			-- Optional, for foot roll. Absent on a single-part foot.
			heel = rig:FindMotor(cfg.HeelJoint:format(side)),
			toe = rig:FindMotor(cfg.ToeJoint:format(side)),
			roll = 0,
			delta = 0,   -- smoothed ground correction, studs
			weight = 0,  -- smoothed 0..1 how much of it to apply
		}
	end
end

--[[
	Where the ANIMATION wants this ankle, by forward kinematics through the
	leg's own joints.

	Must be read before anything is written this frame. Motor6D solves
	part1 = part0 * C0 * Transform * C1:Inverse(), so chaining that from the
	hip outward reproduces the animated pose exactly, without the corrections
	this module applied last frame.
]]
function FootIK:_animatedAnkle(leg): CFrame
	local upper = leg.hip.Part0.CFrame * leg.hip.C0 * leg.hip.Transform * leg.hip.C1:Inverse()
	local lower = upper * leg.knee.C0 * leg.knee.Transform * leg.knee.C1:Inverse()
	return lower * leg.ankle.C0 * leg.ankle.Transform * leg.ankle.C1:Inverse()
end

--[[
	The flat floor the animation assumes, from the root alone.

	HipHeight is ground to the bottom of the root part, so running that
	backwards gives it. Deriving the correction against this, rather than
	against an absolute height, is what makes it zero on level ground.
]]
function FootIK:_groundPlaneY(): number?
	local root = self.rig.parts.Root
	if not root then
		return nil
	end
	local hipHeight = self.rig.humanoid and self.rig.humanoid.HipHeight or 0
	return root.Position.Y - root.Size.Y * 0.5 - hipHeight
end

function FootIK:Update(dt: number)
	local cfg = Config.FootIK
	if not cfg.Enabled then
		return
	end

	local rig = self.rig
	local frame = rig:GetYawFrame()
	local basePlaneY = self:_groundPlaneY()
	if not (frame and basePlaneY) then
		return
	end

	self.dt = dt
	self.rootOp = CFrame.identity
	local grounded = true
	local humanoid = rig.humanoid
	if humanoid then
		local state = humanoid:GetState()
		grounded = humanoid.FloorMaterial ~= Enum.Material.Air
			and state ~= Enum.HumanoidStateType.Freefall
			and state ~= Enum.HumanoidStateType.Jumping
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rig.character }
	params.IgnoreWater = true

	local lowest = 0
	for _, side in SIDES do
		local leg = self.legs[side]
		if leg then
			leg.wanted = nil
			if grounded then
				self:_prepare(leg, basePlaneY, params)
				--[[
					Weight the hip's vote by the same factor as the leg's own
					correction, so a foot inside the dead zone or up in the
					air contributes nothing. Using the raw delta instead means
					a HipHeight that is off by a hundredth sinks the hips
					permanently, because nothing filters it out.
				]]
				lowest = math.min(lowest, leg.delta * leg.weight)
			end
		end
	end

	--[[
		Split the two legs' needs into a common drop and a tilt.

		Dropping by the worst of the two is what drags a leg that needed
		nothing down with it. The average handles what both legs share, and
		rolling the pelvis covers the difference -- so one foot can reach
		lower while the other stays exactly where it was.
	]]
	local dL = (self.legs.Left and self.legs.Left.delta * self.legs.Left.weight) or 0
	local dR = (self.legs.Right and self.legs.Right.delta * self.legs.Right.weight) or 0
	local wantDrop = math.min(0, (dL + dR) * 0.5) * cfg.HipInfluence
	self.hipDrop = Util.damp(self.hipDrop, grounded and wantDrop or 0, cfg.SmoothTime, dt)

	local wantRoll = 0
	if cfg.HipRoll and grounded then
		-- Height difference across the hips becomes a tilt angle.
		wantRoll = math.clamp(math.atan2(dL - dR, math.max(cfg.HipWidth, 0.1)),
			-cfg.MaxHipRoll, cfg.MaxHipRoll)
	end
	self.hipRoll = Util.damp(self.hipRoll or 0, wantRoll, cfg.SmoothTime, dt)

	--[[
		Move the hips for REAL, by translating the root joint.

		Offsetting only the solve's origin -- pretending the hip had moved
		while leaving the joint alone -- puts the top of each thigh somewhere
		the pelvis is not, and the legs visibly detach from the hips.
	]]
	local rootMotor = rig.motors.Root
	if rootMotor and rootMotor.Part0 then
		local pivot = (rootMotor.Part0.CFrame * rootMotor.C0).Position
		local op = CFrame.new(0, self.hipDrop, 0)
		if math.abs(self.hipRoll) > 1e-4 then
			-- Roll about the character's forward axis, pivoting on the hips.
			op *= Util.rotateAboutWorld(pivot, frame.LookVector, self.hipRoll)
		end
		if math.abs(self.hipDrop) > 1e-4 or math.abs(self.hipRoll) > 1e-4 then
			rootMotor.Transform = Util.applyWorldToJoint(rootMotor, op)
		end
		-- Remember it: the legs have to solve against where the hips ARE now,
		-- not where they were before this write.
		self.rootOp = op
	end

	--[[
		Let the spine absorb most of the pelvis roll.

		Everything above the hips is rigidly attached to them, so tilting the
		pelvis tips the chest, arms and head with it. Distributing an opposite
		rotation down the spine keeps the upper body near level while the hips
		do the work -- which is what a real back does.
	]]
	if cfg.CounterRotate and math.abs(self.hipRoll) > 1e-4 and rig.spine then
		for _, joint in rig.spine do
			local motor = joint.motor
			if motor.Part0 then
				local pivot = (motor.Part0.CFrame * motor.C0).Position
				local share = -self.hipRoll * cfg.CounterFraction * (joint.weight or 0)
				motor.Transform = Util.applyWorldToJoint(motor,
					Util.rotateAboutWorld(pivot, frame.LookVector, share))
			end
		end
	end

	for _, side in SIDES do
		self:_apply(self.legs[side], frame)
	end
end

-- Work out this leg's correction, without writing anything yet.
function FootIK:_prepare(leg, basePlaneY: number, params: RaycastParams)
	local cfg = Config.FootIK
	local animCF = self:_animatedAnkle(leg)

	local hit = workspace:Raycast(animCF.Position + Vector3.yAxis * cfg.RayUp,
		Vector3.yAxis * -(cfg.RayUp + cfg.RayDown), params)
	if not hit then
		leg.delta = 0
		return
	end

	--[[
		How far this foot's ground differs from the assumed floor. Zero on
		level ground, positive on a step up, negative over a drop. Note what
		it does not depend on: where the foot currently is.
	]]
	local raw = math.clamp(hit.Position.Y - basePlaneY, -cfg.MaxStepDown, cfg.MaxStepUp)

	--[[
		Smooth both the correction and its weight. Stepping onto or off a
		ledge changes the raycast result discontinuously, and applying that
		jump straight to the joints is what makes a leg snap for a frame.
	]]
	leg.delta = Util.damp(leg.delta, raw, cfg.SmoothTime, self.dt)

	--[[
		Is this foot planted, or has the animation lifted it?

		Clearance above the surface tells us: at rest it equals AnkleHeight,
		and mid-swing it is higher. A lifted foot is meant to be in the air,
		so correcting it fights the animation -- and letting it vote on hip
		height sinks the body under a leg that is not even carrying weight.
	]]
	local clearance = animCF.Position.Y - hit.Position.Y
	local lift = math.max(0, clearance - cfg.AnkleHeight)
	local plant = 1 - math.clamp(lift / math.max(cfg.LiftThreshold, 1e-4), 0, 1)

	local zone = math.max(cfg.DeadZone, 1e-4)
	local wantWeight = math.clamp((math.abs(leg.delta) - zone) / zone, 0, 1) * plant
	leg.weight = Util.damp(leg.weight, wantWeight, cfg.BlendTime, self.dt)

	leg.normal = hit.Normal
	leg.animCF = animCF
	leg.wanted = true
end

function FootIK:_apply(leg, frame: CFrame)
	if not (leg and leg.animCF) then
		return
	end

	local cfg = Config.FootIK
	local w = leg.weight
	if w <= 1e-3 then
		return -- nothing to correct; leave the animation completely alone
	end

	local hipBase = leg.hip.Part0.CFrame * leg.hip.C0
	local hipPos = hipBase.Position
	local pole = frame.LookVector

	--[[
		Solve TWICE and apply the difference.

		A two-bone solve cannot reproduce an arbitrary animated pose -- it
		picks its own knee bend and roll -- so writing its output directly
		replaces the animation even when the correction is zero. That reads as
		the animation cutting out for a moment.

		Solving once for where the animation already is, and once for where
		the foot should end up, gives a delta that is exactly identity when
		the two agree. The animation then survives untouched and only the
		correction is layered on.
	]]
	local baseUpper, baseLower = TwoBone.solve(hipPos, leg.animCF.Position, leg.bone, pole)
	if not baseUpper then
		return
	end

	--[[
		The goal solve starts from where the hips END UP, after the drop and
		roll have been applied. Solving from the old position instead leaves
		each foot displaced by however far its hip just moved.
	]]
	local movedHip = (self.rootOp or CFrame.identity) * hipPos
	local target = leg.animCF.Position + Vector3.yAxis * (leg.delta * w)
	local goalUpper, goalLower, tipPos = TwoBone.solve(movedHip, target, leg.bone, pole)
	if not goalUpper then
		return
	end

	local function jointOf(motor, parentCF, worldCF)
		return (parentCF * motor.C0):Inverse() * worldCF * motor.C1
	end

	local hipBaseJoint = jointOf(leg.hip, leg.hip.Part0.CFrame, baseUpper)
	local hipGoalJoint = jointOf(leg.hip, leg.hip.Part0.CFrame, goalUpper)
	leg.hip.Transform *= hipBaseJoint:Inverse() * hipGoalJoint

	local kneeBaseJoint = jointOf(leg.knee, baseUpper, baseLower)
	local kneeGoalJoint = jointOf(leg.knee, goalUpper, goalLower)
	leg.knee.Transform *= kneeBaseJoint:Inverse() * kneeGoalJoint

	--[[
		If the target is further than the leg can span, roll onto the toe
		rather than letting the leg snap straight.

		Pivoting the foot about the toe drops the ankle by roughly the foot's
		length times sin(angle), which is real extra reach -- the same thing
		your ankle does walking down a step.
	]]
	if cfg.FootRoll and leg.heel and leg.toe then
		local span = leg.bone.l1 + leg.bone.l2
		local needed = (target - movedHip).Magnitude
		local toePos = (leg.toe.Part0.CFrame * leg.toe.C0).Position
		local footLength = math.max((toePos - tipPos).Magnitude, 0.05)

		local over = math.max(0, needed - span * 0.99)
		local wantRoll = math.asin(math.clamp(over / footLength, 0, 1))
		wantRoll = math.min(wantRoll, cfg.MaxFootRoll) * w
		leg.roll = Util.damp(leg.roll, wantRoll, cfg.BlendTime, self.dt)

		if leg.roll > 1e-4 then
			leg.heel.Transform = Util.applyWorldToJoint(leg.heel,
				Util.rotateAboutWorld(toePos, frame.RightVector, cfg.RollSign * leg.roll))
		end
	end

	-- Foot flat on the surface: its rest orientation, tilted by the slope.
	if cfg.AlignFeetToGround and leg.normal then
		local slope = math.acos(math.clamp(leg.normal:Dot(Vector3.yAxis), -1, 1))
		local tilt = (slope <= cfg.MaxSlopeAngle)
			and Util.rotationBetween(Vector3.yAxis, leg.normal)
			or CFrame.identity
		local footRot = tilt * frame.Rotation * leg.bindAnkleRot
		local ankleCF = CFrame.new(tipPos) * footRot * CFrame.new(-leg.ankleInPart)
		leg.ankle.Transform = leg.ankle.Transform:Lerp(
			jointOf(leg.ankle, goalLower, ankleCF), w)
	end
end

return FootIK
