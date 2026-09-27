--[[
    STAND BOT MAIN v2 — clean rewrite
    Places: Da Hood, Ranked DH, DERS HOOD, Des Hood, Hood Customs
    Inject on ALTS only. Owner types commands in public chat (Prefix from config).
    Config comes from Discord loader → StandConfig / getgenv().StandConfig
]]

local Config = rawget(_G, "StandConfig")
    or (getgenv and getgenv().StandConfig)
    or (shared and shared.StandConfig)
    or nil
if not Config then
    warn("[Stand] No StandConfig — use StandInject.lua or Discord /loader")
    return
end

----------------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------------
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local UserInputService  = game:GetService("UserInputService")
local VirtualUser       = game:GetService("VirtualUser")
local StarterGui        = game:GetService("StarterGui")
local TeleportService  = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

----------------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------------
local OwnerName    = tostring(Config.Owner or "")
local Prefix       = tostring(Config.Prefix or ".")
local PreferredGun = tostring(Config.Gun or "[DoubleBarrel]")
local MyRank       = string.lower(tostring(Config.Rank or "free"))
if MyRank ~= "premium" and MyRank ~= "bypass" then MyRank = "free" end

local Controllers = {}
do
    local list = Config.Controllers or {}
    if type(list) == "table" then
        for k, v in pairs(list) do
            if type(k) == "number" and type(v) == "string" then
                Controllers[string.lower(v)] = true
            elseif type(k) == "string" and v then
                Controllers[string.lower(k)] = true
            end
        end
    end
end

do
    local pid = game.PlaceId
    local daHoodStyle = (pid == 2788229376 or pid == 16033173781
        or pid == 96247461091106 or pid == 128413479081937)
    local low = string.lower(PreferredGun:gsub("[%[%]]", ""):gsub("%s+", ""))
    if low == "doublebarrel" or low == "doublebarrelsg" or low == "db" then
        PreferredGun = daHoodStyle and "[Double-Barrel SG]" or "[DoubleBarrel]"
    end
end

----------------------------------------------------------------------
-- PLACE DETECTION
----------------------------------------------------------------------
local PlaceId = game.PlaceId
local IsDaHood      = (PlaceId == 2788229376 or PlaceId == 16033173781)
local IsDersHood    = (PlaceId == 96247461091106 or PlaceId == 128413479081937)
local IsHoodCustoms = (PlaceId == 9825515356)
local IsDaHoodStyle = IsDaHood or IsDersHood

local MainEvent, UnreliableMainEvent, MainFunction
local MouseRemote = "MousePosUpdate"
pcall(function()
    MainEvent = ReplicatedStorage:FindFirstChild("MainEvent")
        or ReplicatedStorage:FindFirstChild("MainEventt")
        or ReplicatedStorage:FindFirstChild("MAINEVENT")
    UnreliableMainEvent = ReplicatedStorage:FindFirstChild("UnreliableMainEvent")
    MainFunction = ReplicatedStorage:FindFirstChild("MainFunction")
    if IsDaHoodStyle then
        MouseRemote = "UpdateMousePosI"
    elseif IsHoodCustoms then
        MouseRemote = "MousePosUpdate"
    else
        MouseRemote = "UpdateMousePos"
    end
end)

local placeLabel =
    (PlaceId == 128413479081937 and "Des Hood")
    or (PlaceId == 96247461091106 and "DERS HOOD")
    or (IsDaHood and "Da Hood")
    or (IsHoodCustoms and "Hood Customs")
    or ("Place " .. tostring(PlaceId))
print("[Stand] Place", PlaceId, placeLabel, "| MouseRemote =", MouseRemote)

----------------------------------------------------------------------
-- SLOT / OWNER
----------------------------------------------------------------------
-- Ground formation (Y = 0)
local SLOT_CF_GROUND = {
    [1] = CFrame.new(-3.5, 0, 0.5),
    [2] = CFrame.new( 3.5, 0, 0.5),
    [3] = CFrame.new( 0,   0, 3.5),
    [4] = CFrame.new( 0,   0,-3.5),
    [5] = CFrame.new(-6,   0, 1),
    [6] = CFrame.new( 0,   0, 6),
    [0] = CFrame.new( 2.5, 0, 2.5),
}

-- Floating summon formation: Y = height above owner, +Z = behind owner
local SLOT_CF_AIR = {
    [1] = CFrame.new(-3.2, 4.8, 2.8),  -- left float, slightly behind
    [2] = CFrame.new( 3.2, 4.8, 2.8),  -- right float, slightly behind
    [3] = CFrame.new( 0,   5.5, 4.0),  -- center behind, higher
    [4] = CFrame.new( 0,   4.2,-3.0),  -- front float
    [5] = CFrame.new(-5.5, 5.2, 3.5),  -- far left float
    [6] = CFrame.new( 0,   6.5, 5.5),  -- high center back
    [0] = CFrame.new( 2.5, 4.5, 2.5),  -- default float behind-right
}

local SLOT_CF = SLOT_CF_AIR  -- default: floating (use .air to toggle)

local function getMySlot()
    local alts = Config.Alts or {}
    local s = alts[LocalPlayer.Name]
    if s == nil then s = Config.Slot or 2 end
    return tonumber(s) or 2
end

local IsOwner = (string.lower(LocalPlayer.Name) == string.lower(OwnerName))
local MySlot  = getMySlot()
local VoidCF  = CFrame.new(0, -480, 0)

----------------------------------------------------------------------
-- STATE
----------------------------------------------------------------------
local State = {
    InVoid        = false,
    Tracking      = true,
    Armed         = false,
    Camlock       = false,
    TargetName    = nil,
    ProtectName   = nil,
    LoopKill      = nil,
    LoopKillKnife = false,
    LoopKnock     = nil,   -- loop knock only (no stomp)
    KnifeBusy     = false,
    LoopKillBusy  = false,
    AutoReload    = true,
    Sweep         = false,
    Air           = true,  -- floating summon formation (toggle with .air)
    Sentry        = false, -- .sentry — knock whoever shoots the OWNER
    Sentry2       = false, -- .sentry2 — knock+stomp whoever shoots the OWNER
    BSentry       = false, -- .bsentry — knock+stomp whoever shoots THIS stand
    AssistName    = nil,   -- .assist user — apply sentry modes for that user too
    SentryBusy    = false,
}

local Whitelist    = {}
local Connections  = {}
local CamTarget    = nil
local CamlockUntil = 0
local lastChatMsg, lastChatAt = "", 0

----------------------------------------------------------------------
-- CHARACTER HELPERS
----------------------------------------------------------------------
local function getChar(p) return (p or LocalPlayer).Character end

local function getHRP(p)
    local c = getChar(p)
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHum(p)
    local c = getChar(p)
    return c and c:FindFirstChildOfClass("Humanoid")
end

----------------------------------------------------------------------
-- IDLE ANIMATION (from Discord /config anim)
----------------------------------------------------------------------
local IdleTrack = nil

local function normalizeAnimId(id)
    if type(id) ~= "string" and type(id) ~= "number" then return nil end
    local s = tostring(id):gsub("%s+", "")
    if s == "" or s == "nil" or s == "0" then return nil end
    if s:match("^%d+$") then
        return "rbxassetid://" .. s
    end
    if s:match("^rbxassetid://%d+") or s:match("^https?://") then
        return s
    end
    -- bare number with junk or http-ish
    local num = s:match("(%d+)")
    if num then return "rbxassetid://" .. num end
    return nil
end

local function stopIdleAnim()
    if IdleTrack then
        pcall(function() IdleTrack:Stop(0.12) end)
        IdleTrack = nil
    end
end

local function isHoldingTool()
    local c = getChar()
    if not c then return false end
    for _, child in ipairs(c:GetChildren()) do
        if child:IsA("Tool") then return true end
    end
    return false
end

