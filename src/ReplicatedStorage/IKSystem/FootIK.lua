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

local function nearlyEqual(a: CFrame, b: CFrame): boolean
	return (a.Position - b.Position).Magnitude < 1e-5
		and a.LookVector:Dot(b.LookVector) > 0.999999
		and a.UpVector:Dot(b.UpVector) > 0.999999
end

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

--[[
	The animation's own value for a joint, ignoring what we last wrote to it.

	Every correction here is multiplicative, which is only safe if the
	Animator rewrites that joint every frame. It does for joints the
	animation keyframes -- but not for ones it never touches, like the root
	joint the hip offset rides on. There, composing onto the live value
	compounds the correction frame after frame until the pose is destroyed.

	If the value changed since we wrote it, the Animator has been here and
	that is the clean base. If it did not, nothing else is driving this joint,
	so the stored clean base still stands.
]]
function FootIK:_cleanBase(motor: Motor6D): CFrame
	self._clean = self._clean or {}
	self._written = self._written or {}

	local current = motor.Transform
	local written = self._written[motor]
	if written and nearlyEqual(current, written) then
		return self._clean[motor] or CFrame.identity
	end
	self._clean[motor] = current
	return current
end

-- Compose a joint-space delta onto the animation's value, not onto ours.
function FootIK:_compose(motor: Motor6D, delta: CFrame)
	local result = self:_cleanBase(motor) * delta
	motor.Transform = result
	self._written[motor] = result
end

-- Same, for a transformation expressed in world space.
function FootIK:_composeWorld(motor: Motor6D, worldOp: CFrame)
	local base = motor.Part0.CFrame * motor.C0
	local result = (base:Inverse() * worldOp * base) * self:_cleanBase(motor)
	motor.Transform = result
	self._written[motor] = result
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
	The pelvis as the ANIMATION has it, with our own drop and roll undone.

	The live pelvis carries last frame's correction, so forward kinematics
	from it measures this system's own output: the correction moves the hips,
	which moves the measured foot, which changes the correction. That loop is
	what makes a leg buzz at a surface transition.
]]
function FootIK:_restParent(leg): CFrame
	return (self.prevOp or CFrame.identity):Inverse() * leg.hip.Part0.CFrame
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
	--[[
		Read each joint's CLEAN base, not its live Transform.

		For any joint the animation does not rewrite every frame, the live
		Transform is our own correction from last frame -- so chaining live
		values measures this system's output and the result drifts away from
		the real animated pose entirely.
	]]
	local hipT = self:_cleanBase(leg.hip)
	local kneeT = self:_cleanBase(leg.knee)
	local ankleT = self:_cleanBase(leg.ankle)

	local upper = self:_restParent(leg) * leg.hip.C0 * hipT * leg.hip.C1:Inverse()
	local lower = upper * leg.knee.C0 * kneeT * leg.knee.C1:Inverse()
	return lower * leg.ankle.C0 * ankleT * leg.ankle.C1:Inverse()
end

