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
    CombatActive  = false, -- true during knock/stomp/loop/etc
    HoverHeight   = 4,     -- studs above target while attacking (lower = more reliable hits)
    VoidEat       = false, -- void + eat while combat to avoid dying
}

local Whitelist    = {}
local Connections  = {}
local CamTarget    = nil
local CamlockUntil = 0
local lastChatMsg, lastChatAt = "", 0
local HealthWatch  = {} -- [userId] = lastHealth (sentry)
local KoWatch      = {} -- [userId] = wasKO
local ArmorWatch   = {} -- [userId] = last armor value
local LastSentryAt = 0

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

    -- keep mouse remotes on target while locked (no HRP twist — fights hover/stomp and errors gun clients)
    -- throttle fireMouse on Hood Customs to avoid client red errors from remote spam
    local lastMouseFire = 0
    RunService.RenderStepped:Connect(function()
        local plr = AimLockPlayer
        if not plr then return end
        if not getChar(plr) then return end
        local aim = getAimPos(plr)
        if not aim then return end
        local now = tick()
        local interval = IsHoodCustoms and 0.08 or 0.0
        if now - lastMouseFire >= interval then
            lastMouseFire = now
            pcall(function() fireMouse(aim) end)
        end
        pcall(function()
            if Camera and Camera.CameraType ~= Enum.CameraType.Scriptable then
                Camera.CFrame = CFrame.new(Camera.CFrame.Position, aim)
            end
        end)
        -- do NOT rotate local HRP here — hoverOverTarget / stomp already set full CFrame
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
    -- Hood Customs client scripts error (red text) on fake Hit/Knife/Punch remotes
    if IsHoodCustoms then return end
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

local lastCamMouseFire = 0
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
    local now = tick()
    local interval = IsHoodCustoms and 0.08 or 0.0
    if now - lastCamMouseFire >= interval then
        lastCamMouseFire = now
        pcall(function() fireMouse(aim) end)
    end
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

-- COMBAT: STRAFE + VOID EAT
----------------------------------------------------------------------
local FOOD_NAMES = {
    "chicken", "pizza", "taco", "hotdog", "burger", "hamburger", "food", "apple",
    "meat", "sandwich", "fries", "donut", "cake", "bread", "cheese",
    "lettuce", "crap", "popcorn", "krab", "latte", "starblox", "noodles",
    "bagel", "cookie", "soda", "water", "milk", "juice", "candy",
}

local function isFoodName(name)
    local n = string.lower(tostring(name or ""))
    for _, key in ipairs(FOOD_NAMES) do
        if n:find(key, 1, true) then return true end
    end
    return false
end

local function findFood()
    local c = getChar()
    local bag = LocalPlayer:FindFirstChild("Backpack")
    for _, container in ipairs({c, bag}) do
        if container then
            for _, t in ipairs(container:GetChildren()) do
                if t:IsA("Tool") and isFoodName(t.Name) then
                    return t
                end
            end
        end
    end
    return nil
end

-- Auto-buy food from shop if none in inventory (Da Hood / hood-style places)
local function buyFood()
    -- 1) remote spam (works on some places without needing shop)
    if MainEvent then
        for _, n in ipairs({
            "BuyChicken", "BuyPizza", "BuyTaco", "BuyHotdog", "BuyBurger",
            "Chicken", "Pizza", "Taco", "Food", "BuyFood",
        }) do
            pcall(function() MainEvent:FireServer(n) end)
            pcall(function() MainEvent:FireServer("Buy", n) end)
        end
    end

    -- 2) click shop food pads under Workspace.Ignored.Shop (classic Da Hood)
    pcall(function()
        local shop = Workspace:FindFirstChild("Ignored")
        shop = shop and shop:FindFirstChild("Shop")
        if not shop then
            -- other hood games
            shop = Workspace:FindFirstChild("Shop")
                or (Workspace:FindFirstChild("MAP") and Workspace.MAP:FindFirstChild("Shop"))
        end
        if not shop then return end

        local my = getHRP()
        local savedCF = my and my.CFrame

        for _, m in ipairs(shop:GetDescendants()) do
            if not isFoodName(m.Name) then continue end
            local cd = m:IsA("ClickDetector") and m or m:FindFirstChildWhichIsA("ClickDetector", true)
            local part = m:IsA("BasePart") and m or m:FindFirstChildWhichIsA("BasePart", true)
            if cd then
                -- teleport next to pad so server accepts click
                if part and my then
                    pcall(function()
                        my.CFrame = part.CFrame * CFrame.new(0, 3, 0)
                        my.AssemblyLinearVelocity = Vector3.zero
                    end)
                    task.wait(0.05)
                end
                if fireclickdetector then
                    pcall(function() fireclickdetector(cd) end)
                    pcall(function() fireclickdetector(cd, 1) end)
                end
                pcall(function()
                    if firetouchinterest and part and my then
                        firetouchinterest(my, part, 0)
                        task.wait(0.05)
                        firetouchinterest(my, part, 1)
                    end
                end)
                task.wait(0.08)
                if findFood() then break end
            end
        end

        -- return to void / previous pos
        if my then
            pcall(function()
                if State.InVoid or State.VoidEat then
                    my.CFrame = VoidCF
                elseif savedCF then
                    my.CFrame = savedCF
                end
                my.AssemblyLinearVelocity = Vector3.zero
            end)
        end
    end)

    task.wait(0.15)
    return findFood() ~= nil