local function applyIdleAnim()
    local animId = normalizeAnimId(Config.Anim)
    if not animId then return end

    -- Don't fight gun/tool hold poses — idle only when unarmed
    if State.Armed or isHoldingTool() then
        stopIdleAnim()
        return
    end

    local char = getChar()
    if not char then return end
    local hum = getHum()
    if not hum then return end

    -- Already playing same track
    if IdleTrack and IdleTrack.IsPlaying then return end

    stopIdleAnim()

    local ok, err = pcall(function()
        -- Reduce conflict with default Animate script
        local animate = char:FindFirstChild("Animate")
        if animate and animate:IsA("LocalScript") then
            pcall(function()
                animate.Disabled = true
            end)
        end

        local animator = hum:FindFirstChildOfClass("Animator")
        if not animator then
            animator = Instance.new("Animator")
            animator.Parent = hum
        end

        -- Stop other idle-priority tracks so ours sticks
        for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
            if t.Priority == Enum.AnimationPriority.Idle or t.Priority == Enum.AnimationPriority.Core then
                pcall(function() t:Stop(0.1) end)
            end
        end

        local anim = Instance.new("Animation")
        anim.AnimationId = animId

        local track = animator:LoadAnimation(anim)
        track.Looped = true
        track.Priority = Enum.AnimationPriority.Action
        track:Play(0.15)
        IdleTrack = track
    end)
    if not ok then
        warn("[Stand] Failed to play idle anim:", animId, err)
    end
end

-- Watch character for tool equip/unequip so idle never blocks gun hold
local function hookToolWatch(char)
    if not char then return end
    char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then
            stopIdleAnim()
        end
    end)
    char.ChildRemoved:Connect(function(child)
        if child:IsA("Tool") then
            task.defer(function()
                if not State.Armed and not isHoldingTool() then
                    applyIdleAnim()
                end
            end)
        end
    end)
end

local function isKO(p)
    local c = getChar(p)
    if not c then return false end
    local be = c:FindFirstChild("BodyEffects")
    if be then
        for _, name in ipairs({"K.O", "KO", "Knocked", "IsKnocked", "Downed"}) do
            local v = be:FindFirstChild(name)
            if v then
                if typeof(v.Value) == "boolean" and v.Value then return true end
                if typeof(v.Value) == "number" and v.Value ~= 0 then return true end
            end
        end
    end
    local h = getHum(p)
    if h and h.PlatformStand and h.Health > 0 and h.Health < h.MaxHealth * 0.2 then
        return true
    end
    return false
end

local function isAlive(p)
    local h = getHum(p)
    if not h or h.Health <= 0 then return false end
    if isKO(p) then return false end
    return true
end

local function getOwner()
    if OwnerName == "" then return nil end
    for _, plr in ipairs(Players:GetPlayers()) do
        if string.lower(plr.Name) == string.lower(OwnerName) then
            return plr
        end
    end
    return nil
end

local function findPlayer(name, opts)
    -- opts.allowSelf = true to include LocalPlayer (default: skip self)
    if not name or name == "" then return nil end
    name = string.lower(tostring(name))
    local allowSelf = opts and opts.allowSelf

    local function ok(plr)
        if not plr then return false end
        if not allowSelf and plr == LocalPlayer then return false end
        return true
    end

    -- 1) exact username / displayname
    for _, plr in ipairs(Players:GetPlayers()) do
        if ok(plr) then
            if string.lower(plr.Name) == name or string.lower(plr.DisplayName) == name then
                return plr
            end
        end
    end

    -- 2) partial — prefer longest match, never self/owner unless exact
    local best, bestLen = nil, -1
    for _, plr in ipairs(Players:GetPlayers()) do
        if ok(plr) then
            local n = string.lower(plr.Name)
            local d = string.lower(plr.DisplayName)
            local hit = nil
            if string.find(n, name, 1, true) then hit = n
            elseif string.find(d, name, 1, true) then hit = d
            end
            if hit and #hit > bestLen then
                -- skip owner on partial (must type full name to target owner — still blocked by isProtected)
                if string.lower(plr.Name) == string.lower(OwnerName) and name ~= string.lower(OwnerName) then
                    -- skip
                else
                    best, bestLen = plr, #hit
                end
            end
        end
    end
    return best
end

-- returns true, reason
local function isProtected(plr)
    if not plr then return true, "nil" end
    if plr == LocalPlayer then return true, "self" end
    if string.lower(plr.Name) == string.lower(OwnerName) then return true, "owner" end
    if Controllers[string.lower(plr.Name)] then return true, "controller" end
    if Whitelist[plr.UserId] then return true, "whitelist" end
    if State.ProtectName and string.lower(plr.Name) == string.lower(State.ProtectName) then
        return true, "protect"
    end
    return false, nil
end

local function canControl(plr)
    if not plr then return false end
    local n = string.lower(plr.Name)
    if n == string.lower(OwnerName) then return true end
    if Controllers[n] then return true end
    return false
end

local function notify(msg)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Stand",
            Text = tostring(msg),
            Duration = 3,
        })
    end)
    print("[Stand]", msg)
end

----------------------------------------------------------------------
-- REMOTES / AIM
----------------------------------------------------------------------
local function fireMouse(pos)
    if not pos then return end
    if MainEvent then
        pcall(function() MainEvent:FireServer(MouseRemote, pos) end)
    end
    if UnreliableMainEvent then
        pcall(function() UnreliableMainEvent:FireServer(MouseRemote, pos) end)
    end
    pcall(function()
        local c = getChar()
        local be = c and c:FindFirstChild("BodyEffects")
        local mp = be and be:FindFirstChild("MousePos")
        if mp and mp:IsA("Vector3Value") then
            mp.Value = pos
        end
    end)
end

local function getAimPos(plr)
    local c = getChar(plr)
    if not c then return nil end
    local head = c:FindFirstChild("Head")
    local hrp  = getHRP(plr)
    if head then return head.Position + Vector3.new(0, 0.1, 0) end
    if hrp  then return hrp.Position + Vector3.new(0, 1.4, 0) end
    return nil
end

-- Silent aim: force Mouse.Hit / Target onto locked player so guns actually hit
local AimLockPlayer = nil

local function setAimLock(plr)
    AimLockPlayer = plr
end

local function clearAimLock()
    AimLockPlayer = nil
end

local silentAimHooked = false
local function ensureSilentAim()
    if silentAimHooked then return end
    silentAimHooked = true

    local mouse = nil
    pcall(function() mouse = LocalPlayer:GetMouse() end)

    -- hookmetamethod silent aim (works on most executors)
    pcall(function()
        if not (hookmetamethod and newcclosure) then return end
        if not mouse then return end
        local oldIndex
        oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
            if AimLockPlayer ~= nil and self == mouse then
                local k = key
                if k == "Hit" or k == "hit" then
                    local aim = getAimPos(AimLockPlayer)
                    if aim then return CFrame.new(aim) end
                elseif k == "Target" or k == "target" then
                    local ch = getChar(AimLockPlayer)
                    if ch then
                        return ch:FindFirstChild("Head") or getHRP(AimLockPlayer) or ch
                    end
                elseif k == "UnitRay" then
                    local aim = getAimPos(AimLockPlayer)
                    if aim and Camera then
                        local origin = Camera.CFrame.Position
                        local dir = (aim - origin)
                        if dir.Magnitude > 0 then
                            return Ray.new(origin, dir.Unit * 999)
                        end
                    end
                end
            end
            return oldIndex(self, key)
        end))
    end)

    -- always: keep mouse remotes + camera on target while locked
    RunService.RenderStepped:Connect(function()
        local plr = AimLockPlayer
        if not plr then return end
        if not getChar(plr) then return end
        local aim = getAimPos(plr)
        if not aim then return end
        fireMouse(aim)
        pcall(function()
            if Camera and Camera.CameraType ~= Enum.CameraType.Scriptable then
                Camera.CFrame = CFrame.new(Camera.CFrame.Position, aim)
            end
        end)
        pcall(function()
            local my = getHRP()
            if my then
                local pos = my.Position
                my.CFrame = CFrame.new(pos, Vector3.new(aim.X, pos.Y, aim.Z))
            end
        end)
    end)
end


local function setAttacking(on)
    pcall(function()
        local be = getChar() and getChar():FindFirstChild("BodyEffects")
        if not be then return end
        local a = be:FindFirstChild("Attacking")
        if a and a:IsA("BoolValue") then a.Value = on and true or false end
        local ac = be:FindFirstChild("Attacking_CLIENT")
        if ac and ac:IsA("BoolValue") then ac.Value = on and true or false end
    end)
end

local function fireHitRemotes(plr)
    local char = getChar(plr)
    local hum  = getHum(plr)
    local aim  = getAimPos(plr)
    local function go(remote, isFn)
        if not remote then return end
        local function send(a, b)
            if isFn then
                if b ~= nil then pcall(function() remote:InvokeServer(a, b) end)
                else pcall(function() remote:InvokeServer(a) end) end
            else
                if b ~= nil then pcall(function() remote:FireServer(a, b) end)
                else pcall(function() remote:FireServer(a) end) end
            end
        end
        send("Hit")
        send("Hit", char)
        send("Hit", hum)
        send("Hit", plr)
        send("Knife")
        send("Punch")
        send("Slash")
        send("Combat")
        if aim then send(MouseRemote, aim) end
    end
    go(MainEvent, false)
    go(UnreliableMainEvent, false)
    go(MainFunction, true)
