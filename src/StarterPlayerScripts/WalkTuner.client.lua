--[[
	WalkTuner -- live sliders for the procedural gait. Press ']' to show it.

	Config is a ModuleScript, so both this and ProceduralWalk hold the SAME
	table on the client: writing a value here changes the gait on the next
	frame, with no plumbing in between and nothing to keep in sync.

	Nothing here is saved. When a gait looks right, press Copy and paste the
	block it prints over Config.Walk, because the next play session starts
	from the file again.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("IKSystem").Config)

local WIDTH = 300
local ROW = 28
local PAD = 8

local BG = Color3.fromRGB(24, 24, 28)
local PANEL = Color3.fromRGB(34, 34, 40)
local TRACK = Color3.fromRGB(52, 52, 60)
local FILL = Color3.fromRGB(96, 168, 255)
local TEXT = Color3.fromRGB(226, 226, 232)
local DIM = Color3.fromRGB(150, 150, 160)

--[[
	Order matters: these are grouped the way you tune them, not the way the
	table happens to be written. Shape of the step first, then how the body
	rides on top of it, then the response.
]]
local GROUPS = {
	{ "Step", { "StepLength", "StepHeight", "DutyFactor", "StanceWidth", "FootAhead", "AnkleHeight", "MaxStride" } },
	{ "Foot roll", { "HeelStrikeAngle", "FlatAt", "HeelRiseAt", "ToeOffAngle", "ToeBend", "FootPitchScale" } },
	{ "Body", { "BobHeight", "BobPhase", "SwayWidth", "SwayPhase", "LeanAngle" } },
	{ "Pelvis", { "BodyYaw", "PelvisList", "PelvisListPhase", "ChestCounter" } },
	{ "Arms", { "ArmSwing", "ElbowBend", "ElbowSwing" } },
	{ "Response", { "MinSpeed", "BlendTime", "SpeedSmooth", "LeanSpeed" } },
}

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "WalkTuner"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 50
gui.Enabled = Config.Gait == "procedural"
gui.Parent = player:WaitForChild("PlayerGui")

local root = Instance.new("Frame")
root.Size = UDim2.new(0, WIDTH, 0.7, 0)
root.Position = UDim2.new(1, -(WIDTH + 16), 0, 60)
root.BackgroundColor3 = BG
root.BorderSizePixel = 0
root.Active = true
root.Draggable = true
root.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 6)
corner.Parent = root

--[[
	The sliders scroll, because there are more of them than fit on a screen
	and a panel that runs off the bottom edge silently loses its last group.
	Dragging the header still moves the whole thing.
]]
local header = Instance.new("TextLabel")
header.Size = UDim2.new(1, -PAD * 2, 0, 22)
header.Position = UDim2.fromOffset(PAD, PAD)
header.BackgroundTransparency = 1
header.Font = Enum.Font.Code
header.TextSize = 13
header.TextColor3 = TEXT
header.TextXAlignment = Enum.TextXAlignment.Left
header.Text = "WALK TUNER    ]  hide"
header.Parent = root

local body = Instance.new("ScrollingFrame")
body.Size = UDim2.new(1, 0, 1, -(22 + PAD * 2))
body.Position = UDim2.fromOffset(0, 22 + PAD)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 4
body.ScrollBarImageColor3 = TRACK
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.CanvasSize = UDim2.new()
body.Parent = root

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 2)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body

local pad = Instance.new("UIPadding")
pad.PaddingBottom = UDim.new(0, PAD)
pad.PaddingLeft = UDim.new(0, PAD)
pad.PaddingRight = UDim.new(0, PAD + 4)
pad.Parent = body

local order = 0
local function nextOrder(): number
	order += 1
	return order
end

local function label(text: string, size: number, colour: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, 0, 0, ROW - 6)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.Code
	l.TextSize = size
	l.TextColor3 = colour
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text
	l.LayoutOrder = nextOrder()
	l.Parent = body
	return l
end

--[[
	One slider per value.

	The readout is a TextBox, so anything the slider's range cannot reach --
	or any number you already know you want -- can just be typed in.
]]
local function slider(key: string, min: number, max: number)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, ROW)
	row.BackgroundTransparency = 1
	row.LayoutOrder = nextOrder()
	row.Parent = body

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(0, 104, 1, 0)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.Code
	name.TextSize = 12
	name.TextColor3 = DIM
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Text = key
	name.Parent = row

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, -164, 0, 6)
	track.Position = UDim2.new(0, 104, 0.5, -3)
	track.BackgroundColor3 = TRACK
	track.BorderSizePixel = 0
	track.Active = true
	track.Parent = row

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = FILL
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0, 54, 1, 0)
	box.Position = UDim2.new(1, -54, 0, 0)
	box.BackgroundColor3 = PANEL
	box.BorderSizePixel = 0
	box.Font = Enum.Font.Code
	box.TextSize = 12
	box.TextColor3 = TEXT
	box.ClearTextOnFocus = false
	box.Parent = row

	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, 4)
	boxCorner.Parent = box

	local function show(value: number)
		fill.Size = UDim2.fromScale(math.clamp((value - min) / (max - min), 0, 1), 1)
		box.Text = string.format("%.3f", value)
	end

	local function set(value: number)
		Config.Walk[key] = value
		show(value)
	end

	local function fromX(x: number)
		local a = track.AbsolutePosition.X
		local w = math.max(track.AbsoluteSize.X, 1)
		set(min + (max - min) * math.clamp((x - a) / w, 0, 1))
	end

	local dragging = false
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			fromX(input.Position.X)
		end
	end)
	track.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			fromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)

	box.FocusLost:Connect(function()
		local typed = tonumber(box.Text)
		if typed then
			-- Deliberately NOT clamped to the slider's range: the range is a
			-- guess at what is useful, not a limit on what is legal.
			set(typed)
		else
			show(Config.Walk[key])
		end
	end)

	show(Config.Walk[key])
end

for _, group in GROUPS do
	label(group[1]:upper(), 11, DIM)
	for _, key in group[2] do
		local range = Config.WalkRanges[key]
		if range then
			slider(key, range[1], range[2])
		end
	end
end

local copy = Instance.new("TextButton")
copy.Size = UDim2.new(1, 0, 0, ROW)
copy.BackgroundColor3 = PANEL
copy.BorderSizePixel = 0
copy.Font = Enum.Font.Code
copy.TextSize = 12
copy.TextColor3 = TEXT
copy.Text = "Copy to Output"
copy.LayoutOrder = nextOrder()
copy.Parent = body

local copyCorner = Instance.new("UICorner")
copyCorner.CornerRadius = UDim.new(0, 4)
copyCorner.Parent = copy

--[[
	Print the tuned values in the order the tuner shows them, ready to paste
	over Config.Walk. Nothing here survives the session otherwise.
]]
copy.Activated:Connect(function()
	local out = { "-- paste over the matching lines in Config.Walk" }
	for _, group in GROUPS do
		table.insert(out, ("\t-- %s"):format(group[1]))
		for _, key in group[2] do
			local value = Config.Walk[key]
			if type(value) == "number" then
				table.insert(out, ("\t%s = %.3f,"):format(key, value))
			end
		end
	end
	print(table.concat(out, "\n"))
end)

ContextActionService:BindAction("ToggleWalkTuner", function(_, state)
	if state == Enum.UserInputState.Begin then
		gui.Enabled = not gui.Enabled
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.RightBracket)

if Config.Gait ~= "procedural" then
	print("[WalkTuner] Config.Gait is \"" .. tostring(Config.Gait)
		.. "\", so the gait is not running. Press ] to show the panel anyway.")
end