--[[
	The floor the body as a whole is standing on -- live, every frame, with
	nothing smoothing it.

	This used to raycast under the root and damp the result, which turns out
	to be the one thing it must not do. The Humanoid climbs a step by
	physically lifting the character; a reference that lags says the ground
	under the body has not moved yet, so it invents a correction for a foot
	that needs none and then unwinds it as the reference catches up. That
	pump is the twitch, and it is worst at exactly the moment it is meant to
	help.

	Power IK's ground node does the same as this: its reference is a BONE,
	normally the root, and what gets smoothed is the foot effector -- never
	the plane. Deriving the floor from the root also means it can never
	disagree with the body, whereas a raycast jumps a whole step the instant
	its sample crosses an edge, while the body is still on its way up.

	Root jitter is what the dead zone and the weight ramp are for.
]]
function FootIK:_floorY(): number?
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
	if not frame then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rig.character }
	params.IgnoreWater = true

	local floorY = self:_floorY()
	if not floorY then
		return
	end

	self.dt = dt
	-- Last frame's pelvis correction, so this frame can measure the animation
	-- with it removed rather than reading back its own output.
	self.prevOp = self.rootOp or CFrame.identity
	self.rootOp = CFrame.identity
	local grounded = true
	local humanoid = rig.humanoid
	if humanoid then
		local state = humanoid:GetState()
		grounded = humanoid.FloorMaterial ~= Enum.Material.Air
			and state ~= Enum.HumanoidStateType.Freefall
			and state ~= Enum.HumanoidStateType.Jumping
	end

	--[[
		Measure both legs before weighing either.

		How planted a foot is comes from comparing it against the other foot,
		so neither answer exists until both have been read.
	]]
	local datum
	for _, side in SIDES do
		local leg = self.legs[side]
		if leg then
			leg.wanted = nil
			self:_measureLeg(leg, floorY, params)
			if leg.wanted and (not datum or leg.bodyY < datum) then
				datum = leg.bodyY
			end
		end
	end

	--[[
		Weight the hip's vote by the same factor as the leg's own correction,
		so a foot inside the dead zone or up in the air contributes nothing.
		Using the raw delta instead means a HipHeight that is off by a
		hundredth sinks the hips permanently, because nothing filters it out.
	]]
	for _, side in SIDES do
		local leg = self.legs[side]
		if leg and leg.wanted then
			self:_weighLeg(leg, datum, grounded)
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
	wantDrop = math.clamp(grounded and wantDrop or 0,
		self.hipDrop - cfg.MaxHipRate * dt, self.hipDrop + cfg.MaxHipRate * dt)
	self.hipDrop = Util.damp(self.hipDrop, wantDrop, cfg.SmoothTime, dt)

	local wantRoll = 0
	if cfg.HipRoll and grounded then
		-- Height difference across the hips becomes a tilt angle.
		wantRoll = math.clamp(math.atan2(dL - dR, math.max(cfg.HipWidth, 0.1)),
			-cfg.MaxHipRoll, cfg.MaxHipRoll)
	end
	local roll = self.hipRoll or 0
	wantRoll = math.clamp(wantRoll, roll - cfg.MaxRollRate * dt, roll + cfg.MaxRollRate * dt)
	self.hipRoll = Util.damp(roll, wantRoll, cfg.SmoothTime, dt)

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
			self:_composeWorld(rootMotor, op)
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
				self:_composeWorld(motor,
					Util.rotateAboutWorld(pivot, frame.LookVector, share))
			end
		end
	end

	for _, side in SIDES do
		self:_apply(self.legs[side], frame)
	end

	if Config.Debug then
		self._nextLog = self._nextLog or 0
		if os.clock() >= self._nextLog then
			self._nextLog = os.clock() + 0.5
			local function fmt(side)
				local leg = self.legs[side]
				if not leg then return side .. "=none" end
				return ("%s raw=%+.3f d=%+.3f w=%.2f plant=%.2f lift=%.2f"):format(
					side:sub(1, 1), leg.raw or 0, leg.delta, leg.weight,
					leg.plant or 0, leg.lift or 0)
			end
			--[[
				Diagnostic only, and deliberately not fed back into anything:
				how far the root-derived floor sits from the real one. A
				standing offset here is a HipHeight that wants correcting,
				and it would otherwise be invisible.
			]]
			local rootPart = rig.parts.Root
			local probe = rootPart and self:_sampleGround(
				Vector3.new(rootPart.Position.X, floorY, rootPart.Position.Z), params)
			print(("[FootIK] floor=%.2f err=%+.3f drop=%+.3f roll=%+.1fdeg | %s | %s"):format(
				floorY, probe and (probe - floorY) or 0,
				self.hipDrop, math.deg(self.hipRoll or 0),
				fmt("Left"), fmt("Right")))
		end
	end
end