end

----------------------------------------------------------------------
-- TOOLS
----------------------------------------------------------------------
local function findTool(name, exact)
    local c = getChar()
    local bag = LocalPlayer:FindFirstChild("Backpack")
    local want = string.lower(tostring(name))
    local function match(t)
        if not t or not t:IsA("Tool") then return false end
        local n = string.lower(t.Name)
        if exact then return n == want end
        return n == want or string.find(n, want, 1, true) ~= nil
    end
    for _, container in ipairs({c, bag}) do
        if container then
            for _, t in ipairs(container:GetChildren()) do
                if match(t) then return t end
            end
        end
    end
    return nil
end

local function equipTool(tool, timeout)
    if not tool then return nil end
    timeout = timeout or 0.6
    local c = getChar()
    local h = getHum()
    if not c or not h then return nil end
    if tool.Parent == c then return tool end
    pcall(function() h:UnequipTools() end)
    task.wait(0.03)
    pcall(function() h:EquipTool(tool) end)
    local t0 = tick()
    while tick() - t0 < timeout do
        if tool.Parent == c then return tool end
        task.wait(0.05)
    end
    return (tool.Parent == c) and tool or nil
end

local function activateTool(tool)
    if not tool then return false end
    local c = getChar()
    if tool.Parent ~= c then
        tool = equipTool(tool, 0.4)
    end
    if not tool or tool.Parent ~= c then return false end
    pcall(function() tool:Activate() end)
    return true
end

local function findKnife()
    return findTool("[Knife]", true)
        or findTool("Knife", true)
        or findTool("[Knife]", false)
        or findTool("Knife", false)
end

local function findGun()
    return findTool(PreferredGun, true)
        or findTool(PreferredGun, false)
        or findTool("[DoubleBarrel]", false)
        or findTool("[Double-Barrel SG]", false)
        or findTool("[Revolver]", false)
end

local function expandKnifeParts(knife)
    if not knife then return end
    pcall(function()
        for _, part in ipairs(knife:GetDescendants()) do
            if part:IsA("BasePart") then
                if not part:GetAttribute("StandOrig") then
                    part:SetAttribute("StandOrig", part.Size)
                end
                local orig = part:GetAttribute("StandOrig")
                if typeof(orig) == "Vector3" then
                    part.Size = Vector3.new(
                        math.max(orig.X * 4, 6),
                        math.max(orig.Y * 4, 8),
                        math.max(orig.Z * 4, 6)
                    )
                end
                part.Massless = true
                part.CanCollide = false
                pcall(function() part.CanTouch = true end)
            end
        end
    end)
end

----------------------------------------------------------------------
-- CAMLOCK (never set CameraType.Scriptable — breaks gun rays + CameraModule)
----------------------------------------------------------------------
local CAM_BIND = "StandCamlock"

local function clearCamlock()
    CamTarget = nil
    State.Camlock = false
    CamlockUntil = 0
    clearAimLock()
    pcall(function() RunService:UnbindFromRenderStep(CAM_BIND) end)
end

local function camlockStep()
    if not State.Camlock then return end
    if CamlockUntil > 0 and tick() > CamlockUntil then
        clearCamlock()
        return
    end
    local plr = CamTarget and findPlayer(CamTarget)
    if not plr then return end
    local aim = getAimPos(plr)
    if not aim then return end
    fireMouse(aim)
    -- soft look without breaking CameraModule
    pcall(function()
        if Camera and Camera.CameraType ~= Enum.CameraType.Scriptable then
            Camera.CFrame = CFrame.new(Camera.CFrame.Position, aim)
        end
    end)
end

local function setCamlock(plr, seconds)
    if not plr then return end
    CamTarget = plr.Name
    State.Camlock = true
    setAimLock(plr)
    pcall(ensureSilentAim)
    CamlockUntil = (seconds and seconds > 0) and (tick() + seconds) or 0
    pcall(function()
        RunService:UnbindFromRenderStep(CAM_BIND)
        RunService:BindToRenderStep(CAM_BIND, Enum.RenderPriority.Last.Value, camlockStep)
    end)
end

----------------------------------------------------------------------
-- FORMATION
----------------------------------------------------------------------
local function followOwner()
    if IsOwner then return end
    if State.KnifeBusy then return end
    if State.InVoid then
        local hrp = getHRP()
        if hrp then
            pcall(function()
                hrp.CFrame = VoidCF
                hrp.AssemblyLinearVelocity = Vector3.zero
            end)
        end
        return
    end
    if not State.Tracking then return end
    local owner = getOwner()
    if not owner then return end
    local oHRP = getHRP(owner)
    local my   = getHRP()
    if not oHRP or not my then return end
    local offset = SLOT_CF[MySlot] or SLOT_CF[2]
    pcall(function()
        my.CFrame = oHRP.CFrame * offset
        my.AssemblyLinearVelocity = Vector3.zero
    end)
end

local function returnToOwner()
    if IsOwner then return end
    clearCamlock()
    State.TargetName = nil
    State.InVoid = false
    State.Tracking = true
    State.KnifeBusy = false
    pcall(function()
        local h = getHum()
        if h then
            h.PlatformStand = false
            h.Sit = false
            h:ChangeState(Enum.HumanoidStateType.Running)
            h:UnequipTools()
        end
    end)
    local owner = getOwner()
    local oHRP = owner and getHRP(owner)
    local my = getHRP()
    if oHRP and my then
        local offset = SLOT_CF[MySlot] or SLOT_CF[2]
        for _ = 1, 5 do
            pcall(function()
                local cf = oHRP.CFrame * offset
                local char = getChar()
                if char and char.PivotTo then char:PivotTo(cf) end
                my.CFrame = cf
                my.AssemblyLinearVelocity = Vector3.zero
            end)
            task.wait(0.05)
            oHRP = getHRP(owner)
            my = getHRP()
            if not oHRP or not my then break end
        end
    end
    followOwner()
end

----------------------------------------------------------------------
----------------------------------------------------------------------
-- COMBAT: RELOAD
----------------------------------------------------------------------
local function reloadGun(gun)
    gun = gun or findGun()
    if not gun then return false end

    local c = getChar()
    local h = getHum()
    if not c or not h then return false end

    -- must be equipped for most hood places
    if gun.Parent ~= c then
        pcall(function() h:UnequipTools() end)
        task.wait(0.05)
        pcall(function() h:EquipTool(gun) end)
        local t0 = tick()
        while tick() - t0 < 0.6 and gun.Parent ~= c do
            task.wait(0.05)
        end
    end
    if gun.Parent ~= c then return false end

    -- 1) press R (real reload input)
    pcall(function()
        local vim = game:GetService("VirtualInputManager")
        if vim then
            vim:SendKeyEvent(true, Enum.KeyCode.R, false, game)
            task.wait(0.05)
            vim:SendKeyEvent(false, Enum.KeyCode.R, false, game)
        end
    end)
    pcall(function()
        local vu = game:GetService("VirtualUser")
        if vu then
            vu:SetKeyDown("0x52") -- R
            task.wait(0.05)
            vu:SetKeyUp("0x52")
        end
    end)

    -- 2) MainEvent family (Da Hood: Reload + tool instance is the real one)
    if MainEvent then
        pcall(function() MainEvent:FireServer("Reload", gun) end)
        pcall(function() MainEvent:FireServer("Reload", gun.Name) end)
        pcall(function() MainEvent:FireServer("Reload") end)
    end
    if UnreliableMainEvent then
        pcall(function() UnreliableMainEvent:FireServer("Reload") end)
        pcall(function() UnreliableMainEvent:FireServer("Reload", gun.Name) end)
    end
    if MainFunction then
        pcall(function() MainFunction:InvokeServer("Reload") end)
        pcall(function() MainFunction:InvokeServer("Reload", gun.Name) end)
    end

    -- 3) tool remotes / values
    pcall(function()
        for _, d in ipairs(gun:GetDescendants()) do
            if d:IsA("RemoteEvent") then
                pcall(function() d:FireServer() end)
                pcall(function() d:FireServer("Reload") end)
            elseif d:IsA("RemoteFunction") then
                pcall(function() d:InvokeServer() end)
                pcall(function() d:InvokeServer("Reload") end)
            end
        end
        -- common ammo values — set high if present (client side, may not stick)
        for _, name in ipairs({"Ammo", "ammo", "MaxAmmo", "Bullets", "Clip", "CLIENT"}) do
            local v = gun:FindFirstChild(name, true)
            if v and (v:IsA("NumberValue") or v:IsA("IntValue")) then
                local mx = gun:FindFirstChild("MaxAmmo", true) or gun:FindFirstChild("Max", true)
                if mx and (mx:IsA("NumberValue") or mx:IsA("IntValue")) then
                    v.Value = mx.Value
                elseif name == "CLIENT" then
                    -- leave CLIENT alone (skin/id on some tools)
                else
                    v.Value = 25
                end
            end
        end
    end)

    -- 4) clear stuck reloading flags
    pcall(function()
        local be = c:FindFirstChild("BodyEffects")
        if be then
            local r = be:FindFirstChild("Reloading")
            if r and r:IsA("BoolValue") then r.Value = false end
            local rc = be:FindFirstChild("Reloading_CLIENT")
            if rc and rc:IsA("BoolValue") then rc.Value = false end
        end
    end)

    return true
