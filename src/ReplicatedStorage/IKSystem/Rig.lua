--[[
	Rig -- resolves a character model into the parts, joints, targets and
	IKControls that the other modules drive.

	Anything it cannot find is reported once and the feature that needed it is
	switched off, so a rig that only half matches the config still runs.
]]

local Config = require(script.Parent.Config)

local Rig = {}
Rig.__index = Rig

-- IKControl targets have to be Attachments, and Attachments need a BasePart
-- parent. Terrain sits at the origin and never moves, so world space and its
-- local space are the same thing.
local TARGET_HOST = workspace.Terrain

local function findPart(character: Instance, name: string): BasePart?
	local inst = character:FindFirstChild(name)
	return (inst and inst:IsA("BasePart")) and inst or nil
end

local function findMotor(character: Instance, name: string): Motor6D?
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") and d.Name == name then
			return d
		end
	end
	return nil
end

--[[
	Walk up the Motor6D chain from `endPart` to `rootPart`, collecting the
	joints in between. These are exactly the joints an IKControl over that
	chain will drive, which is what lets us hand them back when it stops.
]]
local function collectChain(character: Instance, endPart: BasePart, rootPart: BasePart): { Motor6D }
	local byPart1 = {}
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 then
			byPart1[d.Part1] = d
		end
	end

	local motors = {}
	local current: BasePart? = endPart
	for _ = 1, 32 do -- guard against a cycle in a malformed rig
		if not current or current == rootPart then
			break
		end
		local motor = byPart1[current]
		if not motor then
			break
		end
		table.insert(motors, motor)
		current = motor.Part0
	end
	return motors
end

local function makeAttachment(parent: BasePart, name: string, cf: CFrame): Attachment
	local a = Instance.new("Attachment")
	a.Name = name
	a.CFrame = cf
	a.Parent = parent
	return a
end

function Rig.new(character: Model)
	local animator = character:FindFirstChildOfClass("Humanoid")
		or character:FindFirstChildOfClass("AnimationController")
	if not animator then
		warn("[IKSystem] " .. character.Name .. " has no Humanoid or AnimationController; IK cannot run.")
		return nil
	end

	local self = setmetatable({}, Rig)
	self.character = character
	self.humanoid = character:FindFirstChildOfClass("Humanoid")
	self.animator = animator
	self.parts = {}
	self.motors = {}
	self.baseC0 = {}
	self.controls = {}
	self.attachments = {}
	self.chains = {}
	self.instances = {}
	self.features = { aim = false, head = false, feet = false, arms = false }

	-- IKControl is solved inside the animation pipeline, which needs an
	-- Animator to exist. Rigs built by hand often do not have one.
	if self.humanoid and not self.humanoid:FindFirstChildOfClass("Animator") then
		warn("[IKSystem] " .. character.Name .. " has no Animator. Creating one so IK can solve, "
			.. "but add a real Animator to the rig on the server so it replicates.")
		local animator = Instance.new("Animator")
		animator.Parent = self.humanoid
	end

	local missing = {}
	for key, name in Config.Parts do
		local part = findPart(character, name)
		self.parts[key] = part
		if not part then
			table.insert(missing, "part " .. name)
		end
	end
	for key, name in Config.Joints do
		local motor = findMotor(character, name)
		self.motors[key] = motor
		if motor then
			self.baseC0[key] = motor.C0
		else
			table.insert(missing, "Motor6D " .. name)
		end
	end

	-- Spine joints are a weighted list rather than a single waist, so the aim
	-- rotation can be spread down the torso.
	self.spine = {}
	for _, entry in Config.Aim.SpineJoints do
		local motor = findMotor(character, entry.Name)
		if motor then
			table.insert(self.spine, { motor = motor, baseC0 = motor.C0, weight = entry.Weight })
		else
			table.insert(missing, "Motor6D " .. entry.Name)
		end
	end
	if #missing > 0 then
		warn(("[IKSystem] %s is missing: %s. Fix the names in IKSystem.Config, or run IKSystem.Dump(character) to see what the rig actually has."):format(
			character.Name, table.concat(missing, ", ")))
	end

	self:_reportCollidableLimbs()
	self:_buildArms()
	self:_buildHeadLook()
	self:_buildAim()

	return self
