--[[
	CharacterSetup -- forces the rig properties that keep coming back wrong.

	These are all things you can set on the StarterCharacter in Studio, and
	ideally you would. They are enforced here because they were observed
	reverting at runtime: HipHeight read 0.000 on a spawned character after
	being set to 2.7 in the model, and limb collision came back on.

	Whatever resets them does so during spawn, so setting them after
	CharacterAdded wins. Delete this script once the model holds its values.

	Why HipHeight matters so much here: with it at 0 the humanoid holds the
	bottom of the HumanoidRootPart at ground level, which puts this rig's feet
	2.7 studs underground. It also never registers a floor, so it sits in
	Freefall forever -- and foot IK deliberately switches itself off while
	airborne, so none of the IK runs at all.
]]

local Players = game:GetService("Players")

-- Distance from the ground to the BOTTOM of the HumanoidRootPart, measured
-- off this rig. Re-measure with tools/DumpRig.lua if the rig changes.
local HIP_HEIGHT = 2.7

-- Only the humanoid's own collider should collide. Everything else is a limb
-- driven by IK, and a limb in the floor drags the whole character.
local KEEP_COLLIDABLE = {
	HumanoidRootPart = true,
}

local function applyPart(part: BasePart)
	if KEEP_COLLIDABLE[part.Name] then
		return
	end
	part.CanCollide = false
	part.Massless = true
end

local function setup(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not (humanoid and humanoid:IsA("Humanoid")) then
		warn("[CharacterSetup] no Humanoid on " .. character.Name)
		return
	end

	-- R15 characters scale themselves from the player's avatar body-scale
	-- values. That is the most likely thing recomputing HipHeight out from
	-- under us, and it would distort a custom rig regardless, so it goes off.
	humanoid.AutomaticScalingEnabled = false
	humanoid.HipHeight = HIP_HEIGHT

	if not humanoid:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = humanoid
	end

	--[[
		Remove Roblox's injected Animate script.

		With RigType R15 the engine inserts the R15 variant, and this rig
		shares enough R15 joint names (LeftHip, LeftKnee, LeftAnkle,
		LeftShoulder, Waist) that the stock animations partly apply -- so the
		default idle plays on top of ours and the two fight over the same
		joints. CharacterAnimator owns playback instead.

		An empty script of the same name inside the StarterCharacter prevents
		the injection in the first place and is the tidier fix; this catches
		the case where that is missing, and re-catches it if the engine adds
		one late.
	]]
	local function dropStockAnimate(inst: Instance)
		if inst.Name == "Animate" and inst:IsA("BaseScript")
			and not inst:GetAttribute("KeepThisOne") then
			inst:Destroy()
		end
	end
	for _, d in character:GetChildren() do
		dropStockAnimate(d)
	end
	local guard = character.ChildAdded:Connect(dropStockAnimate)
	task.delay(5, function()
		guard:Disconnect()
	end)

	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then
			applyPart(d)
		end
	end

	-- Limbs and accessories can still be streaming in, and anything added
	-- later (a Tool's handle, a hat) should follow the same rule.
	character.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			applyPart(d)
		end
	end)

	print(("[CharacterSetup] %s: HipHeight=%.2f, scaling off, limbs decollided")
		:format(character.Name, humanoid.HipHeight))
end

local function watch(player: Player)
	player.CharacterAdded:Connect(setup)
	if player.Character then
		setup(player.Character)
	end
end

Players.PlayerAdded:Connect(watch)
for _, player in Players:GetPlayers() do
	watch(player)
end