end

local lastAutoReload = 0
local function autoReloadTick()
    if not State.AutoReload then return end
    if State.KnifeBusy then return end
    if tick() - lastAutoReload < 1.5 then return end
    lastAutoReload = tick()

    local c = getChar()
    if not c then return end

    -- prefer currently equipped gun
    local equipped = nil
    for _, t in ipairs(c:GetChildren()) do
        if t:IsA("Tool") then
            local n = string.lower(t.Name)
            if n:find("barrel") or n:find("revolver") or n:find("shotgun")
                or n:find("pistol") or n:find("rifle") or n:find("gun")
                or n:find("tactical") or n:find("silencer") or n:find("ak")
                or n:find("smg") or n:find("ar")
                or n == string.lower(PreferredGun:gsub("[%[%]]", "")) then
                equipped = t
                break
            end
        end
    end

    -- if armed or loopkill gun mode, equip preferred gun and reload
    if not equipped and (State.Armed or (State.LoopKill and not State.LoopKillKnife)) then
        equipped = findGun()
        if equipped then
            pcall(function()
                local h = getHum()
                if h then h:EquipTool(equipped) end
            end)
            task.wait(0.08)
        end
    end

    if equipped then
        local need = true
        local ammo = equipped:FindFirstChild("Ammo", true)
        if ammo and (ammo:IsA("NumberValue") or ammo:IsA("IntValue")) then
            need = (ammo.Value <= 0)
        end
        if need then
            reloadGun(equipped)
        end
    end
end

-- COMBAT: SHOOT
----------------------------------------------------------------------
local function shootTarget(plr)
    if not plr or isProtected(plr) or not isAlive(plr) then return end
    if State.InVoid then State.InVoid = false end

    local gun = findGun()
    if not gun then
        notify("No gun: " .. PreferredGun)
        return
    end
    gun = equipTool(gun, 0.8)
    if not gun then
        notify("Could not equip gun")
        return
    end
    State.Armed = true
    setAimLock(plr)
    pcall(ensureSilentAim)
    setCamlock(plr, 4)

    -- face target + get into range
    local function faceAndClose()
        local my = getHRP()
        local their = getHRP(plr)
        if not my or not their then return end
        local aim = getAimPos(plr) or their.Position
        local dist = (my.Position - their.Position).Magnitude
        -- double barrel is short range — stay ~8-14 studs in front
        local ideal = 10
        if dist > 18 or dist < 4 then
            local dir = (my.Position - their.Position)
            if dir.Magnitude < 0.1 then dir = their.CFrame.LookVector end
            dir = dir.Unit
            local pos = their.Position + dir * ideal + Vector3.new(0, 0.5, 0)
            pcall(function()
                local ch = getChar()
                local cf = CFrame.new(pos, aim)
                if ch and ch.PivotTo then ch:PivotTo(cf) end
                my.CFrame = cf
                my.AssemblyLinearVelocity = Vector3.zero
            end)
        else
            pcall(function()
                my.CFrame = CFrame.new(my.Position, aim)
            end)
        end
    end

    faceAndClose()
    reloadGun(gun)
    task.wait(0.15)

    for shot = 1, 10 do
        if not isAlive(plr) or isKO(plr) then break end
        if gun.Parent ~= getChar() then
            gun = equipTool(findGun(), 0.5)
            if not gun then break end
        end

        faceAndClose()
        local aim = getAimPos(plr)
        if not aim then break end

        -- spam mouse aim BEFORE shot (critical for hits)
        for _ = 1, 8 do
            fireMouse(aim)
        end
        pcall(function()
            local be = getChar() and getChar():FindFirstChild("BodyEffects")
            local mp = be and be:FindFirstChild("MousePos")
            if mp then mp.Value = aim end
        end)

        -- look with camera softly
        pcall(function()
            if Camera then
                Camera.CFrame = CFrame.new(Camera.CFrame.Position, aim)
            end
        end)

        activateTool(gun)

        -- mouse click (some guns key off input not Activate)
        pcall(function()
            local vim = game:GetService("VirtualInputManager")
            if vim then
                vim:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                task.wait(0.03)
                vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
            end
        end)

        if MainEvent then
            pcall(function() MainEvent:FireServer(MouseRemote, aim) end)
            pcall(function() MainEvent:FireServer("Shoot", aim) end)
            pcall(function() MainEvent:FireServer("Hit", getChar(plr)) end)
        end

        if shot % 4 == 0 then
            reloadGun(gun)
            task.wait(0.2)
        end
        task.wait(0.14)
    end

    reloadGun(gun)
end

-- COMBAT: STOMP
----------------------------------------------------------------------
local function stompTarget(plr, times)
    if not plr then return end
    times = times or 12
    State.Tracking = false

    for i = 1, times do
        if not getChar(plr) then break end
        -- if they got up and are no longer KO, stop stomping this cycle
        if not isKO(plr) and i > 2 then
            local h = getHum(plr)
            if h and h.Health > 15 then break end
        end

        local my = getHRP()
        local their = getHRP(plr)
        if my and their then
            -- stand on their torso / head area (classic hood stomp pos)
            local pos = their.Position + Vector3.new(0, 2.5, 0)
            pcall(function()
                local ch = getChar()
                local cf = CFrame.new(pos)
                if ch and ch.PivotTo then ch:PivotTo(cf) end
                my.CFrame = cf
                my.AssemblyLinearVelocity = Vector3.zero
                my.AssemblyAngularVelocity = Vector3.zero
            end)
        end

        -- E key (stomp)
        pcall(function()
            local vim = game:GetService("VirtualInputManager")
            if vim then
                vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                task.wait(0.06)
                vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
            end
        end)
        pcall(function()
            local vu = game:GetService("VirtualUser")
            if vu then
                vu:SetKeyDown("0x45")
                task.wait(0.05)
                vu:SetKeyUp("0x45")
            end
        end)

        local char = getChar(plr)
        if MainEvent then
            for _, n in ipairs({"Stomp", " stoomp", "KnockedStomp", "Finish", "StompPlayer"}) do
                pcall(function() MainEvent:FireServer(n) end)
                pcall(function() MainEvent:FireServer(n, true) end)
                if char then
                    pcall(function() MainEvent:FireServer(n, char) end)
                    pcall(function() MainEvent:FireServer(n, char, true) end)
                end
                pcall(function() MainEvent:FireServer(n, plr) end)
            end
        end
        if UnreliableMainEvent then
            pcall(function() UnreliableMainEvent:FireServer("Stomp") end)
            pcall(function() UnreliableMainEvent:FireServer("Stomp", true) end)
        end

        task.wait(0.1)
    end
end