--[[
	Highest ground under the foot, sampled across its footprint.

	Returns the surface height and the normal of whichever sample won, or nil
	if nothing is underneath at all.
]]
function FootIK:_sampleGround(centre: Vector3, params: RaycastParams): (number?, Vector3)
	local cfg = Config.FootIK
	local r = cfg.SampleRadius
	local down = Vector3.yAxis * -(cfg.RayUp + cfg.RayDown)

	local best, bestNormal = nil, Vector3.yAxis
	for _, offset in {
		Vector3.zero,
		Vector3.new(r, 0, 0), Vector3.new(-r, 0, 0),
		Vector3.new(0, 0, r), Vector3.new(0, 0, -r),
	} do
		local hit = workspace:Raycast(centre + offset + Vector3.yAxis * cfg.RayUp, down, params)
		if hit and (not best or hit.Position.Y > best) then
			best, bestNormal = hit.Position.Y, hit.Normal
		end
	end
	return best, bestNormal
end

--[[
	Read where the animation has put this foot, and how far its ground differs
	from the reference. Nothing is weighed here: that needs both legs.
]]
function FootIK:_measureLeg(leg, floorY: number, params: RaycastParams)
	local cfg = Config.FootIK
	local animCF = self:_animatedAnkle(leg)
	leg.animCF = animCF

	--[[
		The animated foot's height relative to the BODY.

		This is the animation's own foot curve, recovered: a function of where
		the clip is in its cycle and of nothing else. No terrain can move it.
	]]
	local root = self.rig.parts.Root
	leg.bodyY = root and (animCF.Position.Y - root.Position.Y) or 0

	local hit, normal = self:_sampleGround(animCF.Position, params)
	if not hit then
		leg.delta = 0
		return
	end

	--[[
		How far this foot's ground differs from the assumed floor. Zero on
		level ground, positive on a step up, negative over a drop. Note what
		it does not depend on: where the foot currently is.
	]]
	local raw = math.clamp(hit - floorY, -cfg.MaxStepDown, cfg.MaxStepUp)

	--[[
		Smooth both the correction and its weight. Stepping onto or off a
		ledge changes the raycast result discontinuously, and applying that
		jump straight to the joints is what makes a leg snap for a frame.
	]]
	-- Rate-limit first, then smooth: a surface that changes faster than the
	-- smoothing can absorb would otherwise still arrive as a jolt.
	local maxStep = cfg.MaxCorrectionRate * self.dt
	local limited = math.clamp(raw, leg.delta - maxStep, leg.delta + maxStep)
	leg.delta = Util.damp(leg.delta, limited, cfg.SmoothTime, self.dt)

	leg.normal = normal
	leg.raw = raw
	leg.wanted = true
end

--[[
	How much of this leg's correction to apply.

	Whether a foot is planted or swinging is a fact about the ANIMATION, and
	the reference implementations all treat it as one: Unity and Unreal bake a
	foot-contact curve into the clip and drive the IK weight from that. The
	raycast decides only WHERE the ground is -- never whether the foot is on
	it.

	Roblox animations carry no such curve, so it is recovered by comparing the
	two feet. In a walk cycle the lower foot is the one taking the weight, and
	the other is as lifted as the animation has lifted it. Both are measured
	against the same root, so that comparison is immune to the terrain and to
	the body's own bob alike.

	Every ground-derived version of this got it backwards exactly when it
	mattered. Walking onto something higher, the swinging foot passes low over
	the new surface, its clearance collapses, and it reads as planted -- so
	the IK hauls it down onto the step mid-stride while the animation is still
	lifting it. Measuring against a smoothed reference plane only delays that,
	because the plane climbs the step too.
]]
function FootIK:_weighLeg(leg, datum: number?, grounded: boolean)
	local cfg = Config.FootIK
	local lift = math.max(0, leg.bodyY - (datum or leg.bodyY) - cfg.PlantSlack)
	local plant = 1 - math.clamp(lift / math.max(cfg.LiftThreshold, 1e-4), 0, 1)

	--[[
		Ignore small differences, and ramp in over a step-sized range rather
		than over the dead zone itself.

		Ramping over the dead zone reached full strength at twice it -- about
		a tenth of a stud -- which is inside the Humanoid's own vertical
		wobble. The IK would then chase that wobble at near-full weight on
		perfectly flat ground.
	]]
	local wantWeight = math.clamp(
		(math.abs(leg.delta) - cfg.DeadZone) / math.max(cfg.RampWidth, 1e-4), 0, 1) * plant

	--[[
		In the air the IK has nothing to say, but it has to stop saying it
		GRADUALLY.

		Skipping the update entirely, as this did, freezes the legs holding
		whatever correction they had. A short step up can drop the Humanoid
		into Freefall for a handful of frames on the way over the lip, so that
		stall lands in the middle of the transition it was supposed to smooth.
	]]
	if not grounded then
		wantWeight = 0
	end

	leg.weight = Util.damp(leg.weight, wantWeight, cfg.BlendTime, self.dt)
	leg.plant = plant
	leg.lift = lift