end

local function fireEatRemotes(food)
    if not MainEvent then return end
    pcall(function() MainEvent:FireServer("Eat", food) end)
    pcall(function() MainEvent:FireServer("Eat") end)
    pcall(function() MainEvent:FireServer("Eating") end)
    pcall(function() MainEvent:FireServer("Eating", food) end)
    if food then
        pcall(function() MainEvent:FireServer("Eat", food.Name) end)
        -- Da Hood sometimes wants the tool as 2nd arg with string first
        pcall(function() MainEvent:FireServer("Eat", food, food) end)
    end
    if UnreliableMainEvent then
        pcall(function() UnreliableMainEvent:FireServer("Eat", food) end)
        pcall(function() UnreliableMainEvent:FireServer("Eat") end)
    end
end

local function eatFood()
    local food = findFood()
    -- never shop-TP while already void-healing (yanks character out)
    if not food and not State.VoidEat then
        buyFood()
        food = findFood()
    end
    if food then
        -- longer equip timeout in void (character state can be weird)
        food = equipTool(food, State.VoidEat and 0.9 or 0.45)
        if food then
            for _ = 1, 12 do
                if State.VoidEat then
                    pinToVoid()
                end
                pcall(function()
                    food:Activate()
                end)
                activateTool(food)
                fireEatRemotes(food)
                -- click simulation helps some places
                pcall(function()
                    local vim = game:GetService("VirtualInputManager")
                    if vim then
                        vim:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                        task.wait(0.02)
                        vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
                    end
                end)
                pcall(function()
                    local vu = game:GetService("VirtualUser")
                    if vu then
                        vu:ClickButton1(Vector2.new(0, 0))
                    end
                end)
                task.wait(0.08)
            end
            return true
        end
    end
    -- no tool — still spam eat/buy remotes
    fireEatRemotes(nil)
    if MainEvent then
        for _, n in ipairs({
            "BuyChicken", "BuyPizza", "BuyTaco", "BuyHamburger", "BuyDonut",
            "Chicken", "Pizza", "Taco", "Hamburger", "Donut",
        }) do
            pcall(function() MainEvent:FireServer(n) end)
            pcall(function() MainEvent:FireServer("Buy", n) end)
        end
    end
    return false
end

-- Focused void heal: buy if needed, equip food, eat hard while pinned
local function getLocalBlood()
    local c = getChar()
    if not c then return nil end
    local be = c:FindFirstChild("BodyEffects")
    if not be then return nil end
    for _, name in ipairs({"Blood", "Health", "HP"}) do
        local v = be:FindFirstChild(name)
        if v and (v:IsA("NumberValue") or v:IsA("IntValue")) then
            return v.Value, v
        end
    end
    return nil
end

local function getLocalHurt()
    -- Prefer BodyEffects blood; fall back to Humanoid + KO
    local blood = getLocalBlood()
    if blood ~= nil and blood < 90 then return true end
    local hum = getHum()
    if not hum then return true end
    if hum.Health < hum.MaxHealth * 0.9 then return true end
    if isKO(LocalPlayer) then return true end
    return false
end

local VoidRecoverUntil = 0
local VoidMinUntil = 0       -- hard minimum time in void before any exit
local VoidBloodAtEnter = nil -- blood snapshot when we entered (ignore client writes)
local _voidEnterBusy = false
local _lastVoidEatAt = 0
local _voidCooldownUntil = 0 -- prevent instant re-void after exit

local function pinToVoid()
    local hrp = getHRP()
    if not hrp then return end
    pcall(function()
        local ch = getChar()
        if ch and ch.PivotTo then
            ch:PivotTo(VoidCF)
        end
        hrp.CFrame = VoidCF
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)
    pcall(function()
        local h = getHum()
        if h then
            h.PlatformStand = false
            h.Sit = false
            -- keep upright so tools can equip
            if h:GetState() == Enum.HumanoidStateType.Physics
                or h:GetState() == Enum.HumanoidStateType.Ragdoll then
                h:ChangeState(Enum.HumanoidStateType.GettingUp)
            end
        end
    end)
end

local function startVoidPinRender()
    pcall(function()
        RunService:UnbindFromRenderStep("StandVoidPin")
        RunService:BindToRenderStep("StandVoidPin", Enum.RenderPriority.Camera.Value - 1, function()
            if not State.VoidEat then return end
            pinToVoid()
        end)
    end)
