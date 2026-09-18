--[[
	CharacterAnimator -- plays the rig's locomotion animations.

	This exists because the rig has no usable Animate script: Roblox's stock
	one is written for R6 joint names this rig does not have, so it is
	deliberately replaced by an empty script of the same name inside the
	StarterCharacter. Nothing plays animations until something here does.

	Add IDs below as you author them. Anything left at 0 is skipped, and the
	state machine falls back to the closest thing that does exist -- so a rig
	with only an idle behaves sensibly rather than erroring.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local IDS = {
	Idle = 84259856846979,
	Walk = 116544605545946,
	Run = 0,
	Jump = 0,
	Fall = 0,
}

-- Animations that should loop rather than play once.
local LOOPING = { Idle = true, Walk = true, Run = true, Fall = true }

local FADE = 0.2        -- crossfade between states, seconds
local WALK_SPEED = 0.5  -- below this we are standing still
local RUN_SPEED = 14    -- above this, use Run if it exists

-- Speed the Walk and Run animations were authored at, used to scale playback
-- so the feet keep pace with the ground instead of skating.
--[[
	The ground speed each cycle was authored to look natural at.

	Playback is scaled by actual speed / this, so the feet keep pace with the
	floor. Defaulting Walk to the Humanoid's own WalkSpeed means it plays at
	1x normally: if the feet slide forwards the animation is too slow for the
	number here (lower it), and if the legs windmill it is too fast (raise it).
]]
local AUTHORED_SPEED = { Walk = 16, Run = 16 }

local player = Players.LocalPlayer
local active = nil

local function loadTracks(animator: Animator)
	local tracks = {}
	for name, id in IDS do
		if id and id ~= 0 then
			local animation = Instance.new("Animation")
			animation.Name = name
			animation.AnimationId = "rbxassetid://" .. id

			local ok, track = pcall(function()
				return animator:LoadAnimation(animation)
			end)
			if ok and track then
				track.Name = name
				track.Priority = Enum.AnimationPriority.Core
				track.Looped = LOOPING[name] == true
				tracks[name] = track
			else
				warn(("[CharacterAnimator] could not load %s (%s): %s")
					:format(name, tostring(id), tostring(track)))
			end
		end
	end
	return tracks
end

-- First of `names` that actually loaded. Lets a rig with only an idle work.
local function firstAvailable(tracks, ...)
	for _, name in { ... } do
		if tracks[name] then
			return name
		end
	end
	return nil
end

local function chooseState(humanoid: Humanoid, speed: number, tracks): string?
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Jumping then
		return firstAvailable(tracks, "Jump", "Fall", "Idle")
	end
	if state == Enum.HumanoidStateType.Freefall then
		return firstAvailable(tracks, "Fall", "Jump", "Idle")
	end
	if speed > RUN_SPEED then
		return firstAvailable(tracks, "Run", "Walk", "Idle")
	end
	if speed > WALK_SPEED then
		return firstAvailable(tracks, "Walk", "Run", "Idle")
	end
	return firstAvailable(tracks, "Idle")
end

local function setup(character: Model)
	if active then
		for _, track in active.tracks do
			track:Stop(0)
		end
		RunService:UnbindFromRenderStep("CharacterAnimator")
		active = nil
	end

	local humanoid = character:WaitForChild("Humanoid", 10)
	if not (humanoid and humanoid:IsA("Humanoid")) then
		return
	end
	local animator = humanoid:WaitForChild("Animator", 5)
	if not (animator and animator:IsA("Animator")) then
		warn("[CharacterAnimator] no Animator on the Humanoid; nothing can play.")
		return
	end

	-- Anything already playing is not ours: stock tracks started before we got
	-- here would blend with, and fight, the animations below.
	for _, track in animator:GetPlayingAnimationTracks() do
		track:Stop(0)
	end

	local tracks = loadTracks(animator)
	if not next(tracks) then
		warn("[CharacterAnimator] no animations loaded; add IDs at the top of this script.")
		return
	end

	local loaded = {}
	for name in tracks do
		table.insert(loaded, name)
	end
	table.sort(loaded)
	print("[CharacterAnimator] loaded: " .. table.concat(loaded, ", "))

	active = { tracks = tracks, current = nil }

	local root = character:FindFirstChild("HumanoidRootPart")
	RunService:BindToRenderStep("CharacterAnimator", Enum.RenderPriority.Character.Value - 2, function()
		if not (active and root and root.Parent) then
			return
		end

		local velocity = root.AssemblyLinearVelocity
		local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		local wanted = chooseState(humanoid, speed, active.tracks)

		if wanted and wanted ~= active.current then
			if active.current and active.tracks[active.current] then
				active.tracks[active.current]:Stop(FADE)
			end
			active.tracks[wanted]:Play(FADE)
			active.current = wanted
		end

		-- Keep a moving animation in step with the actual ground speed.
		local authored = active.current and AUTHORED_SPEED[active.current]
		if authored and authored > 0 then
			active.tracks[active.current]:AdjustSpeed(math.clamp(speed / authored, 0.3, 2))
		end
	end)
end

player.CharacterAdded:Connect(setup)
if player.Character then
	setup(player.Character)
end