-- COMBAT: KNIFE
----------------------------------------------------------------------
local function knifeTarget(plr)
    if not plr or isProtected(plr) then return end
    if State.KnifeBusy then return end
    State.KnifeBusy = true
    State.Tracking = false
    if State.InVoid then State.InVoid = false end

    task.spawn(function()
        local knife = findKnife()
        if knife then knife = equipTool(knife, 1.0) end
        if not knife then
            notify("Knife: equip [Knife] in backpack first")
            State.KnifeBusy = false
            State.Tracking = true
            return
        end
        expandKnifeParts(knife)
        setCamlock(plr, 10)
        notify("Knife -> " .. plr.Name)

        do
            local my = getHRP()
            local their = getHRP(plr)
            if my and their then
                local start = my.Position
                for step = 1, 10 do
                    their = getHRP(plr)
                    my = getHRP()
                    if not my or not their then break end
                    local goal = their.Position + Vector3.new(0, 0.25, 0)
                    local pos = start:Lerp(goal, step / 10)
                    local cf = CFrame.new(pos, their.Position + Vector3.new(0, 1.2, 0))
                    pcall(function()
                        local ch = getChar()
                        if ch and ch.PivotTo then ch:PivotTo(cf) end
                        my.CFrame = cf
                        my.AssemblyLinearVelocity = Vector3.zero
                    end)
                    task.wait(0.04)
                end
            end
        end

        local under = false
        local lockConn
        lockConn = RunService.Heartbeat:Connect(function()
            if not plr or isKO(plr) or not getChar(plr) then return end
            local my = getHRP()
            local their = getHRP(plr)
            if not my or not their then return end
            local off = under and Vector3.new(0, -1.8, 0) or Vector3.new(0, 0.25, 0)
            local pos = their.Position + off
            local cf = CFrame.new(pos, their.Position + Vector3.new(0, 1.2, 0))
            pcall(function()
                local ch = getChar()
                if ch and ch.PivotTo then ch:PivotTo(cf) end
                my.CFrame = cf
                my.AssemblyLinearVelocity = Vector3.zero
            end)
        end)

        local t0 = tick()
        local swing = 0
        while tick() - t0 < 6.5 do
            if isKO(plr) or not getChar(plr) then break end
            swing = swing + 1
            under = (swing % 6) >= 3

            if not knife or knife.Parent ~= getChar() then
                knife = equipTool(findKnife(), 0.5)
                if knife then expandKnifeParts(knife) end
            end

            local aim = getAimPos(plr)
            if aim then for _ = 1, 5 do fireMouse(aim) end end

            setAttacking(true)
            if knife then activateTool(knife) end
            fireHitRemotes(plr)

            pcall(function()
                local vim = game:GetService("VirtualInputManager")
                if vim then
                    vim:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                    task.wait(0.02)
                    vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
                end
            end)

            task.wait(0.1)
        end

        if lockConn then pcall(function() lockConn:Disconnect() end) end
        setAttacking(false)

        if isKO(plr) then
            notify("KO - stomping " .. plr.Name)
            stompTarget(plr, 8)
        else
            notify("Knife done (no KO) - try .stomp " .. plr.Name)
        end

        clearCamlock()
        State.KnifeBusy = false
        State.Tracking = true
        returnToOwner()
    end)
end

----------------------------------------------------------------------
-- AUTO PERKS
----------------------------------------------------------------------
local function applyArmorMax()
    pcall(function()
        local c = getChar()
        if not c then return end
        local be = c:FindFirstChild("BodyEffects")
        if be then
            local a = be:FindFirstChild("Armor")
            if a and (a:IsA("NumberValue") or a:IsA("IntValue")) then
                a.Value = 100
            end
        end
        for _, d in ipairs(c:GetDescendants()) do
            if d:IsA("NumberValue") or d:IsA("IntValue") then
                local n = string.lower(d.Name)
                if n == "armor" or n == "defense" or n == "defence" then
                    d.Value = 100
                end
            end
        end
    end)
end

local function buyArmor()
    if MainEvent then
        pcall(function() MainEvent:FireServer("BuyArmor") end)
        pcall(function() MainEvent:FireServer("Armor") end)
    end
    pcall(function()
        local shop = Workspace:FindFirstChild("Ignored")
        shop = shop and shop:FindFirstChild("Shop")
        if not shop then return end
        for _, m in ipairs(shop:GetChildren()) do
            if string.find(string.lower(m.Name), "armor") then
                local cd = m:FindFirstChildWhichIsA("ClickDetector", true)
                if cd and fireclickdetector then
                    fireclickdetector(cd)
                end
            end
        end
    end)
    applyArmorMax()
end

local function buyMask()
    if MainEvent then
        pcall(function() MainEvent:FireServer("Mask") end)
        pcall(function() MainEvent:FireServer("BuyMask") end)
    end
end

local function applyMuscle()
    if not Config.Muscle then return end
    local size = tonumber(Config.MuscleSize) or 15000
    pcall(function()
        local be = getChar() and getChar():FindFirstChild("BodyEffects")
        if be then
            for _, name in ipairs({"Muscle", "MuscleSize", "Strength"}) do
                local v = be:FindFirstChild(name)
                if v and (v:IsA("NumberValue") or v:IsA("IntValue")) then
                    v.Value = size
                end
            end
        end
        if MainEvent then
            pcall(function() MainEvent:FireServer("Muscle", size) end)
        end
    end)
end

local function startAutoPerks()
pcall(ensureSilentAim)
    if IsOwner then return end
    task.spawn(function()
        local t0 = tick()
        while tick() - t0 < 10 do
            if getHRP() then break end
            task.wait(0.3)
        end
        task.wait(0.5)
        if Config.AutoArmor then buyArmor() end
        if Config.ArmorMax or Config.Inf then applyArmorMax() end
        if Config.AutoMask then buyMask() end
        if Config.Muscle then applyMuscle() end
        if Config.Inf or Config.ArmorMax then
            while true do
                if Config.Inf or Config.ArmorMax then
                    applyArmorMax()
                    if Config.Inf then buyArmor() end
                end
                task.wait(Config.Inf and 1.5 or 4)
            end
        end
    end)
end

----------------------------------------------------------------------
-- COMMANDS
----------------------------------------------------------------------
local function cmdVoid()
    if IsOwner then return end
    State.InVoid = true
    State.Tracking = false
    clearCamlock()
    notify("Void ON")
end

local function cmdCall()
    if IsOwner then return end
    State.InVoid = false
    State.Tracking = true
    returnToOwner()
    notify("Call - returning")
end

local function cmdTrack()
    if IsOwner then return end
    State.Tracking = not State.Tracking
    notify("Track " .. (State.Tracking and "ON" or "OFF"))
end

local function cmdAir(arg)
    if arg == "on" or arg == "1" or arg == "true" then
        State.Air = true
    elseif arg == "off" or arg == "0" or arg == "false" then
        State.Air = false
    else
        State.Air = not State.Air
    end
    SLOT_CF = State.Air and SLOT_CF_AIR or SLOT_CF_GROUND
    if not IsOwner and State.Tracking and not State.InVoid then
        returnToOwner()
    end
    notify("Air " .. (State.Air and "ON (floating)" or "OFF (ground)"))
end

local function cmdPos(slot)
    local n = tonumber(slot)
    if n and SLOT_CF[n] then
        MySlot = n
        notify("Slot " .. n)
    else
        notify("Usage: " .. Prefix .. "pos 1-6")
    end
end

local function cmdArm()
    local g = findGun()
    if not g then notify("No gun found") return end
    stopIdleAnim()
    g = equipTool(g, 0.7)
    State.Armed = g ~= nil
    notify(State.Armed and ("Armed " .. g.Name) or "Arm failed")
end

local function cmdUnarm()
    pcall(function()
        local h = getHum()
        if h then h:UnequipTools() end
    end)
    State.Armed = false
    task.defer(applyIdleAnim)
    notify("Unarmed")
end

-- .d — knock only (no stomp)
local function cmdKnock(user)
    local plr = findPlayer(user)
    if not plr then notify("Knock: not found (" .. tostring(user) .. ")") return end
    local prot, why = isProtected(plr)
    if prot then
        notify("Knock: protected (" .. tostring(why) .. " = " .. plr.Name .. ")")
        return
    end
    State.Tracking = false
    task.spawn(function()
        shootTarget(plr)
        local t0 = tick()
        while tick() - t0 < 2.5 do
            if isKO(plr) then break end
            if not getChar(plr) then break end
            task.wait(0.15)
        end
        if not isKO(plr) then
            shootTarget(plr)
        end
        clearAimLock()
        clearCamlock()
        State.Tracking = true
        returnToOwner()
    end)
end

-- .s — stomp only
local function cmdStomp(user)
    local plr = findPlayer(user)
    if not plr then notify("Stomp: not found") return end
    State.Tracking = false
    task.spawn(function()
        stompTarget(plr, 12)
        State.Tracking = true
        returnToOwner()
    end)
end

local function cmdKnife(user)
    local plr = findPlayer(user)
    if not plr then notify("Knife: not found (" .. tostring(user) .. ")") return end
    local prot, why = isProtected(plr)
    if prot then
        notify("Knife: protected (" .. tostring(why) .. " = " .. plr.Name .. ")")
        return
    end
    knifeTarget(plr)
