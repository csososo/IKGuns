--[[
	IKController -- drives IKSystem for EVERY character this client can see.

	StarterPlayer > StarterPlayerScripts. Survives respawns on its own.

	Why this is not a server script, which is the obvious thing to reach for
	when you want other players to see the gait: Motor6D.Transform does not
	replicate. Joints written on the server reach nobody, and making them
	reach anyone would mean streaming a CFrame per joint per frame over a
	remote, for every character, forever.

	It does not need to. The gait is a pure function of the root's position
	and velocity and the ground under it, and all three replicate already --
	so every client can compute the same walk for every character, locally,
	at no bandwidth cost at all. That is what this does.

	The phases are not synchronised between clients, so two people watching
	a third see its legs at slightly different points in the cycle. Nobody
	can tell, and the alternative costs a network message per frame.

	One consequence worth knowing: this is decoration, not truth. Nothing
	here is authoritative and nothing here should ever decide a hit. If you
	need that, it belongs on the server working from the replicated root,
	not from these joints.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IKSystem = require(ReplicatedStorage:WaitForChild("IKSystem"))

local RENDER_NAME = "IKSystemUpdate"
-- One tick before the engine's animation + IK pass, so this frame's targets
-- are the ones it solves.
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value - 1

--[[
	Past this, a character is left alone entirely.

	Each one costs a handful of raycasts a frame, and at a distance where
	the legs are a few pixels tall nobody can see which way the knee went.
]]
local CULL_DISTANCE = 250

local camera = workspace.CurrentCamera
local rigs = {}        -- [Player] = { ik, connections, character }
local generation = {}  -- [Player] = number, bumped so a slow setup can bail

local function findWeapon(character: Model): Instance?
	for _, child in character:GetChildren() do
		if child:IsA("Tool") or child:GetAttribute("IsWeapon") then
			return child
		end
	end
	return nil
end

local function teardown(player: Player)
	generation[player] = (generation[player] or 0) + 1
	local entry = rigs[player]
	if not entry then
		return
	end
	rigs[player] = nil
	for _, conn in entry.connections do
		conn:Disconnect()
	end
	entry.ik:Destroy()
end

local function setup(player: Player, character: Model)
	teardown(player)
	local mine = generation[player]

	--[[
		CharacterAdded fires as soon as the model is parented; the limbs
		stream in just after. For a REMOTE character that wait can be
		considerably longer than for your own, so the guard below matters
		more here than it did when this only ran locally.
	]]
	if not character:WaitForChild("Humanoid", 10) then
		return
	end
	for _, partName in IKSystem.Config.Parts do
		character:WaitForChild(partName, 5)
	end
	if mine ~= generation[player] or not character.Parent then
		return -- respawned, left, or streamed out while we were waiting
	end

	local ik = IKSystem.new(character)
	if not ik then
		return
	end
	ik:SetWeapon(findWeapon(character))

	rigs[player] = {
		ik = ik,
		character = character,
		connections = {
			character.ChildAdded:Connect(function(child)
				if child:IsA("Tool") or child:GetAttribute("IsWeapon") then
					ik:SetWeapon(child)
				end
			end),
			character.ChildRemoved:Connect(function(child)
				if child == ik.rig.weapon then
					ik:SetWeapon(findWeapon(character))
				end
			end),
		},
	}
end

local function watch(player: Player)
	player.CharacterAdded:Connect(function(character)
		setup(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		teardown(player)
	end)
	if player.Character then
		setup(player, player.Character)
	end
end

Players.PlayerAdded:Connect(watch)
Players.PlayerRemoving:Connect(teardown)
for _, player in Players:GetPlayers() do
	watch(player)
end

--[[
	The root, or nil if this entry has gone stale.

	PrimaryPart is the usual answer but is not guaranteed to be set on a
	custom rig, so fall back to the part by name rather than culling
	everyone on a model that simply never had it assigned.
]]
local function rootOf(entry): BasePart?
	local character = entry.character
	if not (character and character.Parent) then
		return nil
	end
	return character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
end

--[[
	The gait, for everyone. One loop rather than a binding each: the cost is
	in the solving, and a single pass makes the culling and the ordering
	obvious.

	Legs solve on Stepped, not RenderStep. RenderStep (PreRender) runs
	BEFORE the animation step in a frame, so Motor6D.Transform written there
	is overwritten by the Animator before anything is drawn -- the writes
	happen, they just never survive. Stepped (PreSimulation) runs after
	animations have been applied, so procedural joint writes stick.
]]
RunService.Stepped:Connect(function(_, dt)
	local eye = camera.CFrame.Position
	for player, entry in rigs do
		local root = rootOf(entry)
		if not root then
			teardown(player)
		elseif (root.Position - eye).Magnitude <= CULL_DISTANCE then
			entry.ik:UpdateLate(dt)
		end
	end
end)

--[[
	Aim and arms, for your character only.

	Both are driven by the camera, and there is exactly one camera. Run
	them for everyone and every remote player's torso turns to follow
	YOURS, which is worse than them not aiming at all. Doing it properly
	would mean replicating each player's look direction -- a real feature,
	but a networking one, not this.
]]
RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, function(dt)
	local entry = rigs[Players.LocalPlayer]
	if entry and rootOf(entry) then
		entry.ik:Update(dt)
	end
end)
