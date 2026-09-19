--[[
	Config -- every name and number the IK system touches.

	These values are set for the "Wumig" rig, whose topology is:

	    HumanoidRootPart -RootJoint-> MainMover -MainMoverJoint-> Hip
	    Hip        -HipSpine->  LowerTorso -Waist->  Thorax
	    Thorax     -NeckBase->  Neck       -HeadJoint-> Head
	    Thorax     -LeftShoulder-> LeftUpperArm -LeftElbow-> LeftLowerArm -LeftWrist-> LeftHand
	    Hip        -LeftHip->   LeftUpperLeg -LeftKnee-> LeftLowerLeg -LeftAnkle->
	                            LeftAnkle -LeftHeelBase-> LeftHeel -LeftForefoot-> LeftForefoot

	If you retarget to a different rig, run tools/DumpRig.lua against it and
	correct the names below. Nothing outside this file should need to change.
]]

local Config = {}

--[[
	Bisect switch. Run exactly one subsystem at a time to find which one
	misbehaves, without touching anything else.

		"all"   -- normal operation
		"none"  -- build nothing, write nothing. Equivalent to the controller
		           being disabled, but with the script still running.
		"legs"  -- procedural legs only
		"aim"   -- torso twist and head look only
		"arms"  -- hand IK only

	Set back to "all" when you are done.
]]
Config.Only = "all"

function Config.isOn(name: string): boolean
	return Config.Only == "all" or Config.Only == name
end

--[[
	Parts, by the ROLE the system needs rather than the rig's own naming.
	Left side is the role, right side is what this rig calls it.
]]
Config.Parts = {
	Root = "HumanoidRootPart", -- physics root; hip height is offset relative to this
	LegRoot = "Hip",           -- the part both legs hang off
	Spine = "LowerTorso",
	Chest = "Thorax",          -- the part both arms and the neck hang off
	Head = "Head",

	-- The foot chains end at the main foot block, not the thin ankle plate and
	-- not the toe. The toe (LeftForefoot / RightForefoot) stays animated.
	LeftFoot = "LeftHeel",
	RightFoot = "RightHeel",

	LeftHand = "LeftHand",
	RightHand = "RightHand",

	-- Chain roots: the FIRST MOVING SEGMENT of each limb, not the body part
	-- it hangs off. See Config.Chains.
	LeftUpperLeg = "LeftUpperLeg",
	RightUpperLeg = "RightUpperLeg",
	LeftUpperArm = "LeftUpperArm",
	RightUpperArm = "RightUpperArm",
	Neck = "Neck",
}

--[[
	Where each IK chain starts, as a suffix into Config.Parts -- "%sUpperLeg"
	resolves to LeftUpperLeg and RightUpperLeg.

	These are the first moving segment of the limb, NOT the body part it hangs
	off. Rooting a leg chain at the pelvis instead lets the solver rotate the
	pelvis to help reach the target, and the pelvis carries the entire upper
	body: the torso tips, and with both legs pulling on the same joint they
	fight each other.
]]
Config.Chains = {
	Leg = "%sUpperLeg",
	Arm = "%sUpperArm",
	Head = "Neck",
}

Config.Joints = {
	--[[
		Hip height rides on this joint.

		MainMover is a leftover from when this rig was used for animating. It
		is not a collider and should have CanCollide off -- holding the
		character at the right height is Humanoid.HipHeight's job. Keep the
		part, though: it sits in the chain as
		HumanoidRootPart -> MainMover -> Hip, so deleting it means re-jointing
		the root, and an inert pass-through node costs nothing.

		The offset goes on MainMoverJoint (MainMover -> Hip) rather than
		RootJoint so it moves the body and not the whole assembly below the
		root. It is applied in world space, so this joint's Part0 does not have
		to be upright for it to work. If you ever do delete MainMover, point
		this at whatever joint replaces it -- a missing joint here just
		disables the hip drop rather than erroring.
	]]
	Root = "MainMoverJoint",
}

Config.Aim = {
	Enabled = true,

	--[[
		Aim rotation is spread across the spine instead of snapping one joint.
		Weights are fractions of the total and should add up to 1. Putting some
		of it low in the spine reads as the whole torso turning rather than the
		chest shearing off the hips.
	]]
	SpineJoints = {
		{ Name = "HipSpine", Weight = 0.35 }, -- Hip -> LowerTorso
		{ Name = "Waist", Weight = 0.65 },    -- LowerTorso -> Thorax
	},

	MaxPitch = math.rad(55),   -- how far the torso tips up/down in total
	MaxYaw = math.rad(45),     -- how far it twists before the legs have to turn
	Responsiveness = 0.08,     -- seconds to catch up. lower = snappier
	HeadWeight = 1,            -- 0 disables the head look entirely
	AimDistance = 500,         -- how far out the look target is placed
	-- Off: holding aim should not drag the whole body round to face the
	-- camera. The chest still tracks it via the spine.
	TurnWithCameraWhenAiming = false,

	--[[
		LookAt aims one specific axis of the end effector at the target, and
		which axis reads as "forward" depends on how the head was modelled.
		This rig's head decal is on the Front face, which is -Z and is what
		LookAt expects, so identity is correct here. If you swap the head out
		and it faces wrong, rotate this: CFrame.Angles(0, math.pi, 0) for
		backwards, CFrame.Angles(0, math.rad(90), 0) for sideways.
	]]
	HeadLookAxis = CFrame.identity,
}