end

function FootIK:_apply(leg, frame: CFrame)
	if not (leg and leg.animCF) then
		return
	end

	local cfg = Config.FootIK
	local w = leg.weight

	--[[
		A leg with no ground correction of its own STILL has to be solved
		whenever the pelvis has moved.

		Everything below the hips is a chain: rolling the pelvis to give one
		leg more room lifts the other leg with it, foot and all. Keeping that
		foot where it was means actively re-solving the leg against a hip that
		has moved -- skipping it is what makes the opposite foot rise.

		Only when the pelvis is still is "no correction" the same as "leave it
		alone".
	]]
	local hipMoved = math.abs(self.hipDrop) > 1e-4 or math.abs(self.hipRoll or 0) > 1e-4
	if w <= 1e-3 and not hipMoved then
		return
	end

	local restParent = self:_restParent(leg)
	local hipBase = restParent * leg.hip.C0
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

	--[[
		With w at zero this is just the animated foot position, so the solve
		holds the foot exactly where the animation put it while the hip moves
		underneath it. That is the compensation.
	]]
	local target = leg.animCF.Position + Vector3.yAxis * (leg.delta * w)
	local goalUpper, goalLower, tipPos = TwoBone.solve(movedHip, target, leg.bone, pole)
	if not goalUpper then
		return
	end

	local function jointOf(motor, parentCF, worldCF)
		return (parentCF * motor.C0):Inverse() * worldCF * motor.C1
	end

	--[[
		The goal is expressed relative to where the Hip part ENDS UP, not
		where it is now.

		A joint Transform is applied relative to its Part0 at solve time, and
		Part0 here is the pelvis, which the root write above has already
		moved. Converting against the pre-move pelvis bakes that movement into
		the leg as well, so the roll lands twice and the legs are thrown
		clear of the body.

		The base solve deliberately keeps the pre-move pelvis: it represents
		the animation's pose, which was authored against an untilted one.
	]]
	local movedParent = (self.rootOp or CFrame.identity) * restParent
	local hipBaseJoint = jointOf(leg.hip, restParent, baseUpper)
	local hipGoalJoint = jointOf(leg.hip, movedParent, goalUpper)
	self:_compose(leg.hip, hipBaseJoint:Inverse() * hipGoalJoint)

	local kneeBaseJoint = jointOf(leg.knee, baseUpper, baseLower)
	local kneeGoalJoint = jointOf(leg.knee, goalUpper, goalLower)
	self:_compose(leg.knee, kneeBaseJoint:Inverse() * kneeGoalJoint)

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
			self:_composeWorld(leg.heel,
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
		local ankleBase = self:_cleanBase(leg.ankle)
		local ankleResult = ankleBase:Lerp(jointOf(leg.ankle, goalLower, ankleCF), w)
		leg.ankle.Transform = ankleResult
		self._written[leg.ankle] = ankleResult
	end
end

return FootIK
