--[[
	ViewTool -- watch your own character from any angle while it walks.

	Press P.

	This exists because the gait is client-local: nothing about it
	replicates, so Studio's Server view and a second test client both show
	the rig standing perfectly still. The only place the walk exists is your
	own client, which means the camera has to come to you.

	The awkward part is that Roblox movement is camera-relative, so the
	moment you point the camera at your own face, W walks towards it and you
	cannot hold a direction and study it. So this takes the controls over and
	drives the Humanoid in WORLD axes instead: W is always the same compass
	direction whatever the camera is doing. Orbit freely, walk in a straight
	line, watch the legs.

		P              toggle
		WASD           walk, in world axes, independent of the camera
		Space          jump
		right-drag     orbit
		wheel          zoom
		C              swing round to face the character head on
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ORBIT_SPEED = 0.006   -- radians per pixel of drag
local ZOOM_SPEED = 2        -- studs per wheel click
local MIN_DIST, MAX_DIST = 4, 60
local MIN_PITCH, MAX_PITCH = math.rad(-75), math.rad(75)

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local active = false
local yaw, pitch, distance = 0, math.rad(-10), 16
local dragging = false

local KEYS = {
	[Enum.KeyCode.W] = Vector3.new(0, 0, -1),
	[Enum.KeyCode.S] = Vector3.new(0, 0, 1),
	[Enum.KeyCode.A] = Vector3.new(-1, 0, 0),
	[Enum.KeyCode.D] = Vector3.new(1, 0, 0),
}

local function humanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function subject(): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

--[[
	Roblox's own control module is what makes movement camera-relative, so
	it has to be switched off rather than fought. Re-enabled on the way out,
	otherwise the character is left unable to move at all.
]]
local function setControls(enabled: boolean)
	local scripts = player:FindFirstChild("PlayerScripts")
	local module = scripts and scripts:FindFirstChild("PlayerModule")
	if not module then
		return
	end
	local ok, controls = pcall(function()
		return require(module):GetControls()
	end)
	if ok and controls then
		if enabled then
			controls:Enable()
		else
			controls:Disable()
		end
	end
end

-- Put the camera in front of the character, looking back at it.
local function faceCharacter()
	local root = subject()
	if not root then
		return
	end
	local look = root.CFrame.LookVector
	yaw = math.atan2(-look.X, -look.Z) + math.pi
end

local function update()
	local root = subject()
	if not root then
		return
	end

	local focus = root.Position + Vector3.new(0, 1, 0)
	local offset = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	camera.CFrame = CFrame.lookAt(focus + offset * Vector3.new(0, 0, distance), focus)

	--[[
		Driven in world axes: Humanoid:Move's second argument is "relative
		to the camera", and false is the whole point of this tool.
	]]
	local move = Vector3.zero
	for key, direction in KEYS do
		if UserInputService:IsKeyDown(key) then
			move += direction
		end
	end
	local human = humanoid()
	if human then
		human:Move(move.Magnitude > 0 and move.Unit or Vector3.zero, false)
	end
end

local function setActive(on: boolean)
	if on == active then
		return
	end
	active = on

	if active then
		faceCharacter()
		setControls(false)
		camera.CameraType = Enum.CameraType.Scriptable
		RunService:BindToRenderStep("ViewTool", Enum.RenderPriority.Camera.Value, update)
		print("[ViewTool] on -- WASD is world-relative, right-drag to orbit, C to face.")
	else
		RunService:UnbindFromRenderStep("ViewTool")
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid()
		setControls(true)
		local human = humanoid()
		if human then
			human:Move(Vector3.zero, false)
		end
		print("[ViewTool] off")
	end
end

UserInputService.InputBegan:Connect(function(input, typing)
	if typing then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		dragging = active
	elseif input.KeyCode == Enum.KeyCode.Space and active then
		local human = humanoid()
		if human then
			human.Jump = true
		end
	elseif input.KeyCode == Enum.KeyCode.C and active then
		faceCharacter()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		dragging = false
	end
end)

UserInputService.InputChanged:Connect(function(input, typing)
	if typing or not active then
		return
	end
	if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		yaw -= input.Delta.X * ORBIT_SPEED
		pitch = math.clamp(pitch - input.Delta.Y * ORBIT_SPEED, MIN_PITCH, MAX_PITCH)
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		distance = math.clamp(distance - input.Position.Z * ZOOM_SPEED, MIN_DIST, MAX_DIST)
	end
end)

-- Respawning replaces the Humanoid, so hand the camera back and re-arm.
player.CharacterAdded:Connect(function()
	if active then
		task.defer(function()
			setControls(false)
			faceCharacter()
		end)
	end
end)

ContextActionService:BindAction("ToggleViewTool", function(_, state)
	if state == Enum.UserInputState.Begin then
		setActive(not active)
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.P)

print("[ViewTool] press P to watch your character from any angle.")
