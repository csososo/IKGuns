--[[
	GaitSync -- rebroadcasts tuner edits so everyone sees the same gait.

	Config is a ModuleScript, so every client holds its OWN copy of it.
	Tuning therefore only ever changed your own view: other clients kept
	running the committed values, including on your character. This relays
	each change so all of them agree.

	It is a development tool and it is worth being clear about what that
	means: it lets any client change how every character moves for everyone.
	Nothing here can hurt the server -- the values only ever reach a gait --
	but in a live game it is a griefing lever, so either delete this script
	or gate `allowed` below on whoever should have it.

	Everything arriving from a client is treated as hostile: only known
	profiles, only keys that already exist as numbers, only finite values
	inside a sane bound, only so many at a time, and only so often.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("IKSystem").Config)

local PROFILES = { Walk = Config.Walk, Jog = Config.Jog, Sprint = Config.Sprint }

-- Nothing in a gait is legitimately outside this, and it keeps a hostile
-- value from reaching the solver as an infinity or a NaN.
local LIMIT = 1000
local MAX_KEYS = 64
local MIN_INTERVAL = 0.05

local remote = Instance.new("RemoteEvent")
remote.Name = "GaitTuning"
remote.Parent = ReplicatedStorage

local lastSend = {}

-- Who may retune everyone's gait. Open while developing; narrow it or
-- delete this script before anyone else is in the place.
local function allowed(_player: Player): boolean
	return true
end

local function clean(values): { [string]: number }?
	if type(values) ~= "table" then
		return nil
	end
	local out, count = {}, 0
	for key, value in values do
		count += 1
		if count > MAX_KEYS then
			break
		end
		--[[
			The key has to already exist as a number in the walk profile.
			That is what stops this being a way to write arbitrary fields
			into a shared table, and it costs nothing, since every profile
			is built from the walk and so holds exactly the same keys.
		]]
		if type(key) == "string"
			and type(value) == "number"
			and value == value              -- not NaN
			and math.abs(value) <= LIMIT
			and type(Config.Walk[key]) == "number"
		then
			out[key] = value
		end
	end
	return next(out) and out or nil
end

remote.OnServerEvent:Connect(function(player, profile, values)
	if not allowed(player) then
		return
	end
	local now = os.clock()
	if now - (lastSend[player] or 0) < MIN_INTERVAL then
		return
	end
	lastSend[player] = now

	local store = type(profile) == "string" and PROFILES[profile]
	local safe = store and clean(values)
	if not safe then
		return
	end

	-- Applied here too, so a client joining later is not the only one out
	-- of step with everybody else.
	for key, value in safe do
		store[key] = value
	end
	remote:FireAllClients(profile, safe)
end)

--[[
	Bring a late joiner up to date.

	Without this they would run the committed values while everyone else
	ran the tuned ones, and every character would look different to them
	than to anybody else -- the exact problem this script exists to fix,
	just moved.

	Sent as whole profiles rather than deltas, because the server does not
	track which keys were touched and the whole thing is a few dozen
	numbers.
]]
local function catchUp(player: Player)
	for name, store in PROFILES do
		local numbers = {}
		for key, value in store do
			if type(value) == "number" then
				numbers[key] = value
			end
		end
		remote:FireClient(player, name, numbers)
	end
end

Players.PlayerAdded:Connect(catchUp)
for _, player in Players:GetPlayers() do
	catchUp(player)
end

Players.PlayerRemoving:Connect(function(player)
	lastSend[player] = nil
end)