end

-- .b — bring target near owner
local function cmdBring(user)
    local plr = findPlayer(user)
    if not plr then notify("Bring: not found (" .. tostring(user) .. ")") return end
    local prot, why = isProtected(plr)
    if prot then
        notify("Bring: protected (" .. tostring(why) .. ")")
        return
    end
    State.Tracking = false
    task.spawn(function()
        local owner = getOwner()
        local oHRP = owner and getHRP(owner)
        local their = getHRP(plr)
        local my = getHRP()
        if not their or not my then
            State.Tracking = true
            returnToOwner()
            return
        end
        -- go to target
        for _ = 1, 8 do
            their = getHRP(plr)
            my = getHRP()
            if not their or not my then break end
            pcall(function()
                my.CFrame = their.CFrame * CFrame.new(0, 0, 2)
                my.AssemblyLinearVelocity = Vector3.zero
            end)
            -- common grab/carry remotes
            if MainEvent then
                pcall(function() MainEvent:FireServer("Grabbing", true) end)
                pcall(function() MainEvent:FireServer("Grab") end)
                pcall(function() MainEvent:FireServer("Carry") end)
            end
            task.wait(0.08)
        end
        -- haul toward owner
        oHRP = owner and getHRP(owner)
        for _ = 1, 12 do
            oHRP = owner and getHRP(owner)
            my = getHRP()
            their = getHRP(plr)
            if not oHRP or not my then break end
            pcall(function()
                my.CFrame = oHRP.CFrame * CFrame.new(0, 0, 3)
                my.AssemblyLinearVelocity = Vector3.zero
            end)
            if MainEvent then
                pcall(function() MainEvent:FireServer("Grabbing", true) end)
            end
            task.wait(0.07)
        end
        if MainEvent then
            pcall(function() MainEvent:FireServer("Grabbing", false) end)
        end
        State.Tracking = true
        returnToOwner()
        notify("Bring done " .. plr.Name)
    end)
end

-- .l — loop kill (shoot + stomp)
local function cmdLoopKill(user, useKnife)
    local plr = findPlayer(user)
    if not plr then notify("LoopKill: not found (" .. tostring(user) .. ")") return end
    local prot, why = isProtected(plr)
    if prot then
        notify("LoopKill: protected (" .. tostring(why) .. " = " .. plr.Name .. ")")
        return
    end
    State.LoopKnock = nil
    State.LoopKill = plr.Name
    State.LoopKillKnife = useKnife and true or false
    State.LoopKillBusy = false
    State.Tracking = false
    notify("LoopKill " .. (useKnife and "knife " or "gun ") .. "ON " .. plr.Name)
end

-- .lk — loop knock only (no stomp)
local function cmdLoopKnock(user)
    local plr = findPlayer(user)
    if not plr then notify("LoopKnock: not found (" .. tostring(user) .. ")") return end
    local prot, why = isProtected(plr)
    if prot then
        notify("LoopKnock: protected (" .. tostring(why) .. ")")
        return
    end
    State.LoopKill = nil
    State.LoopKillKnife = false
    State.LoopKnock = plr.Name
    State.LoopKillBusy = false
    State.Tracking = false
    notify("LoopKnock ON " .. plr.Name)
end

local function cmdUnLoopKill()
    State.LoopKill = nil
    State.LoopKillKnife = false
    State.LoopKnock = nil
    State.LoopKillBusy = false
    clearCamlock()
    if not IsOwner then State.Tracking = true end
    notify("Loop OFF")
end

local function parseOnOff(arg, current)
    if arg == "on" or arg == "1" or arg == "true" then return true end
    if arg == "off" or arg == "0" or arg == "false" then return false end
    return not current
end

local function cmdSentry(arg)
    State.Sentry = parseOnOff(arg, State.Sentry)
    if State.Sentry then State.Sentry2 = false end
    notify("Sentry " .. (State.Sentry and "ON" or "OFF") .. " (knock who shoots owner)")
end

local function cmdSentry2(arg)
    State.Sentry2 = parseOnOff(arg, State.Sentry2)
    if State.Sentry2 then State.Sentry = false end
    notify("Sentry2 " .. (State.Sentry2 and "ON" or "OFF") .. " (knock+stomp who shoots owner)")
end

local function cmdBSentry(arg)
    State.BSentry = parseOnOff(arg, State.BSentry)
    notify("BSentry " .. (State.BSentry and "ON" or "OFF") .. " (knock+stomp who shoots stand)")
end

local function cmdAssist(user)
    local plr = findPlayer(user)
    if not plr then notify("Assist: not found") return end
    State.AssistName = plr.Name
    notify("Assist ON " .. plr.Name .. " (sentry covers them too)")
end

local function cmdUnassist()
    State.AssistName = nil
    notify("Assist OFF")
end

local function cmdSay(msg)
    if not msg or msg == "" then
        notify("Usage: " .. Prefix .. "say <message>")
        return
    end
    pcall(function()
        local tcs = game:GetService("TextChatService")
        local channel = tcs and tcs.TextChannels and (
            tcs.TextChannels:FindFirstChild("RBXGeneral")
            or tcs.TextChannels:FindFirstChild("General")
        )
        if channel and channel.SendAsync then
            channel:SendAsync(msg)
            return
        end
    end)
    pcall(function()
        local chat = game:GetService("Chat")
        if chat and chat.Chat then
            chat:Chat(getChar() or LocalPlayer, msg)
        end
    end)
    pcall(function()
        local rs = game:GetService("ReplicatedStorage")
        local re = rs:FindFirstChild("DefaultChatSystemChatEvents")
        if re then
            local say = re:FindFirstChild("SayMessageRequest")
            if say then say:FireServer(msg, "All") end
        end
    end)
end

-- React to attacker (sentry / sentry2 / bsentry / assist)
local function sentryReact(plr, doStomp)
    if not plr or isProtected(plr) then return end
    if not isAlive(plr) and not isKO(plr) then return end
    if State.SentryBusy then return end
    State.SentryBusy = true
    State.Tracking = false
    task.spawn(function()
        if isKO(plr) and doStomp then
            stompTarget(plr, 10)
        elseif isAlive(plr) then
            shootTarget(plr)
            local t0 = tick()
            while tick() - t0 < 2.2 do
                if isKO(plr) then break end
                task.wait(0.12)
            end
            if doStomp and isKO(plr) then
                stompTarget(plr, 10)
            end
        end
        clearAimLock()
        clearCamlock()
        State.Tracking = true
        returnToOwner()
        task.wait(0.35)
        State.SentryBusy = false
    end)
end

-- Find who most likely shot `victim` (creator tag → nearest armed enemy looking at them)
local function findAttacker(victim)
    if not victim then return nil end
    local hum = getHum(victim)
    if hum then
        for _, name in ipairs({"creator", "Creator", "LastHit", "Attacker", "Killer"}) do
            local tag = hum:FindFirstChild(name)
            if tag then
                local val = tag.Value
                if typeof(val) == "Instance" then
                    if val:IsA("Player") then return val end
                    if val:IsA("Model") then
                        local p = Players:GetPlayerFromCharacter(val)
                        if p then return p end
                    end
                end
            end
        end
        local be = getChar(victim) and getChar(victim):FindFirstChild("BodyEffects")
        if be then
            for _, name in ipairs({"Attacker", "LastAttacker", "Shooting", "Creator"}) do
                local tag = be:FindFirstChild(name)
                if tag and tag.Value then
                    local val = tag.Value
                    if typeof(val) == "Instance" then
                        if val:IsA("Player") then return val end
                        if val:IsA("Model") then
                            local p = Players:GetPlayerFromCharacter(val)
                            if p then return p end
                        end
                    end
                end
            end
        end
    end
    -- fallback: nearest non-protected player with a tool aimed near victim
    local vHRP = getHRP(victim)
    if not vHRP then return nil end
    local best, bestDist = nil, 90
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= victim and plr ~= LocalPlayer and not isProtected(plr) and isAlive(plr) then
            local hrp = getHRP(plr)
            local ch = getChar(plr)
            if hrp and ch then
                local hasTool = false
                for _, c in ipairs(ch:GetChildren()) do
                    if c:IsA("Tool") then hasTool = true break end
                end
                if hasTool then
                    local d = (hrp.Position - vHRP.Position).Magnitude
                    if d < bestDist then
                        bestDist = d
                        best = plr
                    end
                end
            end
        end
    end
    return best