--[[
	Analytic two-bone leg IK with a built-in gait, replacing the IKControl
	legs, replacing the IKControl foot chains entirely.

	PlantSlack and LiftThreshold are the only tuned values, and both describe
	the ANIMATION rather than the rig: how far it lifts a swinging foot above
	the one carrying the weight.
]]
--[[
	Foot IK layered on an authored animation. The animation owns the stride,
	the timing and the lift; this only meets the ground.
]]
Config.FootIK = {
	Enabled = true,
	HipJoint = "%sHip",
	KneeJoint = "%sKnee",
	AnkleJoint = "%sAnkle",

	MaxStepUp = 1.2,   -- clamps, so a foot never snaps somewhere absurd
	MaxStepDown = 1.5,

	--[[
		Slack before a foot counts as lifting at all, in studs above the other
		foot. Only has to absorb the wobble of an animation that never puts
		both feet at exactly the same height, so it is small: the datum is the
		other foot, measured live, not a standing height guessed in advance.
	]]
	PlantSlack = 0.1,

	--[[
		How far the animation has to lift a foot before it counts as swinging
		rather than planted, in studs above the foot taking the weight.

		A swinging foot must not be corrected and must not influence the hips:
		it is deliberately in the air, so pulling it down to the ground fights
		the animation, and letting it drag the hips sinks the whole body --
		including the leg that IS planted.
	]]
	LiftThreshold = 0.25,

	--[[
		Corrections smaller than this are skipped entirely and the animation
		is left completely alone. Without it, flat ground still re-solves the
		leg onto the position it already occupies every frame.
	]]
	DeadZone = 0.06,

	--[[
		Height difference, past the dead zone, at which the correction reaches
		full strength.

		Sized for a real step rather than for noise. This used to be the dead
		zone itself, which meant full strength at about a tenth of a stud --
		inside the Humanoid's own vertical wobble, so the IK chased that
		wobble at near-full weight on flat ground.
	]]
	RampWidth = 0.25,

	HipInfluence = 1,  -- 0 = never move the hips to help a foot reach

	--[[
		Roll the pelvis so each hip sits at its own height.

		Dropping the hips by the worst of the two legs drags the leg that
		needed nothing down with it. Tilting instead means one foot can go
		lower while the other stays put -- which is what hips actually do.
	]]
	HipRoll = true,
	MaxHipRoll = math.rad(12),
	HipWidth = 1.2, -- distance between the hip joints, sets how much a given
	                -- height difference tilts the pelvis

	--[[
		Counter-rotate the spine against the pelvis roll.

		The torso hangs off the pelvis, so tilting the hips tips the chest and
		head with them. A real spine absorbs most of that -- the pelvis tilts
		while the shoulders stay near level. 1 would hold the chest perfectly
		level, which reads as stiff; a bit less leaves some of the tilt
		showing, which is what a body actually does.
	]]
	CounterRotate = true,
	CounterFraction = 0.75,

	--[[
		Let the foot roll onto its toe when the leg cannot quite reach, rather
		than over-extending and snapping straight. Uses the HeelBase joint, so
		it needs a rig with a separate heel and forefoot.

		If the heel digs DOWN instead of lifting, flip RollSign.
	]]
	--[[
		Off until the roll direction is confirmed on this rig. It engages
		exactly when a leg over-extends -- which is when crossing a step -- so
		a wrong RollSign shows up as a kick at the worst moment. Turn it on
		deliberately and watch one step-down.
	]]
	FootRoll = false,
	HeelJoint = "%sHeelBase",
	ToeJoint = "%sForefoot",
	MaxFootRoll = math.rad(40),
	RollSign = -1,
	SmoothTime = 0.1,  -- seconds for the correction itself to catch up
	BlendTime = 0.12,  -- and for it to fade in or out

	AlignFeetToGround = true,
	MaxSlopeAngle = math.rad(50),

	RayUp = 2,
	RayDown = 4,

	--[[
		Sample the ground at several points under the foot and take the
		highest, rather than firing one ray at its centre.

		One ray is discontinuous at a step edge: it flips between the top and
		the floor as the foot crosses, and flickers if the foot sits near the
		lip. Several samples make the crossing gradual -- the leading corner
		finds the step first -- which is also closer to how a real foot meets
		an edge.
	]]
	SampleRadius = 0.3,

	--[[
		Cap on how fast the correction may change, in studs per second. A
		backstop for surfaces that change faster than smoothing can absorb.
	]]
	MaxCorrectionRate = 6,

	--[[
		One-frame change in what reaches the rig that counts as a jump, in
		studs. Crossing it switches the debug log to every frame for a dozen
		frames, marked with a "!".

		About a stud and a half per second at 60fps: well under anything you
		would call a twitch, and well over the noise.
	]]
	SpikeLog = 0.02,

	-- Cap on how fast the pelvis may move, studs and radians per second.
	MaxHipRate = 3,
	MaxRollRate = math.rad(60),
}


Config.Arms = {
	-- Arm IK, for pinning hands to weapon grips. Off until you have a weapon.
	Enabled = false,
	-- Attachment names looked for inside the equipped weapon model. This rig
	-- has no grip attachments yet; you add them to the weapon, not the hands.
	LeftGripAttachment = "LeftGrip",
	RightGripAttachment = "RightGrip",
	-- Which way elbows point, along the root's local Z. Opposite the knees.
	PoleBack = 1,
	-- Usually false: the animation holds the gun in the right hand and IK only
	-- places the support hand. Turn on if you want both hands pinned.
	DriveRightHand = false,
	SmoothTime = 0.03,
}


--[[
	Reset a limb's joints to bind pose whenever its IK is not driving them.

	Needed ONLY because this rig has no animations yet: with nothing writing
	Motor6D.Transform, a limb freezes wherever IK left it instead of returning
	to rest. Set this to false the moment you have real animations playing --
	the Animator owns Transform then, and this would fight it every frame.
]]
Config.RelaxIdleChains = false

-- Writes per-frame IK state to attributes on the character so
-- tools/DiagnoseMovement.lua can read it. Free to leave off.
Config.Debug = true

return Config