end

local function voidHealBurst()
    if not State.VoidEat then return end
    pinToVoid()

    if not findFood() then
        -- remote-buy first (no TP)
        if MainEvent then
            for _, n in ipairs({
                "BuyChicken", "BuyPizza", "BuyTaco", "BuyHamburger", "BuyDonut",
                "Chicken", "Pizza", "Taco", "Hamburger", "Donut", "Food", "BuyFood",
            }) do
                pcall(function() MainEvent:FireServer(n) end)
                pcall(function() MainEvent:FireServer("Buy", n) end)
            end
        end
        task.wait(0.2)
        pinToVoid()
        -- if still no food, brief shop trip then back to void
        if not findFood() then
            pcall(buyFood)
            pinToVoid()
            task.wait(0.15)
            pinToVoid()
        end
    end

    for _ = 1, 6 do
        if not State.VoidEat then break end
        pinToVoid()
        eatFood()
        pinToVoid()
        task.wait(0.1)
    end
end

local function enterCombatVoid()
    if State.VoidEat then
        pinToVoid()
        return
    end
    State.InVoid = true
    State.VoidEat = true
    State.Tracking = false
    _voidEnterBusy = true
    local now = tick()
    VoidRecoverUntil = now + 4.5   -- max time in void then forced return
    VoidMinUntil = now + 2.0      -- MUST stay long enough to buy + eat
    VoidBloodAtEnter = getLocalBlood()

    clearCamlock()
    clearAimLock()
    startVoidPinRender()
    pinToVoid()

    pcall(function()
        local h = getHum()
        if h then
            h.PlatformStand = false
            h.Sit = false
            h:ChangeState(Enum.HumanoidStateType.GettingUp)
            h:ChangeState(Enum.HumanoidStateType.Running)
            h:UnequipTools()
        end
    end)

    pinToVoid()

    -- dedicated void heal: buy + equip + eat while pinned
    pcall(voidHealBurst)
    pinToVoid()
end

local function getCombatReturnCF()
    -- Prefer current fight target, else owner formation
    local targetName = State.LoopKill or State.LoopKnock or State.TargetName
    if targetName then
        local plr = findPlayer(targetName)
        local their = plr and getHRP(plr)
        if their then
            return their.CFrame * CFrame.new(0, 2, 6)
        end
    end
    local owner = getOwner()
    local oHRP = owner and getHRP(owner)
    if oHRP then
        local offset = SLOT_CF[MySlot] or SLOT_CF[2]
        return oHRP.CFrame * offset
    end
    -- last resort: above origin so we leave void coords
    return CFrame.new(0, 50, 0)
end

local function warpOutOfVoid()
    local cf = getCombatReturnCF()
    for _ = 1, 8 do
        if State.VoidEat then return end
        pcall(function()
            local h = getHum()
            if h then
                h.PlatformStand = false
                h.Sit = false
                h:ChangeState(Enum.HumanoidStateType.GettingUp)
                h:ChangeState(Enum.HumanoidStateType.Running)
            end
            local hrp = getHRP()
            local ch = getChar()
            if ch and ch.PivotTo then
                ch:PivotTo(cf)
            end
            if hrp then
                hrp.CFrame = cf
                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
            end
        end)
        task.wait(0.03)
    end
end

local function exitCombatVoid()
    State.InVoid = false
    State.VoidEat = false
    VoidRecoverUntil = 0
    VoidMinUntil = 0
    VoidBloodAtEnter = nil
    _voidEnterBusy = false
    _voidCooldownUntil = tick() + 1.25 -- don't re-void immediately
    pcall(function()
        RunService:UnbindFromRenderStep("StandVoidPin")
    end)

    -- MUST leave void coordinates or stand stays stuck under map / in sky
    task.spawn(function()
        warpOutOfVoid()
    end)

    pcall(function()
        local h = getHum()
        if h then
            h.PlatformStand = false
            h.Sit = false
            h:ChangeState(Enum.HumanoidStateType.GettingUp)
            h:ChangeState(Enum.HumanoidStateType.Running)
        end
    end)

    -- Resume combat if still fighting, otherwise return to owner
    if State.CombatActive and (State.LoopKill or State.LoopKnock or State.SentryBusy) then
        State.Tracking = false
        State.LoopKillBusy = false -- allow loop worker to start again
        notify("Combat resume")
    elseif State.CombatActive then
        State.Tracking = false
        notify("Combat resume")
    else
        State.Tracking = true
        notify("Healed — back")
        task.spawn(function()
            task.wait(0.1)
            if not State.CombatActive and not State.VoidEat then
                pcall(returnToOwner)
            end
        end)
    end
end