end

local HealthWatch = {} -- [player] = lastHealth

local function onVictimDamaged(victim, doStomp)
    if State.SentryBusy then return end
    local attacker = findAttacker(victim)
    if attacker then
        sentryReact(attacker, doStomp)
    end
end

local function watchPlayerHealth(plr, mode)
    -- mode: "owner" | "stand" | "assist"
    if not plr then return end
    local hum = getHum(plr)
    if not hum then return end
    local key = plr.UserId
    HealthWatch[key] = hum.Health
    if Connections["hp_" .. key] then
        pcall(function() Connections["hp_" .. key]:Disconnect() end)
    end
    Connections["hp_" .. key] = hum.HealthChanged:Connect(function(hp)
        local prev = HealthWatch[key] or hp
        HealthWatch[key] = hp
        if hp >= prev then return end -- only care about damage taken
        if mode == "owner" then
            -- whoever shoots the owner
            if State.Sentry or State.Sentry2 then
                onVictimDamaged(plr, State.Sentry2)
            end
        elseif mode == "stand" then
            -- whoever shoots this stand → knock+stomp
            if State.BSentry then
                onVictimDamaged(plr, true)
            end
        elseif mode == "assist" then
            -- assist target gets same treatment as active sentry modes
            if State.Sentry or State.Sentry2 then
                onVictimDamaged(plr, State.Sentry2)
            elseif State.BSentry then
                onVictimDamaged(plr, true)
            end
        end
    end)
end

local function refreshSentryWatches()
    -- Owner
    local owner = getOwner()
    if owner then watchPlayerHealth(owner, "owner") end
    -- This stand
    watchPlayerHealth(LocalPlayer, "stand")
    -- Assist target
    if State.AssistName then
        local ap = findPlayer(State.AssistName)
        if ap then watchPlayerHealth(ap, "assist") end
    end
end

-- One full attack cycle for loopkill (gun or knife). Called once at a time.
local function loopKillCycle(plr)
    if not plr then return end
    if State.LoopKillKnife then
        -- knifeTarget is async and sets KnifeBusy; wait until done
        if State.KnifeBusy then return end
        knifeTarget(plr)
        local t0 = tick()
        while State.KnifeBusy and tick() - t0 < 12 and State.LoopKill do
            task.wait(0.2)
        end
    else
        shootTarget(plr)
        task.wait(0.25)
        if isKO(plr) then
            stompTarget(plr, 6)
        end
    end
end

local function cmdSweep()
    if State.Sweep then
        notify("Sweep already ON")
        return
    end
    State.Sweep = true
    State.Tracking = false
    notify("Sweep ON — clearing server")
    task.spawn(function()
        while State.Sweep do
            local targets = {}
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer and not isProtected(plr) then
                    if isAlive(plr) or isKO(plr) then
                        targets[#targets + 1] = plr
                    end
                end
            end
            if #targets == 0 then
                task.wait(1)
            else
                for _, plr in ipairs(targets) do
                    if not State.Sweep then break end
                    if isProtected(plr) then continue end
                    if isKO(plr) then
                        stompTarget(plr, 10)
                    elseif isAlive(plr) then
                        setAimLock(plr)
                        pcall(ensureSilentAim)
                        setCamlock(plr, 3)
                        shootTarget(plr)
                        local t0 = tick()
                        while tick() - t0 < 2 and State.Sweep do
                            if isKO(plr) then break end
                            if not getChar(plr) then break end
                            task.wait(0.15)
                        end
                        if isKO(plr) then
                            stompTarget(plr, 12)
                        end
                    end
                    task.wait(0.2)
                end
            end
            task.wait(0.35)
        end
        clearAimLock()
        clearCamlock()
        State.Tracking = true
        returnToOwner()
        notify("Sweep OFF")
    end)
end

local function cmdUnSweep()
    State.Sweep = false
    notify("Sweep stopping...")
end

local function cmdProtect(user)
    local plr = findPlayer(user)
    if not plr then notify("Protect: not found") return end
    State.ProtectName = plr.Name
    notify("Protect " .. plr.Name)
end

local function cmdUnprotect()
    State.ProtectName = nil
    notify("Protect OFF")
end

local function cmdWL(user)
    local plr = findPlayer(user)
    if not plr then notify("WL: not found") return end
    Whitelist[plr.UserId] = true
    notify("WL " .. plr.Name)
end

local function cmdUWL(user)
    if user and user ~= "" then
        local plr = findPlayer(user)
        if plr then
            Whitelist[plr.UserId] = nil
            notify("UWL " .. plr.Name)
            return
        end
    end
    Whitelist = {}
    notify("WL cleared")
end

local function cmdTarget(user)
    local plr = findPlayer(user)
    if not plr then notify("Target: not found") return end
    if isProtected(plr) then notify("Target: protected") return end
    State.TargetName = plr.Name
    setCamlock(plr, 0)
    notify("Target " .. plr.Name)
end

local function cmdUntarget()
    State.TargetName = nil
    clearCamlock()
    notify("Target OFF")
end

local function cmdArmor()
    buyArmor()
    notify("Armor")
end

local function cmdMask()
    buyMask()
    notify("Mask")
end

local function cmdFix()
    -- Full reset: stop all modes, clear tools, respawn character, return to formation
    clearCamlock()
    State.LoopKill = nil
    State.LoopKillKnife = false
    State.LoopKnock = nil
    State.LoopKillBusy = false
    State.Sweep = false
    State.TargetName = nil
    State.KnifeBusy = false
    State.SentryBusy = false
    State.InVoid = false
    State.Tracking = false  -- pause formation until respawn finishes
    State.Armed = false
    setAttacking(false)

    pcall(function()
        local h = getHum()
        if h then
            h.PlatformStand = false
            h.Sit = false
            h.WalkSpeed = 16
            h.JumpPower = 50
            h.JumpHeight = 7.2
            h:ChangeState(Enum.HumanoidStateType.GettingUp)
            h:UnequipTools()
        end
    end)

    -- hard respawn
    pcall(function()
        LocalPlayer:LoadCharacter()
    end)

    task.spawn(function()
        local t0 = tick()
        while tick() - t0 < 8 do
            if getHRP() and getHum() and getHum().Health > 0 then break end
            task.wait(0.15)
        end
        task.wait(0.35)
        -- re-apply perks after respawn
        if Config.AutoArmor then pcall(buyArmor) end
        if Config.ArmorMax or Config.Inf then pcall(applyArmorMax) end
        if Config.AutoMask then pcall(buyMask) end
        State.Tracking = true
        if not IsOwner then
            returnToOwner()
        end
        notify("Fix - respawned")
    end)
end

local function cmdKick()
    -- Leave server and rejoin same place / same job if possible
    notify("Rejoining...")
    task.spawn(function()
        task.wait(0.2)
        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
        end)
        if not ok then
            pcall(function()
                TeleportService:Teleport(game.PlaceId, LocalPlayer)
            end)
        end
    end)
end

local function cmdHelp()
    notify("See F9 for command list")
    print("[Stand] Commands:")
    print("  " .. Prefix .. "void / call / track / air [on|off] / pos <1-6>")
    print("  " .. Prefix .. "arm / unarm")
    print("  " .. Prefix .. "d <user>   -- knock")
    print("  " .. Prefix .. "b <user>   -- bring")
    print("  " .. Prefix .. "s <user>   -- stomp")
    print("  " .. Prefix .. "l <user>   -- loop kill")
    print("  " .. Prefix .. "lk <user>  -- loop knock")
    print("  " .. Prefix .. "unlk / knife <user>")
    print("  " .. Prefix .. "sentry on|off  -- knock who shoots owner")
    print("  " .. Prefix .. "sentry2 on|off -- knock+stomp who shoots owner")
    print("  " .. Prefix .. "bsentry on|off -- knock+stomp who shoots stand")
    print("  " .. Prefix .. "assist <user> / unassist  -- sentry covers that user too")
    print("  " .. Prefix .. "say <message>")
    print("  " .. Prefix .. "sweep / unsweep")
    print("  " .. Prefix .. "protect <user> / unprotect / wl / uwl")
    print("  " .. Prefix .. "target <user> / untarget")
    print("  " .. Prefix .. "armor / mask / reload / autoreload / fix / kick / help")
end

