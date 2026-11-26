--!strict
--!optimize 2

local actor = script:GetActor()
if not actor then
	return
end

local RunService = game:GetService("RunService")

local parent = script.Parent :: Instance
local module = (parent:WaitForChild("Module") :: ObjectValue).Value :: Instance
local events = (parent.Parent :: Instance):WaitForChild("BulletEvents") :: BindableEvent
local runtime = (require(module:WaitForChild("BulletActor") :: ModuleScript) :: any)(actor, events)

for name, handler in runtime.Messages do
	actor:BindToMessage(name, handler)
end

RunService.Heartbeat:ConnectParallel(runtime.Step)