-- Hover above target (slight offset so gun rays aren't pure vertical — pure top-down breaks many hood gun clients)
local function hoverOverTarget(plr, height)
    if State.VoidEat or State.InVoid then return end
    height = height or State.HoverHeight or 4
    local my = getHRP()
    local their = getHRP(plr)
    if not my or not their then return end
    local aim = getAimPos(plr) or their.Position
    -- small horizontal offset so camera/gun ray has a clean angle (avoids client ray errors)
    -- Hood Customs is stricter about pure vertical rays — use a bit more offset
    local ox = IsHoodCustoms and 0.65 or 0.35
    local targetPos = their.Position + Vector3.new(ox, height, ox)
    pcall(function()
        local look = Vector3.new(aim.X, their.Position.Y + 1.2, aim.Z)
        local cf = CFrame.new(targetPos, look)
        local ch = getChar()
        if ch and ch.PivotTo then
            ch:PivotTo(cf)
        end
        my.CFrame = cf
        my.AssemblyLinearVelocity = Vector3.zero
        my.AssemblyAngularVelocity = Vector3.zero
    end)
end

local function beginCombat()
    State.CombatActive = true
    -- do NOT clear VoidEat — if already recovering from a shot, keep healing
end

local function endCombat()
    State.CombatActive = false
    State.VoidEat = false
    State.InVoid = false
    VoidRecoverUntil = 0
    VoidMinUntil = 0
    VoidBloodAtEnter = nil
    _voidEnterBusy = false
    pcall(function()
        RunService:UnbindFromRenderStep("StandVoidPin")
    end)
end

-- If shot during combat → void + eat, then ALWAYS leave void and resume combat
local function combatSurviveTick()
    if IsOwner then return end

    -- CRITICAL: always process void recovery even if CombatActive became false,
    -- otherwise the stand gets permanently stuck in void.
    if State.VoidEat then
        pinToVoid()

        -- keep eating while voided
        if tick() - _lastVoidEatAt >= 0.55 then
            _lastVoidEatAt = tick()
            pcall(function()
                if findFood() then
                    eatFood()
                else
                    -- remote buy only (no shop TP from heartbeat)
                    if MainEvent then
                        for _, n in ipairs({
                            "BuyChicken", "BuyPizza", "BuyTaco", "BuyHamburger",
                            "Chicken", "Pizza", "Taco", "Hamburger", "Eat", "Eating",
                        }) do
                            pcall(function() MainEvent:FireServer(n) end)
                            pcall(function() MainEvent:FireServer("Buy", n) end)
                        end
                    end
                    fireEatRemotes(nil)
                end
            end)
            pinToVoid()
        end

        local now = tick()
        -- safety: if timers were wiped, force exit soon
        if VoidMinUntil == 0 then VoidMinUntil = now + 1.0 end
        if VoidRecoverUntil == 0 then VoidRecoverUntil = now + 2.5 end

        local minDone = now >= VoidMinUntil
        local maxDone = now >= VoidRecoverUntil

        -- Healed = no longer hurt (blood/hp recovered or full health bar)
        local healed = false
        if minDone then
            if not getLocalHurt() then
                healed = true
            else
                local blood = getLocalBlood()
                if blood ~= nil and blood >= 95 then
                    healed = true
                end
                local hum = getHum()
                if hum and not isKO(LocalPlayer) and hum.Health >= hum.MaxHealth * 0.92 then
                    healed = true
                end
            end
        end

        if (minDone and healed) or maxDone then
            exitCombatVoid()
        end
        return
    end

    -- Auto void-heal on shot DISABLED — stand no longer TPs to void when damaged
    -- (manual .heal still works via cmdHeal)
    -- if not State.CombatActive then return end
    -- if getLocalHurt() and not _voidEnterBusy and tick() >= _voidCooldownUntil then
    --     ...
    -- end
end

-- COMBAT: SHOOT
----------------------------------------------------------------------
local function shootTarget(plr)
    if not plr or isProtected(plr) or not isAlive(plr) then return end
    if State.InVoid and not State.VoidEat then State.InVoid = false end
    if State.VoidEat then
        -- wait for heal void to finish (up to recover window), don't force-exit early
        local t0 = tick()
        while State.VoidEat and tick() - t0 < 4 do task.wait(0.1) end
        if State.VoidEat then
            exitCombatVoid()
        end
    end

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

    hoverOverTarget(plr)
    reloadGun(gun)
    task.wait(0.1)

    for shot = 1, 14 do
        if not isAlive(plr) or isKO(plr) then break end
        -- if we got voided mid-fight, wait and resume
        if State.VoidEat or State.InVoid then
            local t0 = tick()
            while (State.VoidEat or State.InVoid) and tick() - t0 < 4 do
                task.wait(0.1)
            end
            if State.VoidEat or State.InVoid then
                exitCombatVoid()
            end
            gun = equipTool(findGun(), 0.5)
            if not gun then break end
            setAimLock(plr)
            setCamlock(plr, 3)
        end
        if gun.Parent ~= getChar() then
            gun = equipTool(findGun(), 0.5)
            if not gun then break end
        end

        hoverOverTarget(plr)
        local aim = getAimPos(plr)
        if not aim then break end

        -- mouse pos only (legitimate path) — no fake "Shoot"/"Hit" remotes (cause red client errors on Hood Customs)
        pcall(function() fireMouse(aim) end)
        pcall(function()
            local be = getChar() and getChar():FindFirstChild("BodyEffects")
            local mp = be and be:FindFirstChild("MousePos")
            if mp and mp:IsA("Vector3Value") then mp.Value = aim end
        end)

        pcall(function()
            if Camera and Camera.CameraType ~= Enum.CameraType.Scriptable then
                Camera.CFrame = CFrame.new(Camera.CFrame.Position, aim)
            end
        end)

        activateTool(gun)

        pcall(function()
            local vim = game:GetService("VirtualInputManager")
            if vim then
                vim:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                task.wait(0.025)
                vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
            end
        end)
        -- VirtualUser ClickButton1 can trigger extra client errors on Hood Customs; skip there
        if not IsHoodCustoms then
            pcall(function()
                local vu = game:GetService("VirtualUser")
                if vu then vu:ClickButton1(Vector2.new(0, 0)) end
            end)
        end

        if shot % 5 == 0 then
            reloadGun(gun)
            task.wait(0.1)
        end
        task.wait(IsHoodCustoms and 0.14 or 0.11)
    end

    reloadGun(gun)
end

-- COMBAT: STOMP
----------------------------------------------------------------------
local function stompTarget(plr, times)
    if not plr then return end
    times = times or 16
    State.Tracking = false
    clearAimLock()

    -- unequip so stomp input isn't eaten by gun/tool
    pcall(function()
        local h = getHum()
        if h then h:UnequipTools() end
    end)
    State.Armed = false
    task.wait(0.05)

    for i = 1, times do
        if not getChar(plr) then break end
        -- if they got up and are no longer KO, stop stomping this cycle
        if not isKO(plr) and i > 3 then
            local h = getHum(plr)
            if h and h.Health > 20 then break end
        end

        local my = getHRP()
        local theirChar = getChar(plr)
        local their = getHRP(plr)
        -- prefer UpperTorso for standing on knocked body (HRP can float)
        local standOn = theirChar and (theirChar:FindFirstChild("UpperTorso") or theirChar:FindFirstChild("Torso") or their)
        if my and standOn then
            -- plant feet on chest — classic hood stomp distance
            local pos = standOn.Position + Vector3.new(0, 2.15, 0)
            pcall(function()
                local ch = getChar()
                local cf = CFrame.new(pos)
                if ch and ch.PivotTo then ch:PivotTo(cf) end
                my.CFrame = cf
                my.AssemblyLinearVelocity = Vector3.zero
                my.AssemblyAngularVelocity = Vector3.zero
            end)
        end

        -- ensure upright / not ragdolled ourselves
        pcall(function()
            local h = getHum()
            if h then
                h.PlatformStand = false
                h.Sit = false
                if h:GetState() == Enum.HumanoidStateType.Physics
                    or h:GetState() == Enum.HumanoidStateType.Ragdoll then
                    h:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end
        end)

        -- E key (stomp) — hold a bit longer for server registration
        pcall(function()
            local vim = game:GetService("VirtualInputManager")
            if vim then
                vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                task.wait(0.08)
                vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
            end
        end)
        pcall(function()
            local vu = game:GetService("VirtualUser")
            if vu then
                vu:SetKeyDown("0x45")
                task.wait(0.07)
                vu:SetKeyUp("0x45")
            end
        end)

        -- primary stomp remote only (spam invalid names can trip client/server)
        if MainEvent then
            pcall(function() MainEvent:FireServer("Stomp") end)
            pcall(function() MainEvent:FireServer("Stomp", true) end)
        end
        if UnreliableMainEvent then
            pcall(function() UnreliableMainEvent:FireServer("Stomp") end)
        end

        task.wait(0.12)
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
    beginCombat()
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
        endCombat()
        State.Tracking = true
        returnToOwner()
    end)
