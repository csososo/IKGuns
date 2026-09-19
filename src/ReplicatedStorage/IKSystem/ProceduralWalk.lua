--[[
	ProceduralWalk -- generates the whole gait, replacing the animation.

	This is the other half of the fork from FootIK. FootIK assumes a clip owns
	the pose and only nudges the feet onto real ground; this owns the pose
	outright. Nothing else may write Motor6D.Transform while it runs, and
	because nothing does, it can write joints directly -- no clean-base
	bookkeeping, no composing onto someone else's value, no reading back its
	own output the frame after. That whole class of bug is simply absent here.

	Two ideas carry it:

	1. The phase advances with DISTANCE, not time. A planted foot travels
	   backwards through stance at exactly the speed the body travels
	   forwards, so it cannot slide at any speed, and cadence rises with
	   speed without being told to.

	2. Everything is solved against a pelvis this module computes itself,
	   never against the live part. The live pelvis is last frame's answer,
	   and feeding it back in is what makes a procedural leg buzz.
]]

local Config = require(script.Parent.Config)
local TwoBone = require(script.Parent.TwoBone)
local Util = require(script.Parent.Util)

local ProceduralWalk = {}
ProceduralWalk.__index = ProceduralWalk

-- Sign along the body's right axis, and the phase offset that puts the two
-- legs half a stride apart.
local SIDES = {
	Left = { sign = -1, offset = 0 },
	Right = { sign = 1, offset = 0.5 },
}
local ORDER = { "Left", "Right" }