end

--[[
	IK moves real, collidable parts. A limb pushed into the floor by foot
	planting or a hip drop will grind against it, and the character walks like
	it is wading through treacle. On a normal Roblox rig the engine keeps limb
	collision out of the way; on a hand-built one it is usually left on by
	accident.

	This only reports. Which parts should collide is a decision about the rig,
	not something the IK layer should quietly change underneath you.
]]
function Rig:_reportCollidableLimbs()
	local collidable = {}
	for _, d in self.character:GetChildren() do
		if d:IsA("BasePart") and d.CanCollide and d ~= self.parts.Root then
			table.insert(collidable, d.Name)
		end
	end
	if #collidable > 0 then
		warn(("[IKSystem] %d parts besides the root can collide: %s. If walking feels heavy "
			.. "or snagged, these are why -- IK drives them through the floor. Usually only "
			.. "the HumanoidRootPart and a dedicated floor collider should have CanCollide on."
			):format(#collidable, table.concat(collidable, ", ")))
	end
end

-- Upright frame at the root facing where the character faces. Pitch and roll
-- are dropped so a settling or tilting root cannot skew the reference pose.
function Rig:_yawFrame(): CFrame?
	local root = self.parts.Root
	if not root then
		return nil
	end
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-4 then
		return CFrame.new(root.Position)
	end
	return CFrame.lookAt(root.Position, root.Position + flat.Unit)
end

--[[
	Work out where a limb sits relative to the root in the rig's BIND pose,
	from the joints rather than from the world.

	A Motor6D solves part1 = part0 * C0 * Transform * C1:Inverse(). Ignoring
	Transform -- which is the animation/IK layer -- and walking the chain from
	the root down gives the pose the rig was built in.

	Reading live part positions instead, as an earlier version did, samples
	whatever attitude the character happens to be in at that instant. Spawn
	mid-fall or catch it still settling and that tilt gets baked in as
	"standing", which then shows up as a permanently skewed reference pose.
	Deriving it from C0/C1 cannot go wrong that way: there is no timing to get
	right, because no world state is involved.
]]
function Rig:_bindOffset(endPart: BasePart): CFrame?
	local root = self.parts.Root
	if not root then
		return nil
	end
	local motors = collectChain(self.character, endPart, root)
	if #motors == 0 then
		return nil
	end
	-- collectChain walks upward, so apply it in reverse: root outward.
	local cf = CFrame.identity
	for i = #motors, 1, -1 do
		cf = cf * motors[i].C0 * motors[i].C1:Inverse()
	end
	return cf
end

-- Public accessors for modules that solve joints themselves.
function Rig:FindMotor(name: string): Motor6D?
	return findMotor(self.character, name)
end

function Rig:GetBindOffset(part: BasePart): CFrame?
	return self:_bindOffset(part)
end

function Rig:GetYawFrame(): CFrame?
	return self:_yawFrame()
end

function Rig:_track(inst: Instance): Instance
	table.insert(self.instances, inst)
	return inst
end

function Rig:_createControl(name: string, controlType: Enum.IKControlType, chainRoot: BasePart, endEffector: Instance, target: Instance, pole: Instance?, smoothTime: number?)
	local control = Instance.new("IKControl")
	control.Name = name
	control.Type = controlType
	control.ChainRoot = chainRoot
	control.EndEffector = endEffector
	control.Target = target
	if pole then
		control.Pole = pole
	end
	control.SmoothTime = smoothTime or 0
	control.Weight = 0 -- everything fades in from nothing
	control.Enabled = true
	control.Parent = self.animator

	self.controls[name] = control
	self:_track(control)
	return control
end


--[[
	Arms: chains rooted at the UpperTorso so shoulder, elbow and wrist move.
	Targets stay nil until a weapon is equipped; weight stays 0 until then.
	Elbow poles sit behind the body so elbows bend the right way.
]]
function Rig:_buildArms()
	if not (Config.Arms.Enabled and Config.isOn("arms")) then return end
	-- Only used to size the pole offsets; the chain roots are per-arm below.
	local chest = self.parts.Chest
	if not chest then return end

	local poleHost = self.parts.Root or chest
	local halfWidth = chest.Size.X * 0.5
	local elbowTrail = math.max(3, chest.Size.Z * 3)

	for side, hand in { Left = self.parts.LeftHand, Right = self.parts.RightHand } do
		local chainRoot = self.parts[Config.Chains.Arm:format(side)]
		if hand and chainRoot then
			local sign = side == "Left" and -1 or 1
			local pole = self:_track(makeAttachment(poleHost, "IK" .. side .. "ElbowPole",
				CFrame.new(sign * (halfWidth + 1), -0.5, Config.Arms.PoleBack * elbowTrail)))
			local target = self:_track(makeAttachment(TARGET_HOST,
				("IK_%s_%sHand"):format(self.character.Name, side), hand.CFrame))

			self.attachments[side .. "Hand"] = target
			self.chains[side .. "Hand"] = collectChain(self.character, hand, chainRoot)
			self:_createControl(side .. "ArmIK", Enum.IKControlType.Transform,
				chainRoot, hand, target, pole, Config.Arms.SmoothTime)
		end
	end

	self.features.arms = true
end

--[[
	Head: a LookAt chain from the UpperTorso to the Head, so only the Neck
	turns.

	The end effector is an Attachment on the head rather than the head part
	itself. LookAt aims one particular axis of the end effector at the target,
	and which axis that is depends on how the head was built -- going through
	an attachment means a wrong-facing head is one CFrame in Config to fix
	instead of a re-modelled head.
]]
function Rig:_buildHeadLook()
	if not (Config.Aim.Enabled and Config.isOn("aim")) or Config.Aim.HeadWeight <= 0 then return end
	local headRoot, head = self.parts[Config.Chains.Head], self.parts.Head
	if not (headRoot and head) then return end

	local eye = self:_track(makeAttachment(head, "IKHeadLook", Config.Aim.HeadLookAxis))
	local target = self:_track(makeAttachment(TARGET_HOST,
		("IK_%s_Look"):format(self.character.Name), head.CFrame * CFrame.new(0, 0, -50)))
	self.attachments.Look = target

	self:_createControl("HeadLookIK", Enum.IKControlType.LookAt, headRoot, eye, target, nil, 0.05)
	self.features.head = true
end

function Rig:_buildAim()
	self.features.aim = Config.Aim.Enabled and Config.isOn("aim")
		and #self.spine > 0 and self.parts.Root ~= nil
end

--[[
	Point the arm IK at a weapon's grip attachments. Pass nil to release the
	arms back to the animation.
]]
function Rig:SetWeapon(weapon: Instance?)
	self.weapon = weapon
	self.grips = {}
	if not weapon then return end

	for side, attName in {
		Left = Config.Arms.LeftGripAttachment,
		Right = Config.Arms.RightGripAttachment,
	} do
		local grip = weapon:FindFirstChild(attName, true)
		if grip and grip:IsA("Attachment") then
			self.grips[side] = grip
		end
	end
end

--[[
	Return a chain to its bind pose.

	Only safe while nothing else drives these joints. With no animations
	playing, an IKControl that drops to weight 0 simply stops writing
	Transform and the limb stays frozen at the last solved pose -- there is no
	animation track underneath to restore it. Once real animations exist the
	Animator owns Transform every frame and this must be turned off, or it
	will fight the animation.
]]
function Rig:RelaxChain(key: string)
	if not Config.RelaxIdleChains then
		return
	end
	local motors = self.chains[key]
	if not motors then
		return
	end
	for _, motor in motors do
		motor.Transform = CFrame.identity
	end
end

function Rig:Destroy()
	for key, motor in self.motors do
		if motor and motor.Parent and self.baseC0[key] then
			motor.C0 = self.baseC0[key]
		end
	end
	for _, joint in self.spine do
		if joint.motor.Parent then
			joint.motor.C0 = joint.baseC0
		end
	end
	table.clear(self.spine)
	for _, inst in self.instances do
		if inst.Parent then
			inst:Destroy()
		end
	end
	table.clear(self.instances)
	table.clear(self.controls)
	table.clear(self.attachments)
end

return Rig