end

-- .s — stomp only
local function cmdStomp(user)
    local plr = findPlayer(user)
    if not plr then notify("Stomp: not found") return end
    State.Tracking = false
    beginCombat()
    task.spawn(function()
        stompTarget(plr, 12)
        endCombat()
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
    beginCombat()
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
    beginCombat()
    notify("LoopKnock ON " .. plr.Name)
end

local function cmdUnLoopKill()
    State.LoopKill = nil
    State.LoopKillKnife = false
    State.LoopKnock = nil
    State.LoopKillBusy = false
    endCombat()
    clearCamlock()
    if not IsOwner then State.Tracking = true end
    notify("Loop OFF")
end

local function parseOnOff(arg, current)
    if arg == "on" or arg == "1" or arg == "true" then return true end
    if arg == "off" or arg == "0" or arg == "false" then return false end
    return not current
end

local function baselineSentryPlayer(plr)
    if not plr then return end
    local hum = getHum(plr)
    if not hum then return end
    HealthWatch[plr.UserId] = hum.Health
    KoWatch[plr.UserId] = isKO(plr)
    local armor = 0
    local c = getChar(plr)
    local be = c and c:FindFirstChild("BodyEffects")
    if be then
        for _, name in ipairs({"Armor", "Defence", "Defense", "Helmet", "CurrentArmor"}) do
            local v = be:FindFirstChild(name)
            if v and typeof(v.Value) == "number" then armor = armor + v.Value end
        end
    end
    ArmorWatch[plr.UserId] = armor
end

local function cmdSentry(arg)
    State.Sentry = parseOnOff(arg, State.Sentry)
    if State.Sentry then State.Sentry2 = false end
    local o = getOwner()
    baselineSentryPlayer(o)
    notify("Sentry " .. (State.Sentry and "ON" or "OFF")
        .. " (knock who shoots owner)"
        .. (State.Sentry and (o and (" | owner=" .. o.Name) or " | WARNING: no owner set") or ""))
end

local function cmdSentry2(arg)
    State.Sentry2 = parseOnOff(arg, State.Sentry2)
    if State.Sentry2 then State.Sentry = false end
    local o = getOwner()
    baselineSentryPlayer(o)
    notify("Sentry2 " .. (State.Sentry2 and "ON" or "OFF")
        .. " (knock+stomp who shoots owner)"
        .. (State.Sentry2 and (o and (" | owner=" .. o.Name) or " | WARNING: no owner set") or ""))
end

local BSentryConn = nil
local BSentryCharConn = nil

local function hookBSentryLocal()
    if BSentryConn then pcall(function() BSentryConn:Disconnect() end) BSentryConn = nil end
    if BSentryCharConn then pcall(function() BSentryCharConn:Disconnect() end) BSentryCharConn = nil end
    if not State.BSentry then return end

    local function attach(hum)
        if not hum then return end
        baselineSentryPlayer(LocalPlayer)
        if BSentryConn then pcall(function() BSentryConn:Disconnect() end) end
        local last = hum.Health
        BSentryConn = hum.HealthChanged:Connect(function(hp)
            if not State.BSentry then return end
            if hp < last - 0.5 or isKO(LocalPlayer) then
                last = hp
                -- immediate reaction on local damage (most reliable)
                task.defer(function()
                    if State.SentryBusy then return end
                    onVictimDamaged(LocalPlayer, true)
                end)
            else
                last = hp
            end
        end)
    end

    attach(getHum(LocalPlayer))
    BSentryCharConn = LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.5)
        if State.BSentry then attach(getHum(LocalPlayer)) end
    end)