----------------------------------------------------------------------
-- CHAT HANDLER
----------------------------------------------------------------------
local function onControlChat(msg, speaker)
    if type(msg) ~= "string" then return end
    if not canControl(speaker) then return end

    msg = string.gsub(msg, "^%s+", "")
    msg = string.gsub(msg, "%s+$", "")
    if string.sub(msg, 1, #Prefix) ~= Prefix then return end

    local now = tick()
    if msg == lastChatMsg and (now - lastChatAt) < 0.35 then return end
    lastChatMsg = msg
    lastChatAt = now

    local rawBody = string.sub(msg, #Prefix + 1)
    local body = string.lower(rawBody)
    local parts = {}
    for w in string.gmatch(body, "%S+") do parts[#parts + 1] = w end
    if #parts == 0 then return end

    local cmd, a1 = parts[1], parts[2]
    -- original-case remainder for .say
    local sayMsg = nil
    if cmd == "say" then
        local rest = string.match(rawBody, "^%s*[Ss][Aa][Yy]%s+(.*)$")
        sayMsg = rest
    end

    if cmd == "void" then cmdVoid()
    elseif cmd == "call" or cmd == "come" then cmdCall()
    elseif cmd == "track" or cmd == "follow" then cmdTrack()
    elseif cmd == "air" or cmd == "float" or cmd == "summon" then cmdAir(a1)
    elseif cmd == "pos" or cmd == "slot" then cmdPos(a1)
    elseif cmd == "arm" then cmdArm()
    elseif cmd == "unarm" then cmdUnarm()
    -- combat shortcuts
    elseif cmd == "d" or cmd == "knock" or cmd == "k" then cmdKnock(a1)
    elseif cmd == "b" or cmd == "bring" then cmdBring(a1)
    elseif cmd == "s" or cmd == "stomp" then cmdStomp(a1)
    elseif cmd == "l" or cmd == "loopkill" then cmdLoopKill(a1, false)
    elseif cmd == "lk" then cmdLoopKnock(a1)
    elseif cmd == "lkk" then cmdLoopKill(a1, true)
    elseif cmd == "knife" then cmdKnife(a1)
    elseif cmd == "unlk" or cmd == "unloopkill" or cmd == "unl" then cmdUnLoopKill()
    -- protection
    elseif cmd == "sentry" then cmdSentry(a1)
    elseif cmd == "sentry2" then cmdSentry2(a1)
    elseif cmd == "bsentry" then cmdBSentry(a1)
    elseif cmd == "assist" then cmdAssist(a1)
    elseif cmd == "unassist" then cmdUnassist()
    elseif cmd == "say" then cmdSay(sayMsg or "")
    elseif cmd == "sweep" then cmdSweep()
    elseif cmd == "unsweep" or cmd == "stopsweep" then cmdUnSweep()
    elseif cmd == "protect" or cmd == "prot" then cmdProtect(a1)
    elseif cmd == "unprotect" or cmd == "unprot" then cmdUnprotect()
    elseif cmd == "wl" or cmd == "whitelist" then cmdWL(a1)
    elseif cmd == "uwl" or cmd == "unwhitelist" then cmdUWL(a1)
    elseif cmd == "target" or cmd == "t" then cmdTarget(a1)
    elseif cmd == "untarget" or cmd == "unt" then cmdUntarget()
    elseif cmd == "armor" then cmdArmor()
    elseif cmd == "mask" then cmdMask()
    elseif cmd == "reload" then
        reloadGun(findGun())
        notify("Reload")
    elseif cmd == "autoreload" then
        State.AutoReload = not State.AutoReload
        notify("AutoReload " .. (State.AutoReload and "ON" or "OFF"))
    elseif cmd == "fix" then cmdFix()
    elseif cmd == "kick" or cmd == "rejoin" then cmdKick()
    elseif cmd == "help" or cmd == "cmds" then cmdHelp()
    end
end

local function hookPlayerChat(plr)
    pcall(function()
        plr.Chatted:Connect(function(msg)
            onControlChat(msg, plr)
        end)
    end)
end

for _, plr in ipairs(Players:GetPlayers()) do
    hookPlayerChat(plr)
end
Players.PlayerAdded:Connect(hookPlayerChat)

pcall(function()
    local tcs = game:GetService("TextChatService")
    if not tcs then return end
    tcs.MessageReceived:Connect(function(message)
        local src = message.TextSource
        if not src then return end
        local plr = Players:GetPlayerByUserId(src.UserId)
        if plr then onControlChat(message.Text, plr) end
    end)
end)

----------------------------------------------------------------------
-- MAIN LOOP
----------------------------------------------------------------------
Connections.Main = RunService.Heartbeat:Connect(function()
    if IsOwner then return end
    if not State.KnifeBusy and not State.LoopKillBusy and not State.Sweep
        and not State.LoopKill and not State.LoopKnock and not State.SentryBusy then
        followOwner()
    end
    autoReloadTick()

    -- LoopKnock: shoot only, no stomp
    if State.LoopKnock and not State.LoopKillBusy and not State.KnifeBusy then
        local hum = getHum()
        if hum and hum.Health <= 0 then return end
        local lk = findPlayer(State.LoopKnock)
        if not lk then return end
        if isProtected(lk) then
            notify("LoopKnock stopped: protected " .. lk.Name)
            State.LoopKnock = nil
            State.Tracking = true
            return
        end
        State.LoopKillBusy = true
        task.spawn(function()
            local ok, err = pcall(function()
                if isAlive(lk) then
                    setCamlock(lk, 2)
                    shootTarget(lk)
                    task.wait(0.4)
                else
                    task.wait(0.5)
                end
            end)
            if not ok then warn("[Stand] LoopKnock error:", err) end
            State.LoopKillBusy = false
            if not State.LoopKnock and not IsOwner then
                State.Tracking = true
                clearCamlock()
            end
        end)
    end

    -- LoopKill: single-flight worker (never stack shootTarget every frame)
    if State.LoopKill and not State.LoopKillBusy and not State.KnifeBusy then
        local hum = getHum()
        if hum and hum.Health <= 0 then return end
        local name = State.LoopKill
        local lk = findPlayer(name)
        if not lk then
            return
        end
        local prot = isProtected(lk)
        if prot then
            notify("LoopKill stopped: protected " .. lk.Name)
            State.LoopKill = nil
            State.LoopKillBusy = false
            State.Tracking = true
            return
        end

        State.LoopKillBusy = true
        task.spawn(function()
            local ok, err = pcall(function()
                if isKO(lk) then
                    stompTarget(lk, 5)
                    local t0 = tick()
                    while tick() - t0 < 4 and State.LoopKill do
                        if not getChar(lk) then break end
                        if isAlive(lk) then break end
                        task.wait(0.25)
                    end
                    task.wait(0.4)
                elseif isAlive(lk) then
                    setCamlock(lk, 2)
                    loopKillCycle(lk)
                    task.wait(0.35)
                else
                    task.wait(0.5)
                end
            end)
            if not ok then
                warn("[Stand] LoopKill error:", err)
            end
            State.LoopKillBusy = false
            if not State.LoopKill and not IsOwner then
                State.Tracking = true
                clearCamlock()
            end
        end)
    end
end)

----------------------------------------------------------------------
-- SENTRY HEALTH WATCH (shot detection)
----------------------------------------------------------------------
task.spawn(function()
    while true do
        pcall(refreshSentryWatches)
        task.wait(1.5)
    end
end)

LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(1)
    hookToolWatch(char)
    pcall(refreshSentryWatches)
    if Config.AutoArmor then buyArmor() end
    if Config.ArmorMax or Config.Inf then applyArmorMax() end
    if Config.AutoMask then buyMask() end
    if Config.Muscle then applyMuscle() end
    if not State.Armed and not isHoldingTool() then
        applyIdleAnim()
    else
        stopIdleAnim()
    end
end)

-- Initial character (already spawned)
task.spawn(function()
    local t0 = tick()
    while tick() - t0 < 8 do
        if getHum() then
            task.wait(0.8)
            local c = getChar()
            hookToolWatch(c)
            pcall(refreshSentryWatches)
            if not State.Armed and not isHoldingTool() then
                applyIdleAnim()
            end
            break
        end
        task.wait(0.25)
    end
end)

startAutoPerks()
pcall(ensureSilentAim)

print("[Stand] Main v2 loaded |", IsOwner and "OWNER" or ("ALT slot " .. tostring(MySlot)),
    "| prefix", Prefix, "| owner", OwnerName, "| anim", tostring(Config.Anim or "none"))
notify(IsOwner and "Owner ready" or ("Alt slot " .. tostring(MySlot)))
