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
	Left = { sign = -1, offset = 0, other = "Right" },
	Right = { sign = 1, offset = 0.5, other = "Left" },
}
local ORDER = { "Left", "Right" }

-- Below this blend the gait is done and the idle stance owns the feet.
local SETTLED = 0.05

function ProceduralWalk.new(rig)
	local self = setmetatable({}, ProceduralWalk)
	self.rig = rig
	self.legs = {}
	self.phase = 0
	self.blend = 0
	self.speed = 0
	self.cadence = 0
	self.velocity = nil
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
			-- Phase offset from an early step, unwound over later strides.
			shift = 0,
			-- True while this foot is turning under itself to catch up.
			pivoting = false,
			-- Set when the other foot had to step around this one.
			crowded = false,
			-- Last frame's world position, for the foot speed ceiling.
			last = nil,
			-- The heading this foot landed on. Held for as long as it is
			-- planted, so turning the body cannot spin a foot in place.
			footRot = nil,
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

	self.dt = dt

	--[[
		Smooth the velocity VECTOR, and take both speed and direction from
		it. Smoothing the magnitude separately is what makes mashing A and D
		look silly.

		Held alternately, those cancel: you go nowhere. But |velocity| never
		drops -- you are always moving hard at 16 studs a second, just not in
		any direction for long -- so the gait reads a sprint and runs full
		strides back and forth over the same patch of ground. Smoothing the
		vector cancels the way the movement does, the speed falls to
		something small, and the gait settles into shuffles, which is what
		someone twitching side to side actually does.

		Straight-line movement is unaffected: with a steady direction,
		smoothing the vector and smoothing its length are the same thing.
	]]
	local velocity = root.AssemblyLinearVelocity
	local travel = Vector3.new(velocity.X, 0, velocity.Z)
	self.velocity = (self.velocity or travel):Lerp(travel,
		1 - math.exp(-dt / math.max(cfg.SpeedSmooth, 1e-3)))
	self.speed = self.velocity.Magnitude

	local moving = self.speed > cfg.MinSpeed
	self.blend = Util.damp(self.blend, moving and 1 or 0, cfg.BlendTime, dt)

	--[[
		The direction the body is TRAVELLING, which is not the direction it
		is facing.

		Steps used to go along the facing, so the feet marched forwards no
		matter which way the character was actually going: backwards walked
		the legs the wrong way entirely, and strafing stepped sideways with
		a forward stride. Placing them along the velocity makes backwards,
		strafing and every diagonal fall out of the same code, because a
		step goes where you are going.

		Held rather than zeroed when stopped, so the last step of a stop
		finishes in the direction it was already heading.
	]]
	local wanted = self.velocity.Magnitude > 1e-3 and self.velocity.Unit
		or self.moveDir or frame.LookVector

	--[[
		Turned as an ANGLE, not lerped between two direction vectors.

		Reversing makes the target the exact opposite of the current
		direction, and a lerp between opposite unit vectors passes through
		zero length -- so at the halfway point the direction is undefined
		and thrashes, which is the legs getting stuck when you change
		direction. Rotating by a bounded angle instead sweeps through the
		reversal smoothly and can never degenerate.

		Same mistake as the foot aim lerp, in a different place. Any time
		two unit vectors are interpolated and one can oppose the other, the
		answer is an angle.
	]]
	local from = self.moveDir or wanted
	local here = math.atan2(-from.X, -from.Z)
	local there = math.atan2(-wanted.X, -wanted.Z)
	local diff = (there - here + math.pi) % (math.pi * 2) - math.pi
	--[[
		An angular RATE, not "a reversal per TurnTime".

		Phrased as a time-to-complete, a 45 degree input change finished in
		under two frames -- 1500 degrees a second -- which swung the landing
		target, four and a half studs out from the hip, at 126 studs per
		second. A foot's own peak during a swing is about 43. That is the
		snap when A or D is pressed or released against a held W: both the
		press and the release are 45 degree changes, so both jump.

		A rate makes small changes quick and large ones proportionate, which
		is what the parameter was meant to mean all along.
	]]
	local most = math.rad(cfg.TurnRate) * dt
	local yawed = here + math.clamp(diff, -most, most)
	self.moveDir = Vector3.new(-math.sin(yawed), 0, -math.cos(yawed))
	local moveDir = self.moveDir

	--[[
		Advance by distance covered, not by time.

		One foot's stance lasts as long as the body takes to travel one step
		length, which is what pins the planted foot to the ground. Driving
		the phase off a clock instead means picking a cadence, and then the
		feet skate whenever the speed disagrees with it.
	]]
	--[[
		Side-steps are shorter than forward steps, and they have to be.

		The feet are held apart ACROSS the body, so when travel turns
		sideways the stride runs along the very axis that keeps them apart.
		A step longer than twice the separation lands the trailing foot past
		the leading one, and that is the crossing -- with a 2.78 stride and
		1.2 of hip separation the trailing foot overshoots by 0.19 studs,
		every single side-step.

		Clamping a foot to its own side stops the crossing and produces
		something worse: the trailing foot reaches the limit and then simply
		stops, so the leg slides instead of stepping. Shortening the stride
		keeps BOTH feet stepping, and is what people actually do.
	]]
	--[[
		Stride grows with speed, and cadence takes what is left over.

		It was a constant at every speed, which is what splays the legs when
		you jab A and D: the direction alternates, the smoothed speed drops
		to about a third, and the feet still reach a full 2.78 studs each
		way -- so one plants hard left, the other hard right.

		Real gait splits a change of pace between stride and cadence rather
		than putting it all in one. An exponent of 0.5 divides it evenly,
		which also means neither grows as fast as speed does.
	]]
	local pace = math.clamp(self.speed / math.max(cfg.StrideSpeedRef, 0.1), 0, 2)
	local scaled = cfg.StepLength
		* math.clamp(pace ^ cfg.StrideExponent, cfg.MinStrideScale, 1.5)

	local sideways = math.abs(moveDir:Dot(frame.RightVector))
	local cap = math.max(self.separation or 0, 0.1) * cfg.SideStepRatio
	local stepLength = math.max(
		scaled * (1 - sideways) + math.min(scaled, cap) * sideways, 0.1)

	if moving then
		self.cadence = self.speed * cfg.DutyFactor / stepLength
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

	-- How far apart the feet stand, from the rig rather than from a guess.
	local left, right = self.legs.Left, self.legs.Right
	if left and right then
		self.separation = ((restPelvis * left.hip.C0).Position
			- (restPelvis * right.hip.C0).Position).Magnitude + math.abs(cfg.StanceWidth)
	end

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

	--[[
		Lean into the direction of travel, not into the facing.

		Leaning forward while walking backwards is the wrong way round, and
		while strafing it should be sideways. Rotating about the axis
		perpendicular to the movement gets all three from one expression.
	]]
	if math.abs(lean) > 1e-5 then
		local axis = -Vector3.yAxis:Cross(moveDir)
		if axis.Magnitude > 1e-3 then
			op *= Util.rotateAboutWorld(restPelvis.Position, axis.Unit, lean)
		end
	end

	local pelvisCF = op * restPelvis * CFrame.Angles(0, yaw, 0)
	rootMotor.Transform = parentCF:Inverse() * pelvisCF * rootMotor.C1

	--[[
		The frame the idle stance is pinned to.

		Feet must do two things that look contradictory: settle into a
		symmetric stance when you stop, and NOT slide about when the body
		turns underneath them. Resolving that by leaving each foot where it
		last landed satisfies the second and fails the first -- the stance
		keeps whatever asymmetry the last step happened to end on, and a
		deadzone means it stays there forever.

		So the stance is symmetric, but pinned to a frozen copy of the body
		frame. Feet sit under their hips AS OF that frame, so turning the
		camera moves nothing; once the body has moved or turned too far to
		stand in, the frame eases across and the feet shuffle with it.
	]]
	local ground = Vector3.new(pelvisCF.Position.X, floorY, pelvisCF.Position.Z)
	local bodyCF = CFrame.lookAt(ground, ground + frame.LookVector)
	self.stance = self.stance or bodyCF

	if self.blend > SETTLED then
		-- Stepping: the anchors are doing this job, so the stance just follows.
		self.stance = bodyCF
		self.shuffling = false
	else
		local off = self.stance:ToObjectSpace(bodyCF)
		local drifted = Vector3.new(off.X, 0, off.Z).Magnitude
		local turned = math.abs(math.atan2(-off.LookVector.X, -off.LookVector.Z))
		if drifted > cfg.IdleSlack or turned > math.rad(cfg.MaxFootLag) then
			self.shuffling = true
		end
		if self.shuffling then
			self.stance = self.stance:Lerp(bodyCF,
				math.clamp(dt / math.max(cfg.IdleStepTime, 1e-3), 0, 1))
			local now = self.stance:ToObjectSpace(bodyCF)
			if Vector3.new(now.X, 0, now.Z).Magnitude < 0.02
				and math.abs(math.atan2(-now.LookVector.X, -now.LookVector.Z)) < math.rad(2) then
				self.shuffling = false
			end
		end
	end

	local chestCF = self:_spine(pelvisCF, yaw)
	local duty = math.clamp(cfg.DutyFactor, 0.05, 0.95)

	for _, side in ORDER do
		local leg = self.legs[side]
		if leg then
			self:_leg(leg, SIDES[side], frame, moveDir, stepLength, pelvisCF, bodyCF, floorY, params)
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