end

local function cmdBSentry(arg)
    State.BSentry = parseOnOff(arg, State.BSentry)
    baselineSentryPlayer(LocalPlayer)
    hookBSentryLocal()
    notify("BSentry " .. (State.BSentry and "ON" or "OFF") .. " (knock+stomp who shoots stand)")
end

local function cmdAssist(user)
    local plr = findPlayer(user)
    if not plr then notify("Assist: not found") return end
    State.AssistName = plr.Name
    baselineSentryPlayer(plr)
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
    if plr == LocalPlayer then return end
    if not isAlive(plr) and not isKO(plr) then return end
    if State.SentryBusy then return end
    State.SentryBusy = true
    State.Tracking = false
    beginCombat()
    notify("Sentry → " .. plr.Name .. (doStomp and " (stomp)" or ""))
    task.spawn(function()
        local ok, err = pcall(function()
            -- if WE are knocked, try to stand back up so we can shoot
            pcall(function()
                local h = getHum()
                if h and (h.PlatformStand or isKO(LocalPlayer)) then
                    h.PlatformStand = false
                    h:ChangeState(Enum.HumanoidStateType.GettingUp)
                    h:ChangeState(Enum.HumanoidStateType.Running)
                end
            end)
            task.wait(0.05)

            if isKO(plr) and doStomp then
                stompTarget(plr, 14)
            else
                setCamlock(plr, 4)
                setAimLock(plr)
                -- force arm + shoot even if we just took damage
                local gun = findGun()
                if gun then
                    stopIdleAnim()
                    equipTool(gun, 0.5)
                    State.Armed = true
                end
                shootTarget(plr)
                local t0 = tick()
                while tick() - t0 < 2.8 do
                    if isKO(plr) then break end
                    if not getChar(plr) then break end
                    task.wait(0.1)
                end
                if doStomp then
                    if isKO(plr) then
                        stompTarget(plr, 14)
                    else
                        shootTarget(plr)
                        task.wait(0.35)
                        if isKO(plr) then stompTarget(plr, 12) end
                    end
                end
            end
        end)
        if not ok then warn("[Stand] sentryReact:", err) end
        clearAimLock()
        clearCamlock()
        endCombat()
        State.Tracking = true
        returnToOwner()
        task.wait(0.2)
        State.SentryBusy = false
    end)