function ProceduralWalk.new(rig)
	local self = setmetatable({}, ProceduralWalk)
	self.rig = rig
	self.legs = {}
	self.phase = 0
	self.blend = 0
	self.speed = 0
	self.cadence = 0
	self:_measure()

	--[[
		Say whether the shoulders resolved.

		Arm swing is optional and skips silently when the joint name does not
		match, which is indistinguishable from a swing angle set too low --
		you would sit there dragging the slider wondering why nothing moves.
	]]
	local ready, arms = {}, 0
	for _, side in ORDER do
		if self.legs[side] then
			table.insert(ready, side)
			arms += self.legs[side].shoulder and 1 or 0
		end
	end
	print(("[ProceduralWalk] %d legs ready: %s | %d/%d shoulders for arm swing (%s)")
		:format(#ready, #ready > 0 and table.concat(ready, ", ") or "NONE",
			arms, #ready, Config.Walk.ShoulderJoint))

	return self
end

function ProceduralWalk:_measure()
	local rig = self.rig
	local cfg = Config.Walk
	local forward = -Vector3.zAxis

	for _, side in ORDER do
		local hip = rig:FindMotor(cfg.HipJoint:format(side))
		local knee = rig:FindMotor(cfg.KneeJoint:format(side))
		local ankle = rig:FindMotor(cfg.AnkleJoint:format(side))
		if not (hip and knee and ankle and hip.Part0 and hip.Part1 and knee.Part1) then
			warn(("[ProceduralWalk] %s leg joints missing; skipping."):format(side))
			continue
		end

		local bone = TwoBone.measure(rig, hip, knee, ankle, forward)
		local bindAnkle = rig:GetBindOffset(ankle.Part1)
		if not (bone and bindAnkle) then
			warn(("[ProceduralWalk] %s leg geometry unreadable; skipping."):format(side))
			continue
		end

		--[[
			Ankle-to-toe length, measured off the rig's own bind pose.

			Plantarflexion at push-off pivots on the toe, so the ankle rises
			by this times the sine of the angle. That is real reach, and
			getting it from the rig means it stays right if the foot is
			remodelled.
		]]
		local toe = rig:FindMotor(cfg.ToeJoint:format(side))
		local bindToe = toe and toe.Part1 and rig:GetBindOffset(toe.Part1)
		local toeAhead = cfg.ToeAhead
		if toeAhead <= 0 and bindToe then
			local span = bindToe.Position - bindAnkle.Position
			toeAhead = Vector3.new(span.X, 0, span.Z).Magnitude
		end

		self.legs[side] = {
			hip = hip,
			knee = knee,
			ankle = ankle,
			bone = bone,
			bindAnkleRot = bindAnkle.Rotation,
			ankleInPart = ankle.C1.Position,
			-- All optional. Each feature is skipped if its joint is absent.
			shoulder = rig:FindMotor(cfg.ShoulderJoint:format(side)),
			elbow = rig:FindMotor(cfg.ElbowJoint:format(side)),
			heel = rig:FindMotor(cfg.HeelJoint:format(side)),
			toe = toe,
			toeAhead = toeAhead,
			-- Where this foot is planted in the world, and where its current
			-- swing started. Both nil until the first frame places them.
			anchor = nil,
			from = nil,
		}
	end
end

--[[
	The floor the body is standing on, from the root and HipHeight.

	Live and unsmoothed, for the reason the animated path had to learn the
	hard way: the Humanoid climbs a step by physically lifting the character,
	so a reference that lags claims the ground has not moved yet and invents
	a correction that it then has to unwind.
]]
function ProceduralWalk:_floorY(): number?
	local root = self.rig.parts.Root
	if not root then
		return nil
	end
	local hipHeight = self.rig.humanoid and self.rig.humanoid.HipHeight or 0
	return root.Position.Y - root.Size.Y * 0.5 - hipHeight
end

function ProceduralWalk:_ground(at: Vector3, params: RaycastParams): (number?, Vector3)
	local cfg = Config.Walk
	local hit = workspace:Raycast(at + Vector3.yAxis * cfg.RayUp,
		Vector3.yAxis * -(cfg.RayUp + cfg.RayDown), params)
	if hit then
		return hit.Position.Y, hit.Normal
	end
	return nil, Vector3.yAxis
end

-- Height of the swing arc, nil at both ends so the foot leaves and meets the
-- ground rather than arriving at it sideways.
local function swingLift(t: number, height: number): number
	return math.sin(math.pi * t) * height
end

--[[
	How the foot is pitched at this point in the cycle, and how far the toe
	joint gives back, both in radians. Positive pitch is toes up.

	This is the part a flat-footed procedural walk is missing, and it is the
	single largest difference between one that reads as walking and one that
	reads as sliding. Real stance is four events, not one:

		heel strike   toes up, only the heel touching
		foot flat     rolled down onto the sole, ~12% into stance
		heel rise     heel lifts, ~60% in
		toe off       toes down 15-20 degrees, pivoting over the toe

	Swing then carries the foot back up to the heel-strike attitude, which
	is also what clears it over the ground.

	Dorsiflexion through midstance is deliberately absent: the foot is held
	flat on the surface and the shin comes down to meet it, so the ankle
	angle there falls out of the IK on its own. Only the parts the geometry
	CANNOT produce are driven here.
]]
local function footRoll(p: number, duty: number, cfg): (number, number)
	local strike = math.rad(cfg.HeelStrikeAngle)
	local push = math.rad(cfg.ToeOffAngle)

	if p >= duty then
		-- Swing: ease from the toe-off attitude back to the next heel strike.
		local t = (p - duty) / math.max(1 - duty, 1e-4)
		local eased = t * t * (3 - 2 * t)
		local pitch = -push + (strike + push) * eased
		-- The toe unbends quickly once it leaves the ground.
		return pitch, push * cfg.ToeBend * (1 - math.min(t * 3, 1))
	end

	local s = p / duty
	local flat = math.clamp(cfg.FlatAt, 0.01, 0.9)
	local rise = math.clamp(cfg.HeelRiseAt, flat + 0.01, 0.99)

	if s < flat then
		-- Rolling down onto the sole. Fast, because a real one is.
		return strike * (1 - s / flat), 0
	end
	if s < rise then
		return 0, 0
	end

	--[[
		Heel rise into toe off, squared rather than linear: the heel barely
		moves at first and then goes quickly, which is what a push looks
		like. Linear here reads as the foot being peeled off the floor.
	]]
	local t = (s - rise) / math.max(1 - rise, 1e-4)
	local eased = t * t
	return -push * eased, push * cfg.ToeBend * eased
end

function ProceduralWalk:Update(dt: number)
	local cfg = Config.Walk
	local rig = self.rig
	local root = rig.parts.Root
	local rootMotor = rig.motors.Root
	if not (root and rootMotor and rootMotor.Part0) then
		return
	end

	local frame = rig:GetYawFrame()
	local floorY = self:_floorY()
	if not (frame and floorY) then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rig.character }
	params.IgnoreWater = true

	local velocity = root.AssemblyLinearVelocity
	local ground = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	self.speed = Util.damp(self.speed, ground, cfg.SpeedSmooth, dt)

	local moving = self.speed > cfg.MinSpeed
	self.blend = Util.damp(self.blend, moving and 1 or 0, cfg.BlendTime, dt)

	--[[
		Advance by distance covered, not by time.

		One foot's stance lasts as long as the body takes to travel one step
		length, which is what pins the planted foot to the ground. Driving
		the phase off a clock instead means picking a cadence, and then the
		feet skate whenever the speed disagrees with it.
	]]
	if moving then
		local length = math.max(cfg.StepLength, 0.1)
		self.cadence = self.speed * cfg.DutyFactor / length
	end

	--[[
		Keep the cycle turning while the gait folds away.

		Freezing the phase the instant you stop leaves the legs stuck
		mid-stride while the stride shrinks around them, which is exactly
		what "it freezes, then goes back to idle" looks like. Letting it
		keep advancing -- scaled by the blend, so it slows as it fades --
		finishes the step that was in progress and decelerates into the
		stance instead.
	]]
	self.phase = (self.phase
		+ (self.cadence or 0) * (moving and 1 or self.blend) * dt) % 1

	local turns = math.pi * 2
	local bob = math.sin((self.phase * 2 + cfg.BobPhase) * turns) * cfg.BobHeight * self.blend
	local sway = math.sin((self.phase + cfg.SwayPhase) * turns) * cfg.SwayWidth * self.blend
	local yaw = math.sin((self.phase + cfg.SwayPhase) * turns) * math.rad(cfg.BodyYaw) * self.blend
	local lean = math.rad(cfg.LeanAngle) * self.blend
		* math.clamp(self.speed / math.max(cfg.LeanSpeed, 0.1), 0, 1)

	--[[
		Build the pelvis WE want, then tell the joint to produce it.

		Reading rootMotor.Part0.CFrame is fine -- that is the
		HumanoidRootPart, which physics owns and we never touch. What must
		not happen is reading the pelvis itself, which is this module's own
		output from last frame.
	]]
	local parentCF = rootMotor.Part0.CFrame * rootMotor.C0
	local restPelvis = parentCF * rootMotor.C1:Inverse()

	--[[
		Pelvic list: the hip on the swinging side drops, about 5 degrees in a
		real walk.

		This is one of the classic six determinants of gait, and it is what
		keeps the body's centre of mass travelling in a flatter line than the
		legs alone would allow. Without it the hips stay rigidly level and
		the whole pelvis reads as a plank the legs are bolted to.
	]]
	local list = math.sin((self.phase + cfg.PelvisListPhase) * turns)
		* math.rad(cfg.PelvisList) * self.blend

	local op = CFrame.new(Vector3.yAxis * bob + frame.RightVector * sway)
	if math.abs(list) > 1e-5 then
		op *= Util.rotateAboutWorld(restPelvis.Position, frame.LookVector, list)
	end
	local pelvisCF = op * restPelvis * CFrame.Angles(lean, yaw, 0)
	rootMotor.Transform = parentCF:Inverse() * pelvisCF * rootMotor.C1

	local chestCF = self:_spine(pelvisCF, yaw)
	local duty = math.clamp(cfg.DutyFactor, 0.05, 0.95)

	for _, side in ORDER do
		local leg = self.legs[side]
		if leg then
			self:_leg(leg, SIDES[side], frame, pelvisCF, floorY, params)
			self:_arm(leg, (self.phase + SIDES[side].offset) % 1, chestCF, frame)
		end
	end
end

--[[
	Give back most of the pelvis rotation up the spine.

	The pelvis and the thorax counter-rotate in a real walk -- that opposition
	is what the arm swing is actually driven by, and it is why the shoulders
	stay pointing where you are going while the hips twist under them. Without
	it the whole torso yaws as one block and the character reads as swivelling
	rather than walking.

	Chained off the pelvis WE computed, not the live part: the live pelvis is
	this module's own output from last frame.
]]
function ProceduralWalk:_spine(pelvisCF: CFrame, yaw: number)
	local cfg = Config.Walk
	local spine = self.rig.spine
	if not spine then
		return pelvisCF
	end

	local parent = pelvisCF
	for _, joint in spine do
		local motor = joint.motor
		local base = parent * motor.C0
		local share = -yaw * cfg.ChestCounter * (joint.weight or 0)
		local turn = (math.abs(share) > 1e-5)
			and Util.rotateAboutWorld(base.Position, Vector3.yAxis, share)
			or CFrame.identity
		local transform = base:Inverse() * turn * base
		motor.Transform = transform
		parent = base * transform * motor.C1:Inverse()
	end
	return parent
end

function ProceduralWalk:_leg(leg, side, frame: CFrame, pelvisCF: CFrame, floorY: number, params: RaycastParams)
	local cfg = Config.Walk

	local hipCF = pelvisCF * leg.hip.C0
	local hipPos = hipCF.Position

	local duty = math.clamp(cfg.DutyFactor, 0.05, 0.95)
	local p = (self.phase + side.offset) % 1
	local swinging = p >= duty

	--[[
		Where this foot would stand with no gait at all: under its own hip.

		This is both the idle pose and the reference everything else is
		measured from, so idle needs no separate code path. Stance width and
		the forward bias are posture rather than gait, so they apply even
		standing still.
	]]
	local neutral = Vector3.new(hipPos.X, floorY, hipPos.Z)
		+ frame.LookVector * cfg.FootAhead
		+ frame.RightVector * (side.sign * cfg.StanceWidth * 0.5)

	local lift = 0
	local place

	if swinging then
		local t = (p - duty) / math.max(1 - duty, 1e-4)

		--[[
			Aim at where the body WILL be, not where it is.

			The body covers (1-duty)/duty step lengths during one swing, and
			that ratio does not depend on speed -- a faster walk has a
			proportionally shorter swing. Recomputing the remaining travel
			every frame rather than committing at lift-off means a turn
			mid-stride redirects the step instead of planting it where you
			used to be going.

			At t=1 the remaining travel is zero, so the target is simply half
			a stride ahead of the hip: a heel strike.
		]]
		local remaining = cfg.StepLength * (1 - duty) / duty * (1 - t)
		local landing = neutral + frame.LookVector * (remaining + cfg.StepLength * 0.5)

		leg.from = leg.from or neutral
		place = leg.from:Lerp(landing, t * t * (3 - 2 * t))
		lift = swingLift(t, cfg.StepHeight)
		leg.anchor = landing
	else
		--[[
			STANCE: the foot does not move. At all.

			This is the difference between walking and waving your legs
			about while you slide. Previously the foot was positioned
			relative to the hip every frame, so it tracked the body exactly
			and never pushed against anything. Pinning it to the world and
			letting the hip travel away from it is what makes a step a step.
		]]
		leg.anchor = leg.anchor or neutral
		leg.from = leg.anchor
		place = leg.anchor
	end

	--[[
		A planted foot the hips have walked away from -- a hard turn, a
		sudden speed change, a shove -- would otherwise stretch the leg until
		the solver clamps and the foot visibly tears off its anchor. Slide
		the anchor in instead, proportionally to how far past the limit it
		has got.
	]]
	local reach = (Vector3.new(place.X - hipPos.X, 0, place.Z - hipPos.Z)).Magnitude
	local limit = math.max(cfg.StepLength, 0.1) * cfg.MaxStride
	if reach > limit then
		local slide = math.clamp((reach - limit) / limit, 0, 1)
		place = place:Lerp(neutral, slide)
		leg.anchor = leg.anchor:Lerp(neutral, slide)
	end

	-- Fold the whole gait back to the standing pose as the blend drops.
	place = neutral:Lerp(place, self.blend)
	lift *= self.blend
	if self.blend < 0.01 then
		leg.anchor = neutral
		leg.from = neutral
	end

	local plant = place

	local pitch, toeBend = footRoll(p, duty, cfg)
	local gain = cfg.FootPitchScale * self.blend
	pitch, toeBend = pitch * gain, toeBend * gain

	--[[
		Plantarflexion pivots on the toe, which lifts the ankle by the foot's
		length times the sine of the angle.

		Without this the foot rotates but the ankle stays put, so the toe
		drives into the floor and the push-off reads as the foot clipping
		through rather than pressing off. It is also genuine extra reach --
		the same thing your ankle does stepping down off a kerb.
	]]
	local pivotLift = math.max(0, math.sin(-pitch)) * leg.toeAhead

	local surface, normal = self:_ground(plant, params)
	local target = Vector3.new(plant.X,
		(surface or floorY) + cfg.AnkleHeight + lift + pivotLift, plant.Z)

	local upperCF, lowerCF, tipPos = TwoBone.solve(hipPos, target, leg.bone, frame.LookVector)
	if not upperCF then
		return
	end

	--[[
		Motor6D solves part1 = part0 * C0 * Transform * C1:Inverse(), so
		Transform = (part0 * C0):Inverse() * part1 * C1. Each joint's parent
		here is the CFrame the solve produced, not the live part, so the
		whole chain is one feed-forward pass.
	]]
	leg.hip.Transform = hipCF:Inverse() * upperCF * leg.hip.C1
	leg.knee.Transform = (upperCF * leg.knee.C0):Inverse() * lowerCF * leg.knee.C1

	-- Foot flat on the surface: its rest orientation, tilted by the slope.
	local slope = math.acos(math.clamp(normal:Dot(Vector3.yAxis), -1, 1))
	local tilt = (slope <= cfg.MaxSlopeAngle)
		and Util.rotationBetween(Vector3.yAxis, normal)
		or CFrame.identity
	local ankleCF = CFrame.new(tipPos)
		* (tilt * frame.Rotation * leg.bindAnkleRot)
		* CFrame.new(-leg.ankleInPart)
	leg.ankle.Transform = (lowerCF * leg.ankle.C0):Inverse() * ankleCF * leg.ankle.C1

	--[[
		The ankle rocker rides on the heel joint, and the toe bend on the
		forefoot joint, so the ankle plate above still follows the terrain
		while the foot rolls heel to toe on top of it.

		Both are applied as rotations about the body's right axis in WORLD
		space and converted back through the Motor6D definition, so neither
		depends on knowing which way this rig's joint axes point. If the
		whole roll happens backwards, negate FootPitchScale -- that is what
		it is for.
	]]
	local footCF = ankleCF
	if leg.heel then
		local base = ankleCF * leg.heel.C0
		local turn = (math.abs(pitch) > 1e-5)
			and Util.rotateAboutWorld(base.Position, frame.RightVector, pitch)
			or CFrame.identity
		local transform = base:Inverse() * turn * base
		leg.heel.Transform = transform
		footCF = base * transform * leg.heel.C1:Inverse()
	end

	if leg.toe then
		local base = footCF * leg.toe.C0
		local turn = (math.abs(toeBend) > 1e-5)
			and Util.rotateAboutWorld(base.Position, frame.RightVector, toeBend)
			or CFrame.identity
		leg.toe.Transform = base:Inverse() * turn * base
	end

end

--[[
	The arm for this leg, swinging against it.

	A shoulder rotating on its own is the thing that reads as a mannequin:
	real arm swing bends at the elbow too, and bends FURTHER as the arm comes
	forward. The elbow also never straightens fully, even standing still, so
	its resting bend is posture and survives the blend.

	Chained off the chest this module computed rather than the live part,
	like everything else here.
]]
function ProceduralWalk:_arm(leg, p: number, chestCF: CFrame, frame: CFrame)
	if not leg.shoulder then
		return
	end
	local cfg = Config.Walk

	-- Half a cycle out of phase with its own leg: left arm forward with the
	-- right leg, which is what the counter-rotating torso is doing anyway.
	local forward = math.sin(((p + 0.5) % 1) * math.pi * 2)

	local shoulderBase = chestCF * leg.shoulder.C0
	local swing = math.rad(cfg.ArmSwing) * forward * self.blend
	local turn = (math.abs(swing) > 1e-5)
		and Util.rotateAboutWorld(shoulderBase.Position, frame.RightVector, swing)
		or CFrame.identity
	local shoulderT = shoulderBase:Inverse() * turn * shoulderBase
	leg.shoulder.Transform = shoulderT

	if not leg.elbow then
		return
	end

	-- 0 at the back of the swing, 1 at the front.
	local ahead = 0.5 + 0.5 * forward
	local bend = math.rad(cfg.ElbowBend) + math.rad(cfg.ElbowSwing) * ahead * self.blend

	local upperCF = shoulderBase * shoulderT * leg.shoulder.C1:Inverse()
	local elbowBase = upperCF * leg.elbow.C0
	local flex = (math.abs(bend) > 1e-5)
		and Util.rotateAboutWorld(elbowBase.Position, frame.RightVector, bend)
		or CFrame.identity
	leg.elbow.Transform = elbowBase:Inverse() * flex * elbowBase
end

--[[
	Hand the rig back to whatever else might drive it.

	Leaving the last frame's Transform behind would freeze the character
	mid-stride, since nothing else is writing these joints.
]]
function ProceduralWalk:Reset()
	local rootMotor = self.rig.motors.Root
	if rootMotor then
		rootMotor.Transform = CFrame.identity
	end
	for _, joint in self.rig.spine or {} do
		joint.motor.Transform = CFrame.identity
	end
	for _, side in ORDER do
		local leg = self.legs[side]
		if leg then
			for _, key in { "hip", "knee", "ankle", "shoulder", "elbow", "heel", "toe" } do
				if leg[key] then
					leg[key].Transform = CFrame.identity
				end
			end
		end
	end
end

return ProceduralWalk