function ProceduralWalk:_leg(leg, side, frame: CFrame, moveDir: Vector3, stepLength: number, pelvisCF: CFrame, bodyCF: CFrame, floorY: number, params: RaycastParams)
	local cfg = Config.Walk

	local hipCF = pelvisCF * leg.hip.C0
	local hipPos = hipCF.Position

	local duty = math.clamp(cfg.DutyFactor, 0.05, 0.95)
	local p = (self.phase + side.offset + leg.shift) % 1
	local swinging = p >= duty

	-- Furthest the foot may be from its hip: the shorter of a stride limit
	-- and what the leg can physically reach.
	local limit = math.min(stepLength * cfg.MaxStride,
		(leg.bone.l1 + leg.bone.l2) * cfg.MaxReach)

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

	--[[
		Out of reach while planted: STEP, do not slide.

		Dragging the anchor onto the reach circle bounds the problem and
		looks terrible -- the circle moves with the hip, so every frame
		re-clamps and the foot skates along at arm's length. Reversing a
		strafe does this continuously, which is the fast, unsmooth
		replanting.

		A person does not slide the foot; they pick it up early and put it
		down again. Jumping this leg's phase to the start of its swing is
		exactly that, and it is free: swing begins at the current anchor,
		so the foot does not move on the frame it happens. Everything after
		is the ordinary swing -- a real arc, a real landing, a real plant.

		The shift unwinds over the following strides, so the two legs come
		back into alternation on their own.
	]]
	local other = self.legs[side.other]
	if not swinging and leg.anchor and not (other and other.airborne) then
		local held = Vector3.new(leg.anchor.X - hipPos.X, 0, leg.anchor.Z - hipPos.Z)
		if held.Magnitude > limit or leg.crowded then
			leg.shift = (leg.shift + duty - p) % 1
			p, swinging = duty, true
		end
	end
	if swinging then
		leg.crowded = false
	end

	--[[
		Never lift a foot while the other one is already up.

		An early step is a convenience; having something to stand on is
		not. DutyFactor below 0.5 already designs in a float phase -- at
		0.439 that is 12% of every cycle with both feet off the ground --
		and letting early steps stack on top of it is why rapid input made
		the feet rise together.
	]]
	leg.airborne = swinging

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
		local remaining = stepLength * (1 - duty) / duty * (1 - t)
		local landing = neutral + moveDir * (remaining + stepLength * 0.5)

		--[[
			Do not land on the wrong side of the foot already down.

			Turning while walking swings the body between a plant and the
			next landing, and the target can end up across the standing
			leg. Measured against the PLANTED FOOT, not the body's midline:
			an earlier version clamped against the pelvis, which moves, so
			the constrained foot held a fixed offset from a moving body and
			slid instead of stepping. The planted foot is fixed in the
			world, so a clamp against it is fixed too.

			Only the sideways part is limited, so the step keeps its full
			reach along travel.
		]]
		if other and other.anchor and not other.airborne then
			local rel = landing - other.anchor
			local gap = rel:Dot(frame.RightVector)
			local least = side.sign * cfg.MinFootGap
			local held = (side.sign > 0) and math.max(gap, least) or math.min(gap, least)
			if math.abs(held - gap) > 1e-5 then
				landing += frame.RightVector * (held - gap)
				--[[
					Having to shove a landing sideways means the standing
					foot is in the way, not that this one aimed badly. It
					gets to step as soon as this foot is down, rather than
					waiting out a stance it is now badly placed for.
				]]
				if math.abs(held - gap) > cfg.MinFootGap then
					other.crowded = true
				end
			end
		end

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
		An anchor the hips have walked away from is pulled back to arm's
		length, hard.

		The limit is capped by what the leg can actually REACH, not just by
		a multiple of the stride: 2.2 strides came to six studs, further
		than the leg is long, so nothing was ever caught. Reversing left a
		foot pinned well behind the body with the solver clamping to hide
		it, which is a leg that has stopped moving.

		Projected onto the reach circle rather than eased toward neutral,
		so the result is bounded on the frame it happens. A planted foot
		sliding is not ideal; a planted foot the leg cannot reach is worse,
		and being dragged is what actually happens to you.
	]]
	local out = Vector3.new(place.X - hipPos.X, 0, place.Z - hipPos.Z)
	if out.Magnitude > limit and out.Magnitude > 1e-4 then
		place = Vector3.new(hipPos.X, place.Y, hipPos.Z) + out.Unit * limit
	end

	--[[
		Nothing moves a foot faster than a foot can move.

		A backstop over everything above, rather than a fix for any one
		thing. Every snap so far has been some upstream value changing
		faster than a leg could follow, and each was found only after it
		shipped; a ceiling on the output catches the next one without
		needing to know what it is.

		Scaled by speed, because what counts as too fast depends on how
		fast you are going, with a floor so it still holds at a crawl. A
		genuine swing peaks near 2.7x body speed, so the ratio sits above
		that and only bites on things no gait would ask for. Very large
		jumps pass through untouched -- those are respawns and teleports,
		and easing across the map would be worse than arriving.
	]]
	local previous = leg.last
	if previous then
		local moved = place - previous
		local ceiling = math.max(self.speed * cfg.FootSpeedRatio, cfg.MinFootSpeed)
			* (self.dt or 0)
		if moved.Magnitude > ceiling and moved.Magnitude < 10 then
			place = previous + moved.Unit * ceiling
		end
	end
	leg.last = place

	--[[
		The standing position: under this hip, but in the STANCE frame
		rather than the live one.

		Symmetric, so stopping always settles to the same pose instead of
		keeping whatever asymmetry the last step left -- and frozen, so
		turning the camera in shift lock does not drag the feet round with
		it. The stance frame catches up separately, as a shuffle.
	]]
	--[[
		Unwind an early step's phase shift, but only while the leg is in the
		air -- the swing arc absorbs a small change in t, whereas doing it
		in stance would slide a planted foot, which is the thing the early
		step existed to avoid.
	]]
	if swinging and leg.shift > 1e-4 then
		leg.shift = math.max(0, leg.shift - cfg.PhaseRecover * (self.dt or 0))
	end

	local rest = self.stance:PointToWorldSpace(bodyCF:PointToObjectSpace(neutral))

	place = rest:Lerp(place, self.blend)
	lift *= self.blend
	if self.blend <= SETTLED then
		-- Start the next stride from where the foot actually is.
		leg.anchor = rest
		leg.from = rest
	end

	local plant = place

	--[[
		A planted foot keeps the heading it landed on.

		The foot orientation used to come straight off the body's facing, so
		swinging the camera spun every foot on the spot -- including the one
		bearing weight, which is what the twisting was. A foot on the ground
		does not rotate; only a foot in the air can turn, and it turns to
		meet the heading it is about to land on.

		At low blend it eases back to facing regardless, so standing still
		and turning brings the feet round with you instead of leaving them
		splayed where the last step left them.
	]]
	--[[
		As an ANGLE off the body's facing, not a lerp between two direction
		vectors. Lerping them collapses to zero length when travel is
		opposite the facing, and before that it points the feet backwards
		when walking backwards -- which nobody does. Folding the yaw
		difference into the front half throws the reversal away and keeps
		only how far off-axis the travel is, so backwards behaves like
		forwards and a diagonal gets a real, clampable angle.
	]]
	local off = math.atan2(moveDir:Dot(frame.RightVector), moveDir:Dot(frame.LookVector))
	if off > math.pi * 0.5 then
		off -= math.pi
	elseif off < -math.pi * 0.5 then
		off += math.pi
	end
	local maxYaw = math.rad(cfg.MaxFootYaw)
	local footYaw = math.clamp(off * math.clamp(cfg.FootTurnToMove, 0, 1), -maxYaw, maxYaw)
	local wantRot = frame.Rotation * CFrame.Angles(0, -footYaw, 0)

	--[[
		Only a foot in the air turns. A planted one holds, full stop.

		Easing it round while standing was the other half of the shift-lock
		problem: looking about spun both feet on the spot. The pivot below
		is the only thing that may move a planted foot, and it only fires
		once the mismatch is too big to stand in.
	]]
	local turn = (swinging or self.shuffling)
		and (self.dt or 0) / math.max(cfg.FootTurnTime, 1e-3) or 0
	leg.footRot = leg.footRot
		and leg.footRot:Lerp(wantRot, math.clamp(turn, 0, 1))
		or wantRot

	--[[
		A planted foot may lag the body, but only so far -- and it catches
		up at a speed, not in a frame.

		Holding the landing heading through stance is right until you turn
		while walking. With AutoRotate the character faces wherever it is
		going, so adding A to a held W or S swings the body a full 45
		degrees: straight past the limit, on the first frame of the turn.
		Snapping the excess away there is what made one leg jump.

		Rate-limited, and once started it goes all the way round rather
		than stopping at the limit, because that is what a pivot on the
		ball of the foot actually does. Stopping at the limit would also
		re-trigger every frame the body kept turning, which is a snap per
		frame rather than one.
	]]
	local lag = leg.footRot.LookVector
	local lagYaw = math.atan2(lag:Dot(frame.RightVector), lag:Dot(frame.LookVector))
	if math.abs(lagYaw) > math.rad(cfg.MaxFootLag) then
		leg.pivoting = true
	end
	if leg.pivoting then
		if math.abs(lagYaw) < math.rad(3) then
			leg.pivoting = false
		else
			local rate = math.rad(cfg.PivotRate) * (self.dt or 0)
			leg.footRot *= CFrame.Angles(0, math.clamp(lagYaw, -rate, rate), 0)
		end
	end

	--[[
		Heel first going forwards, toe first going backwards, and neither
		sideways -- which is what people actually do. One dot product gets
		all three, and it passes smoothly through zero on a diagonal.
	]]
	local pitch, toeBend = footRoll(p, duty, cfg)
	local gain = cfg.FootPitchScale * self.blend * moveDir:Dot(frame.LookVector)
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
	local footAxis = leg.footRot.RightVector
	local ankleCF = CFrame.new(tipPos)
		* (tilt * leg.footRot * leg.bindAnkleRot)
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
			and Util.rotateAboutWorld(base.Position, footAxis, pitch)
			or CFrame.identity
		local transform = base:Inverse() * turn * base
		leg.heel.Transform = transform
		footCF = base * transform * leg.heel.C1:Inverse()
	end

	if leg.toe then
		local base = footCF * leg.toe.C0
		local turn = (math.abs(toeBend) > 1e-5)
			and Util.rotateAboutWorld(base.Position, footAxis, toeBend)
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