end

local function resolvePlayerFromValue(val)
    if not val then return nil end
    if typeof(val) == "Instance" then
        if val:IsA("Player") then return val end
        if val:IsA("Model") then return Players:GetPlayerFromCharacter(val) end
        if val:IsA("ObjectValue") and val.Value then
            return resolvePlayerFromValue(val.Value)
        end
    elseif type(val) == "string" then
        return findPlayer(val)
    elseif type(val) == "number" then
        return Players:GetPlayerByUserId(val)
    end
    return nil
end

-- Find who most likely shot `victim`
local function findAttacker(victim)
    if not victim then return nil end
    local char = getChar(victim)
    local hum = getHum(victim)

    -- 1) Creator / attacker tags on humanoid & character
    if hum then
        for _, inst in ipairs(hum:GetChildren()) do
            local n = string.lower(inst.Name)
            if n:find("creat") or n:find("attack") or n:find("kill") or n:find("hit") or n:find("shoot") then
                local p = resolvePlayerFromValue(inst.Value or inst)
                if p and p ~= victim and p ~= LocalPlayer and not isProtected(p) then return p end
            end
        end
    end
    if char then
        local be = char:FindFirstChild("BodyEffects")
        if be then
            for _, inst in ipairs(be:GetDescendants()) do
                local n = string.lower(inst.Name)
                if n:find("creat") or n:find("attack") or n:find("kill") or n:find("shoot") or n:find("last") then
                    local p = resolvePlayerFromValue(inst.Value)
                    if p and p ~= victim and p ~= LocalPlayer and not isProtected(p) then return p end
                end
            end
        end
        for _, inst in ipairs(char:GetChildren()) do
            local n = string.lower(inst.Name)
            if n:find("creat") or n:find("attack") then
                local p = resolvePlayerFromValue(inst.Value)
                if p and p ~= victim and p ~= LocalPlayer and not isProtected(p) then return p end
            end
        end
    end

    -- 2) Player looking at victim with a gun equipped (most reliable fallback)
    local vHRP = getHRP(victim)
    if not vHRP then return nil end
    local best, bestScore = nil, -1
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
                    local dist = (hrp.Position - vHRP.Position).Magnitude
                    if dist < 120 then
                        local look = hrp.CFrame.LookVector
                        local toVic = (vHRP.Position - hrp.Position)
                        if toVic.Magnitude > 0.5 then
                            local dot = look:Dot(toVic.Unit)
                            -- prefer players facing the victim + closer
                            local score = dot * 2 - (dist / 120)
                            if dot > 0.35 and score > bestScore then
                                bestScore = score
                                best = plr
                            end
                        end
                    end
                end
            end
        end
    end
    if best then return best end

    -- 3) Closest armed player within range
    local closest, closestD = nil, 70
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
                    if d < closestD then
                        closestD = d
                        closest = plr
                    end
                end
            end
        end
    end
    return closest
end

local function readArmor(plr)
    local c = getChar(plr)
    if not c then return 0 end
    local be = c:FindFirstChild("BodyEffects")
    if not be then return 0 end
    local sum = 0
    for _, name in ipairs({"Armor", "Defence", "Defense", "Helmet", "CurrentArmor"}) do
        local v = be:FindFirstChild(name)
        if v and typeof(v.Value) == "number" then
            sum = sum + v.Value
        end
    end
    return sum
end

local function onVictimDamaged(victim, doStomp)
    if State.SentryBusy then return end
    if tick() - LastSentryAt < 0.45 then return end
    local attacker = findAttacker(victim)
    if not attacker then
        -- last resort: any armed player within 100 studs of victim
        local vHRP = getHRP(victim)
        if vHRP then
            local best, bestD = nil, 100
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= victim and plr ~= LocalPlayer and not isProtected(plr) and isAlive(plr) then
                    local hrp = getHRP(plr)
                    local ch = getChar(plr)
                    if hrp and ch then
                        local armed = false
                        for _, c in ipairs(ch:GetChildren()) do
                            if c:IsA("Tool") then armed = true break end
                        end
                        if armed then
                            local d = (hrp.Position - vHRP.Position).Magnitude
                            if d < bestD then bestD = d best = plr end
                        end
                    end
                end
            end
            attacker = best
        end
    end
    if attacker then
        LastSentryAt = tick()
        sentryReact(attacker, doStomp)
    else
        notify("Sentry: damage on " .. (victim and victim.Name or "?") .. " — no shooter found")
    end
end

-- Multi-signal poll: health, KO, armor (Da Hood style)
local function sentryTick()
    if IsOwner then return end
    if State.SentryBusy then return end
    if not (State.Sentry or State.Sentry2 or State.BSentry) then return end

    local function check(plr, doStomp)
        if not plr then return end
        local hum = getHum(plr)
        local char = getChar(plr)
        if not hum or not char then return end
        local key = plr.UserId

        local hp = hum.Health
        local prevHp = HealthWatch[key]
        local knocked = isKO(plr)
        local wasKO = KoWatch[key]
        local armor = readArmor(plr)
        local prevArmor = ArmorWatch[key]

        if prevHp == nil then
            HealthWatch[key] = hp
            KoWatch[key] = knocked
            ArmorWatch[key] = armor
            return
        end

        local hit = false
        -- 1) health dropped
        if hp < prevHp - 0.5 then hit = true end
        -- 2) just got knocked
        if knocked and not wasKO then hit = true end
        -- 3) armor/defense dropped (hood games)
        if prevArmor ~= nil and armor < prevArmor - 1 then hit = true end

        HealthWatch[key] = hp
        KoWatch[key] = knocked
        ArmorWatch[key] = armor

        if hit then
            onVictimDamaged(plr, doStomp)
        end
    end

    local owner = getOwner()
    if owner and (State.Sentry or State.Sentry2) then
        check(owner, State.Sentry2 and true or false)
    end
    if State.BSentry then
        check(LocalPlayer, true)
    end
    if State.AssistName and (State.Sentry or State.Sentry2 or State.BSentry) then
        local ap = findPlayer(State.AssistName)
        if ap then
            check(ap, (State.Sentry2 or State.BSentry) and true or false)
        end
    end
end

local function refreshSentryWatches()
    local function baseline(plr)
        if not plr then return end
        local hum = getHum(plr)
        if not hum then return end
        HealthWatch[plr.UserId] = hum.Health
        KoWatch[plr.UserId] = isKO(plr)
        ArmorWatch[plr.UserId] = readArmor(plr)
    end
    baseline(getOwner())
    baseline(LocalPlayer)
    if State.AssistName then
        baseline(findPlayer(State.AssistName))
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

local function cmdBuyFood()
    State.Tracking = false
    notify("Buying food...")
    task.spawn(function()
        local ok, err = pcall(function()
            local had = findFood() ~= nil
            if not had then
                buyFood()
            end
            task.wait(0.25)
            if findFood() then
                notify("Food ready: " .. tostring(findFood().Name))
            else
                -- one more remote-only attempt
                if MainEvent then
                    for _, n in ipairs({
                        "BuyChicken", "BuyPizza", "BuyTaco", "BuyHamburger", "BuyDonut",
                        "Chicken", "Pizza", "Taco", "Hamburger", "Donut",
                    }) do
                        pcall(function() MainEvent:FireServer(n) end)
                        pcall(function() MainEvent:FireServer("Buy", n) end)
                    end
                end
                task.wait(0.3)
                if findFood() then
                    notify("Food ready: " .. tostring(findFood().Name))
                else
                    notify("No food — try near shop")
                end
            end
        end)
        if not ok then warn("[Stand] buyfood:", err) end
        if not State.CombatActive and not State.VoidEat then
            State.Tracking = true
            returnToOwner()
        end
    end)
end

local function cmdHeal()
    if State.VoidEat then
        notify("Already healing")
        return
    end
    notify("Heal — void + eat")
    State.Tracking = false
    task.spawn(function()
        local ok, err = pcall(function()
            -- force combat-void style heal even outside combat
            local wasCombat = State.CombatActive
            State.CombatActive = true
            enterCombatVoid()
            -- wait until void heal finishes (exitCombatVoid clears VoidEat)
            local t0 = tick()
            while State.VoidEat and tick() - t0 < 6 do
                task.wait(0.15)
            end
            if State.VoidEat then
                exitCombatVoid()
            end
            if not wasCombat then
                State.CombatActive = false
            end
            -- ensure out of void and near owner/target
            warpOutOfVoid()
            if not State.CombatActive then
                State.Tracking = true
                returnToOwner()
            end
            notify("Heal done")
        end)
        if not ok then
            warn("[Stand] heal:", err)
            pcall(exitCombatVoid)
            State.Tracking = true
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
    print("  " .. Prefix .. "armor / mask / buyfood / heal")
    print("  " .. Prefix .. "reload / autoreload / fix / kick / help")
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
    elseif cmd == "buyfood" or cmd == "food" or cmd == "bf" then cmdBuyFood()
    elseif cmd == "heal" or cmd == "eat" then cmdHeal()
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
    pcall(sentryTick)
    pcall(combatSurviveTick)

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
