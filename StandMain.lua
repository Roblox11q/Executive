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

local F = {}

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

-- All stands / alts / owner / controllers — never target each other
local StandTeam = {}
do
    local function addName(n)
        if type(n) ~= "string" then return end
        n = string.lower(n:gsub("%s+", ""))
        if n ~= "" then StandTeam[n] = true end
    end
    addName(OwnerName)
    addName(LocalPlayer.Name)
    for name in pairs(Controllers) do
        addName(name)
    end
    local alts = Config.Alts or {}
    if type(alts) == "table" then
        for k, v in pairs(alts) do
            -- Alts = { ["User1"] = 1, ["User2"] = 2 } or { "User1", "User2" }
            if type(k) == "string" then addName(k) end
            if type(v) == "string" then addName(v) end
        end
    end
    -- optional explicit list
    local team = Config.StandTeam or Config.Team or Config.Stands
    if type(team) == "table" then
        for k, v in pairs(team) do
            if type(k) == "string" then addName(k) end
            if type(v) == "string" then addName(v) end
            if type(k) == "number" and type(v) == "string" then addName(v) end
        end
    end
end

function F.isStandTeam(plr)
    if not plr then return false end
    local n = string.lower(plr.Name)
    if StandTeam[n] then return true end
    -- also match display name if username was listed under a display-style key
    local d = string.lower(plr.DisplayName or "")
    if d ~= "" and StandTeam[d] then return true end
    return false
end

do
    local pid = game.PlaceId
    local daHoodStyle = (pid == 2788229376 or pid == 16033173781
        or pid == 96247461091106 or pid == 128413479081937
        or pid == 105240105208766 or pid == 77582891937348
        or pid == 76755883806632 or pid == 98074214215906
        or pid == 17895262040)
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
-- Der / Des Hood family (multiple clones share similar AC + gun systems)
local IsDersHood    = (PlaceId == 96247461091106   -- DERS HOOD
    or PlaceId == 128413479081937                  -- Des Hood
    or PlaceId == 105240105208766                  -- DERS H00D
    or PlaceId == 77582891937348                   -- DERS H00D UPD
    or PlaceId == 76755883806632                   -- [LOL] DER H00D
    or PlaceId == 98074214215906                   -- TELEPORT HUB DER H00D
    or PlaceId == 17895262040)                     -- Der Hood Flame
local IsHoodCustoms = (PlaceId == 9825515356)
local IsDaHoodStyle = IsDaHood or IsDersHood
-- These places kick on hookmetamethod(game, "__index") → "indexInstance detector"
local NoIndexHook = IsDersHood or IsHoodCustoms

local MainEvent, UnreliableMainEvent, MainFunction
local StompEffectEvent, GunsFolder, AssetsInvoke
local MouseRemote = "MousePosUpdate"
pcall(function()
    MainEvent = ReplicatedStorage:FindFirstChild("MainEvent")
        or ReplicatedStorage:FindFirstChild("MainEventt")
        or ReplicatedStorage:FindFirstChild("MAINEVENT")
    UnreliableMainEvent = ReplicatedStorage:FindFirstChild("UnreliableMainEvent")
    MainFunction = ReplicatedStorage:FindFirstChild("MainFunction")
    StompEffectEvent = ReplicatedStorage:FindFirstChild("STOMPEFFECTEVENT")
    GunsFolder = ReplicatedStorage:FindFirstChild("guns")
        or ReplicatedStorage:FindFirstChild("Guns")
        or ReplicatedStorage:FindFirstChild("GUNS")
    local assets = ReplicatedStorage:FindFirstChild("Assets")
    AssetsInvoke = assets and assets:FindFirstChild("Invoke")
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
    or (IsDersHood and "Der/Des Hood")
    or (IsDaHood and "Da Hood")
    or (IsHoodCustoms and "Hood Customs")
    or ("Place " .. tostring(PlaceId))
print("[Stand] Place", PlaceId, placeLabel, "| MouseRemote =", MouseRemote,
    "| MainEvent =", MainEvent and MainEvent.Name or "nil",
    "| StompFX =", StompEffectEvent and "yes" or "no",
    "| guns =", GunsFolder and "yes" or "no")

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

function F.getMySlot()
    local alts = Config.Alts or {}
    local s = alts[LocalPlayer.Name]
    if s == nil then s = Config.Slot or 2 end
    return tonumber(s) or 2
end

local IsOwner = (string.lower(LocalPlayer.Name) == string.lower(OwnerName))
local MySlot  = F.getMySlot()
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
    AutoHeal      = true,  -- auto buy food + eat when hurt (HC: EatFood / BuyItem)
    Sweep         = false,
    Air           = true,  -- floating summon formation (toggle with .air)
    FakePos       = false, -- stay in formation; gun kills still work via silent aim + mouse remotes
    Sentry        = false, -- .sentry — knock whoever shoots the OWNER
    Sentry2       = false, -- .sentry2 — knock+stomp whoever shoots the OWNER
    BSentry       = false, -- .bsentry — knock+stomp whoever shoots THIS stand
    AssistName    = nil,   -- .assist user — apply sentry modes for that user too
    SentryBusy    = false,
    CombatActive  = false, -- true during knock/stomp/loop/etc
    HoverHeight   = 3.2,   -- studs above target while attacking (lower = more reliable hits)
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
function F.getChar(p) return (p or LocalPlayer).Character end

function F.getHRP(p)
    local c = F.getChar(p)
    return c and c:FindFirstChild("HumanoidRootPart")
end

function F.getHum(p)
    local c = F.getChar(p)
    return c and c:FindFirstChildOfClass("Humanoid")
end

----------------------------------------------------------------------
-- IDLE ANIMATION (from Discord /config anim)
----------------------------------------------------------------------
local IdleTrack = nil

function F.normalizeAnimId(id)
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

function F.stopIdleAnim()
    if IdleTrack then
        pcall(function() IdleTrack:Stop(0.12) end)
        IdleTrack = nil
    end
end

function F.isHoldingTool()
    local c = F.getChar()
    if not c then return false end
    for _, child in ipairs(c:GetChildren()) do
        if child:IsA("Tool") then return true end
    end
    return false
end

function F.applyIdleAnim()
    local animId = F.normalizeAnimId(Config.Anim)
    if not animId then return end

    -- Don't fight gun/tool hold poses — idle only when unarmed
    if State.Armed or F.isHoldingTool() then
        F.stopIdleAnim()
        return
    end

    local char = F.getChar()
    if not char then return end
    local hum = F.getHum()
    if not hum then return end

    -- Already playing same track
    if IdleTrack and IdleTrack.IsPlaying then return end

    F.stopIdleAnim()

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
function F.hookToolWatch(char)
    if not char then return end
    char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then
            F.stopIdleAnim()
        end
    end)
    char.ChildRemoved:Connect(function(child)
        if child:IsA("Tool") then
            task.defer(function()
                if not State.Armed and not F.isHoldingTool() then
                    F.applyIdleAnim()
                end
            end)
        end
    end)
end

function F.isKO(p)
    local c = F.getChar(p)
    if not c then return false end
    local be = c:FindFirstChild("BodyEffects")
    if be then
        for _, name in ipairs({"K.O", "KO", "Knocked", "IsKnocked", "Downed", "Dead", "SDeath", "Death"}) do
            local v = be:FindFirstChild(name)
            if v then
                if typeof(v.Value) == "boolean" and v.Value then return true end
                if typeof(v.Value) == "number" and v.Value ~= 0 then return true end
            end
        end
        -- some games nest KO under BodyEffects children
        for _, d in ipairs(be:GetDescendants()) do
            local n = string.lower(d.Name)
            if (n == "k.o" or n == "ko" or n == "knocked") and typeof(d.Value) == "boolean" and d.Value then
                return true
            end
        end
    end
    local h = F.getHum(p)
    if h then
        if h.PlatformStand and h.Health > 0 and h.Health < h.MaxHealth * 0.35 then
            return true
        end
        local st = h:GetState()
        if (st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Ragdoll)
            and h.Health > 0 and h.Health < h.MaxHealth * 0.25 then
            return true
        end
    end
    return false
end

function F.isAlive(p)
    local h = F.getHum(p)
    if not h or h.Health <= 0 then return false end
    if F.isKO(p) then return false end
    return true
end

function F.getOwner()
    if OwnerName == "" then return nil end
    for _, plr in ipairs(Players:GetPlayers()) do
        if string.lower(plr.Name) == string.lower(OwnerName) then
            return plr
        end
    end
    return nil
end

function F.findPlayer(name, opts)
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
function F.isProtected(plr)
    if not plr then return true, "nil" end
    if plr == LocalPlayer then return true, "self" end
    if string.lower(plr.Name) == string.lower(OwnerName) then return true, "owner" end
    if Controllers[string.lower(plr.Name)] then return true, "controller" end
    -- Never kill other stands / alts from the same config
    if F.isStandTeam(plr) then return true, "stand" end
    if Whitelist[plr.UserId] then return true, "whitelist" end
    if State.ProtectName and string.lower(plr.Name) == string.lower(State.ProtectName) then
        return true, "protect"
    end
    return false, nil
end

function F.canControl(plr)
    if not plr then return false end
    local n = string.lower(plr.Name)
    if n == string.lower(OwnerName) then return true end
    if Controllers[n] then return true end
    return false
end

function F.notify(msg)
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
function F.fireMouse(pos)
    if not pos then return end
    -- reject NaN / inf — HC gun clients throw red errors on bad Vector3
    if pos.X ~= pos.X or pos.Y ~= pos.Y or pos.Z ~= pos.Z then return end
    if math.abs(pos.X) > 1e6 or math.abs(pos.Y) > 1e6 or math.abs(pos.Z) > 1e6 then return end

    if MainEvent then
        if IsDersHood then
            -- Der/Des Hood: try all common mouse remote strings (clones differ)
            for _, name in ipairs({
                MouseRemote, "UpdateMousePosI", "UpdateMousePos", "MousePosUpdate",
                "MOUSE", "MousePos", "UpdateMouse",
            }) do
                pcall(function() MainEvent:FireServer(name, pos) end)
            end
            -- some builds want x,y,z
            pcall(function() MainEvent:FireServer("UpdateMousePosI", pos.X, pos.Y, pos.Z) end)
            pcall(function() MainEvent:FireServer("UpdateMousePos", pos.X, pos.Y, pos.Z) end)
        else
            pcall(function() MainEvent:FireServer(MouseRemote, pos) end)
        end
    end
    -- Hood Customs: UnreliableMainEvent + MousePosUpdate spam is a common red-error source
    if UnreliableMainEvent and not IsHoodCustoms then
        pcall(function() UnreliableMainEvent:FireServer(MouseRemote, pos) end)
        if IsDersHood then
            pcall(function() UnreliableMainEvent:FireServer("UpdateMousePosI", pos) end)
            pcall(function() UnreliableMainEvent:FireServer("UpdateMousePos", pos) end)
        end
    end
    pcall(function()
        local c = F.getChar()
        local be = c and c:FindFirstChild("BodyEffects")
        if not be then return end
        for _, n in ipairs({"MousePos", "MousePosition", "Mouse", "AimPos"}) do
            local mp = be:FindFirstChild(n)
            if mp and (mp:IsA("Vector3Value") or mp:IsA("CFrameValue")) then
                if mp:IsA("CFrameValue") then
                    mp.Value = CFrame.new(pos)
                else
                    mp.Value = pos
                end
            end
        end
    end)
end

function F.getAimPos(plr)
    local c = F.getChar(plr)
    if not c then return nil end
    local head = c:FindFirstChild("Head")
    local torso = c:FindFirstChild("UpperTorso") or c:FindFirstChild("Torso")
    local hrp  = F.getHRP(plr)
    local base = nil
    -- Prefer head (slight up bias for pellet spread), then upper torso, then HRP
    if head then
        base = head.Position + Vector3.new(0, 0.15, 0)
    elseif torso then
        base = torso.Position + Vector3.new(0, 0.35, 0)
    elseif hrp then
        base = hrp.Position + Vector3.new(0, 1.45, 0)
    end
    if not base then return nil end
    -- Velocity lead: stronger on Hood Customs (faster strafes, longer bullet travel feel)
    if hrp then
        local vel = hrp.AssemblyLinearVelocity
        if vel and vel.Magnitude > 4 then
            local leadT = 0.08
            if IsHoodCustoms then
                leadT = 0.14
            elseif IsDersHood then
                leadT = 0.13
            end
            -- scale lead with speed so slow walkers aren't overshot
            local speedFactor = math.clamp(vel.Magnitude / 28, 0.35, 1.25)
            leadT = leadT * speedFactor
            base = base + Vector3.new(vel.X, vel.Y * 0.4, vel.Z) * leadT
        end
    end
    return base
end

-- Silent aim: force Mouse.Hit / Target onto locked player so guns actually hit
local AimLockPlayer = nil

function F.setAimLock(plr)
    AimLockPlayer = plr
end

function F.clearAimLock()
    AimLockPlayer = nil
end

local silentAimHooked = false
function F.ensureSilentAim()
    if silentAimHooked then return end
    silentAimHooked = true

    local mouse = nil
    pcall(function() mouse = LocalPlayer:GetMouse() end)

    -- NEVER hook game.__index on Der/Des Hood / Hood Customs — kicks with:
    -- "indexInstance detector detected (Error Code: 267)"
    if not NoIndexHook then
        pcall(function()
            if not (hookmetamethod and newcclosure) then return end
            if not mouse then return end
            local oldIndex
            oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
                if AimLockPlayer ~= nil and self == mouse then
                    local k = key
                    if k == "Hit" or k == "hit" then
                        local aim = F.getAimPos(AimLockPlayer)
                        if aim then return CFrame.new(aim) end
                    elseif k == "Target" or k == "target" then
                        local ch = F.getChar(AimLockPlayer)
                        if ch then
                            return ch:FindFirstChild("Head") or F.getHRP(AimLockPlayer) or ch
                        end
                    elseif k == "UnitRay" then
                        local aim = F.getAimPos(AimLockPlayer)
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
    else
        print("[Stand] Silent aim: safe mode (no game.__index) on", placeLabel)
        -- Der Hood: try mouse-only metatable (not game) — many detectors only scan game/Instance
        if IsDersHood and mouse then
            pcall(function()
                if not getrawmetatable then return end
                local mt = getrawmetatable(mouse)
                if not mt then return end
                local oldIndex = mt.__index
                if type(oldIndex) ~= "function" then return end
                if setreadonly then setreadonly(mt, false) end
                mt.__index = newcclosure and newcclosure(function(self, key)
                    if AimLockPlayer ~= nil and self == mouse then
                        local k = key
                        if k == "Hit" or k == "hit" then
                            local aim = F.getAimPos(AimLockPlayer)
                            if aim then return CFrame.new(aim) end
                        elseif k == "Target" or k == "target" then
                            local ch = F.getChar(AimLockPlayer)
                            if ch then
                                return ch:FindFirstChild("Head") or F.getHRP(AimLockPlayer) or ch
                            end
                        elseif k == "UnitRay" then
                            local aim = F.getAimPos(AimLockPlayer)
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
                end) or function(self, key)
                    if AimLockPlayer ~= nil and self == mouse then
                        if key == "Hit" or key == "hit" then
                            local aim = F.getAimPos(AimLockPlayer)
                            if aim then return CFrame.new(aim) end
                        end
                    end
                    return oldIndex(self, key)
                end
                if setreadonly then setreadonly(mt, true) end
                print("[Stand] Silent aim: mouse metatable hooked (Der Hood safe path)")
            end)
        end
    end

    -- keep mouse remotes + screen aim on target while locked
    local lastMouseFire = 0
    local lastCamSoft = 0
    local function pushAim(aim)
        -- Always update local BodyEffects MousePos (safe)
        pcall(function()
            local be = F.getChar() and F.getChar():FindFirstChild("BodyEffects")
            if not be then return end
            for _, n in ipairs({"MousePos", "MousePosition", "AimPos"}) do
                local mp = be:FindFirstChild(n)
                if mp and mp:IsA("Vector3Value") then mp.Value = aim end
            end
        end)
        -- FakePos on HC: BodyEffects only — FireServer spam + static body = red errors
        if State.FakePos and IsHoodCustoms then
            return
        end
        pcall(function() F.fireMouse(aim) end)
        -- never move real cursor / camera on FakePos
        if State.FakePos then return end
        if IsDersHood or IsHoodCustoms then
            pcall(function()
                if not Camera then return end
                local sp, onScreen = Camera:WorldToViewportPoint(aim)
                if not onScreen or sp.Z < 0 then return end
                local vim = game:GetService("VirtualInputManager")
                if vim then
                    vim:SendMouseMoveEvent(sp.X, sp.Y, game)
                end
            end)
        end
    end

    RunService.RenderStepped:Connect(function()
        local plr = AimLockPlayer
        if not plr then return end
        if not F.getChar(plr) then return end
        local aim = F.getAimPos(plr)
        if not aim then return end
        local now = tick()
        local interval = 0.0
        if IsHoodCustoms then
            -- FakePos: very slow BodyEffects-only updates
            interval = State.FakePos and 0.18 or 0.08
        elseif IsDersHood then
            interval = 0.02
        end
        if now - lastMouseFire >= interval then
            lastMouseFire = now
            pushAim(aim)
        end
        -- FakePos / HC: do NOT force Camera.CFrame — major source of red client errors
        if State.FakePos or IsHoodCustoms then return end
        local camInterval = IsDersHood and 0.0 or 0.0
        if now - lastCamSoft >= camInterval then
            lastCamSoft = now
            pcall(function()
                if not Camera or Camera.CameraType == Enum.CameraType.Scriptable then return end
                local origin = Camera.CFrame.Position
                local dir = aim - origin
                if dir.Magnitude < 1.5 then return end
                local flat = Vector3.new(dir.X, 0, dir.Z)
                if flat.Magnitude < 0.35 then
                    aim = aim + Vector3.new(0.4, 0, 0.4)
                end
                Camera.CFrame = CFrame.new(origin, aim)
            end)
        end
    end)

    -- Der Hood: also Heartbeat so MousePos stays hot even if RenderStepped is throttled
    if IsDersHood then
        RunService.Heartbeat:Connect(function()
            local plr = AimLockPlayer
            if not plr or not F.getChar(plr) then return end
            local aim = F.getAimPos(plr)
            if not aim then return end
            pcall(function()
                local be = F.getChar() and F.getChar():FindFirstChild("BodyEffects")
                local mp = be and be:FindFirstChild("MousePos")
                if mp and mp:IsA("Vector3Value") then mp.Value = aim end
            end)
            if MainEvent then
                pcall(function() MainEvent:FireServer("UpdateMousePosI", aim) end)
            end
        end)
    end
end


function F.setAttacking(on)
    pcall(function()
        local be = F.getChar() and F.getChar():FindFirstChild("BodyEffects")
        if not be then return end
        local a = be:FindFirstChild("Attacking")
        if a and a:IsA("BoolValue") then a.Value = on and true or false end
        local ac = be:FindFirstChild("Attacking_CLIENT")
        if ac and ac:IsA("BoolValue") then ac.Value = on and true or false end
    end)
end

function F.fireHitRemotes(plr)
    -- Hood Customs client scripts error (red text) on fake Hit/Knife/Punch remotes
    if IsHoodCustoms then return end
    local char = F.getChar(plr)
    local hum  = F.getHum(plr)
    local aim  = F.getAimPos(plr)
    local function go(remote, isFn)
        if not remote then return end
        local function send(a, b, c)
            if isFn then
                if c ~= nil then pcall(function() remote:InvokeServer(a, b, c) end)
                elseif b ~= nil then pcall(function() remote:InvokeServer(a, b) end)
                else pcall(function() remote:InvokeServer(a) end) end
            else
                if c ~= nil then pcall(function() remote:FireServer(a, b, c) end)
                elseif b ~= nil then pcall(function() remote:FireServer(a, b) end)
                else pcall(function() remote:FireServer(a) end) end
            end
        end
        send("Hit")
        send("Hit", char)
        send("Hit", hum)
        send("Hit", plr)
        send("Knife")
        send("Knife", char)
        send("Punch")
        send("Slash")
        send("Combat")
        send("Damage", char)
        send("Damage", hum)
        if aim then send(MouseRemote, aim) end
    end
    go(MainEvent, false)
    go(UnreliableMainEvent, false)
    go(MainFunction, true)
end

-- Force-hit for gun shots: push aim + common damage/hit remotes so shots register more reliably
function F.forceGunHit(plr, gun)
    if not plr then return end
    local char = F.getChar(plr)
    local hum  = F.getHum(plr)
    local aim  = F.getAimPos(plr)
    if not aim then return end

    -- Always refresh mouse / aim (safe on all places including HC)
    pcall(function() F.fireMouse(aim) end)
    pcall(function()
        local be = F.getChar() and F.getChar():FindFirstChild("BodyEffects")
        if not be then return end
        for _, n in ipairs({"MousePos", "MousePosition", "AimPos", "Mouse"}) do
            local mp = be:FindFirstChild(n)
            if mp and mp:IsA("Vector3Value") then mp.Value = aim end
            if mp and mp:IsA("CFrameValue") then mp.Value = CFrame.new(aim) end
        end
    end)
    F.setAttacking(true)

    -- HC: only mouse / BodyEffects — fake Hit strings cause red client errors
    if IsHoodCustoms then return end

    local function blast(remote, isFn)
        if not remote then return end
        local function send(...)
            local args = {...}
            if isFn then
                pcall(function() remote:InvokeServer(table.unpack(args)) end)
            else
                pcall(function() remote:FireServer(table.unpack(args)) end)
            end
        end
        send("Hit")
        send("Hit", char)
        send("Hit", hum)
        send("Hit", plr)
        send("Shoot")
        send("Shoot", char)
        send("GunHit", char)
        send("GunHit", hum)
        send("Damage", char)
        send("Damage", hum)
        if gun then
            send("Hit", gun)
            send("Shoot", gun)
            send("Fire", gun)
        end
        send(MouseRemote, aim)
    end
    blast(MainEvent, false)
    blast(UnreliableMainEvent, false)
    blast(MainFunction, true)

    -- Tool-local remotes (some guns fire damage from inside the tool)
    if gun then
        pcall(function()
            for _, d in ipairs(gun:GetDescendants()) do
                if d:IsA("RemoteEvent") then
                    pcall(function() d:FireServer() end)
                    pcall(function() d:FireServer(char) end)
                    pcall(function() d:FireServer(hum) end)
                    pcall(function() d:FireServer("Hit", char) end)
                elseif d:IsA("RemoteFunction") then
                    pcall(function() d:InvokeServer() end)
                    pcall(function() d:InvokeServer(char) end)
                end
            end
        end)
    end
end

----------------------------------------------------------------------
-- TOOLS
----------------------------------------------------------------------
function F.findTool(name, exact)
    local c = F.getChar()
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

function F.equipTool(tool, timeout)
    if not tool then return nil end
    timeout = timeout or 0.6
    local c = F.getChar()
    local h = F.getHum()
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

function F.activateTool(tool)
    if not tool then return false end
    local c = F.getChar()
    if tool.Parent ~= c then
        tool = F.equipTool(tool, 0.4)
    end
    if not tool or tool.Parent ~= c then return false end
    pcall(function() tool:Activate() end)
    -- Hood Customs: real activation is Tool.ACTION:FireServer("ACTIVATE")
    if IsHoodCustoms then
        pcall(function()
            local action = tool:FindFirstChild("ACTION")
            if action and action:IsA("RemoteEvent") then
                action:FireServer("ACTIVATE")
            end
        end)
        pcall(function()
            for _, d in ipairs(tool:GetDescendants()) do
                if d:IsA("RemoteEvent") and string.lower(d.Name):find("action") then
                    pcall(function() d:FireServer("ACTIVATE") end)
                    pcall(function() d:FireServer() end)
                end
            end
        end)
    end
    return true
end

function F.findKnife()
    -- Katana first (some hood clones), then classic knife names
    return F.findTool("[Katana]", true)
        or F.findTool("Katana", true)
        or F.findTool("[Katana]", false)
        or F.findTool("Katana", false)
        or F.findTool("[Knife]", true)
        or F.findTool("Knife", true)
        or F.findTool("[Knife]", false)
        or F.findTool("Knife", false)
        or F.findTool("[Combat]", false)
        or F.findTool("Combat", false)
end

function F.findGun()
    return F.findTool(PreferredGun, true)
        or F.findTool(PreferredGun, false)
        or F.findTool("[DoubleBarrel]", false)
        or F.findTool("[Double-Barrel SG]", false)
        or F.findTool("[Revolver]", false)
end

function F.expandKnifeParts(knife)
    if not knife then return end
    pcall(function()
        for _, part in ipairs(knife:GetDescendants()) do
            if part:IsA("BasePart") then
                if not part:GetAttribute("StandOrig") then
                    part:SetAttribute("StandOrig", part.Size)
                end
                local orig = part:GetAttribute("StandOrig")
                if typeof(orig) == "Vector3" then
                    -- Large hitbox so swings connect reliably (still massless / no collide)
                    part.Size = Vector3.new(
                        math.max(orig.X * 12, 14),
                        math.max(orig.Y * 12, 16),
                        math.max(orig.Z * 12, 14)
                    )
                else
                    part.Size = Vector3.new(14, 16, 14)
                end
                part.Massless = true
                part.CanCollide = false
                part.Transparency = math.max(part.Transparency, 0.35)
                pcall(function() part.CanTouch = true end)
                pcall(function() part.CanQuery = true end)
            end
        end
        -- Also expand Handle if present as direct child
        local handle = knife:FindFirstChild("Handle")
        if handle and handle:IsA("BasePart") then
            if not handle:GetAttribute("StandOrig") then
                handle:SetAttribute("StandOrig", handle.Size)
            end
            local orig = handle:GetAttribute("StandOrig")
            if typeof(orig) == "Vector3" then
                handle.Size = Vector3.new(
                    math.max(orig.X * 12, 14),
                    math.max(orig.Y * 12, 16),
                    math.max(orig.Z * 12, 14)
                )
            end
            handle.Massless = true
            handle.CanCollide = false
            pcall(function() handle.CanTouch = true end)
        end
    end)
end

----------------------------------------------------------------------
-- CAMLOCK (never set CameraType.Scriptable — breaks gun rays + CameraModule)
----------------------------------------------------------------------
local CAM_BIND = "StandCamlock"

function F.clearCamlock()
    CamTarget = nil
    State.Camlock = false
    CamlockUntil = 0
    F.clearAimLock()
    pcall(function() RunService:UnbindFromRenderStep(CAM_BIND) end)
end

local lastCamMouseFire = 0
function F.camlockStep()
    if not State.Camlock then return end
    if CamlockUntil > 0 and tick() > CamlockUntil then
        F.clearCamlock()
        return
    end
    local plr = CamTarget and F.findPlayer(CamTarget)
    if not plr then return end
    local aim = F.getAimPos(plr)
    if not aim then return end
    local now = tick()
    local interval = IsHoodCustoms and 0.08 or 0.0
    if State.FakePos then interval = 0.12 end
    if now - lastCamMouseFire >= interval then
        lastCamMouseFire = now
        pcall(function() F.fireMouse(aim) end)
        pcall(function()
            local be = F.getChar() and F.getChar():FindFirstChild("BodyEffects")
            local mp = be and be:FindFirstChild("MousePos")
            if mp and mp:IsA("Vector3Value") then mp.Value = aim end
        end)
    end
    -- FakePos / HC: never force Camera.CFrame (red ERROR_CLIENT_UNSYNCED_SERVER / gun ray NaNs)
    if State.FakePos or IsHoodCustoms then return end
    pcall(function()
        if not Camera or Camera.CameraType == Enum.CameraType.Scriptable then return end
        local origin = Camera.CFrame.Position
        local dir = aim - origin
        if dir.Magnitude < 1.5 then return end
        local flat = Vector3.new(dir.X, 0, dir.Z)
        if flat.Magnitude < 0.35 then
            aim = aim + Vector3.new(0.4, 0, 0.4)
        end
        Camera.CFrame = CFrame.new(origin, aim)
    end)
end

function F.setCamlock(plr, seconds)
    if not plr then return end
    CamTarget = plr.Name
    State.Camlock = true
    F.setAimLock(plr)
    pcall(F.ensureSilentAim)
    CamlockUntil = (seconds and seconds > 0) and (tick() + seconds) or 0
    -- FakePos: aim lock only — no RenderStep camera bind (avoids red errors)
    if State.FakePos then
        pcall(function() RunService:UnbindFromRenderStep(CAM_BIND) end)
        return
    end
    pcall(function()
        RunService:UnbindFromRenderStep(CAM_BIND)
        RunService:BindToRenderStep(CAM_BIND, Enum.RenderPriority.Last.Value, F.camlockStep)
    end)
end

----------------------------------------------------------------------
-- FORMATION
----------------------------------------------------------------------
local _lastFormAt = 0
local _fakeFreezeCF = nil -- when FakePos + shooting: pin here, zero CFrame writes

function F.clearFakeFreeze()
    _fakeFreezeCF = nil
end

function F.pinFakeFreeze()
    if not State.FakePos then
        _fakeFreezeCF = nil
        return
    end
    local my = F.getHRP()
    if not my then return end
    -- prefer current slot relative to owner once; then freeze
    local owner = F.getOwner()
    local oHRP = owner and F.getHRP(owner)
    if oHRP then
        local offset = SLOT_CF[MySlot] or SLOT_CF[2]
        _fakeFreezeCF = oHRP.CFrame * offset
        pcall(function()
            my.CFrame = _fakeFreezeCF
            my.AssemblyLinearVelocity = Vector3.zero
            my.AssemblyAngularVelocity = Vector3.zero
        end)
    else
        _fakeFreezeCF = my.CFrame
    end
end

-- Hold formation slot relative to owner. Soft on HC to avoid CLIENT_UNSYNCED_SERVER.
-- force=true ignores Tracking (used by FakePos during combat).
function F.holdFormation(force)
    if IsOwner then return end
    if State.KnifeBusy and not force then return end
    if State.InVoid or State.VoidEat then
        local hrp = F.getHRP()
        if hrp then
            pcall(function()
                hrp.CFrame = VoidCF
                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        return
    end
    if not force and not State.Tracking then return end

    -- FakePos + gun combat: DO NOT write CFrame at all (only kill velocity).
    -- Writing HRP while activating the gun = ERROR_CLIENT_UNSYNCED_SERVER on HC.
    if State.FakePos and (State.CombatActive or AimLockPlayer ~= nil) and not State.KnifeBusy then
        pcall(function()
            local my = F.getHRP()
            if not my then return end
            if _fakeFreezeCF then
                -- only re-pin if we drifted a lot (rare); otherwise velocity only
                local dist = (my.Position - _fakeFreezeCF.Position).Magnitude
                if dist > 8 then
                    my.CFrame = _fakeFreezeCF
                end
            end
            my.AssemblyLinearVelocity = Vector3.zero
            my.AssemblyAngularVelocity = Vector3.zero
        end)
        return
    end

    local owner = F.getOwner()
    if not owner then return end
    local oHRP = F.getHRP(owner)
    local my = F.getHRP()
    if not oHRP or not my then return end
    local offset = SLOT_CF[MySlot] or SLOT_CF[2]
    local dest = oHRP.CFrame * offset
    if dest.Position.Y < (oHRP.Position.Y - 2) then
        dest = CFrame.new(dest.Position.X, oHRP.Position.Y + math.max(offset.Y, 0), dest.Position.Z)
            * (dest - dest.Position)
    end
    pcall(function()
        if IsHoodCustoms then
            local now = tick()
            local minGap = force and 0.10 or 0.16
            if now - _lastFormAt < minGap then
                local v = my.AssemblyLinearVelocity
                if v.Magnitude > 4 or v.Y < -1 then
                    my.AssemblyLinearVelocity = Vector3.new(0, math.max(v.Y, 0), 0)
                end
                my.AssemblyAngularVelocity = Vector3.zero
                return
            end
            _lastFormAt = now
            local dist = (dest.Position - my.Position).Magnitude
            if dist > 14 then
                my.CFrame = my.CFrame:Lerp(dest, 0.35)
            elseif dist > 4 then
                my.CFrame = my.CFrame:Lerp(dest, 0.28)
            elseif dist > 1.5 then
                my.CFrame = my.CFrame:Lerp(dest, 0.18)
            end
            my.AssemblyLinearVelocity = Vector3.zero
            my.AssemblyAngularVelocity = Vector3.zero
        else
            my.CFrame = dest
            my.AssemblyLinearVelocity = Vector3.zero
            my.AssemblyAngularVelocity = Vector3.zero
        end
    end)
end

function F.followOwner()
    F.holdFormation(false)
end

function F.returnToOwner()
    if IsOwner then return end
    F.clearCamlock()
    State.TargetName = nil
    State.InVoid = false
    State.Tracking = true
    State.KnifeBusy = false
    pcall(function()
        local h = F.getHum()
        if h then
            h.PlatformStand = false
            h.Sit = false
            h:ChangeState(Enum.HumanoidStateType.Running)
            h:UnequipTools()
        end
    end)
    local owner = F.getOwner()
    local oHRP = owner and F.getHRP(owner)
    local my = F.getHRP()
    if oHRP and my then
        local offset = SLOT_CF[MySlot] or SLOT_CF[2]
        local steps = IsHoodCustoms and 2 or 5
        for _ = 1, steps do
            pcall(function()
                local cf = oHRP.CFrame * offset
                -- HC: never PivotTo (desync red error)
                if not IsHoodCustoms then
                    local char = F.getChar()
                    if char and char.PivotTo then char:PivotTo(cf) end
                end
                my.CFrame = cf
                my.AssemblyLinearVelocity = Vector3.zero
                my.AssemblyAngularVelocity = Vector3.zero
            end)
            task.wait(IsHoodCustoms and 0.08 or 0.05)
            oHRP = F.getHRP(owner)
            my = F.getHRP()
            if not oHRP or not my then break end
        end
    end
    F.holdFormation(true)
end

----------------------------------------------------------------------
----------------------------------------------------------------------
-- COMBAT: RELOAD
----------------------------------------------------------------------
function F.reloadGun(gun)
    gun = gun or F.findGun()
    if not gun then return false end

    local c = F.getChar()
    local h = F.getHum()
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
function F.autoReloadTick()
    if not State.AutoReload then return end
    if State.KnifeBusy then return end
    if tick() - lastAutoReload < 1.5 then return end
    lastAutoReload = tick()

    local c = F.getChar()
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
        equipped = F.findGun()
        if equipped then
            pcall(function()
                local h = F.getHum()
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
            F.reloadGun(equipped)
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

function F.isFoodName(name)
    local n = string.lower(tostring(name or ""))
    for _, key in ipairs(FOOD_NAMES) do
        if n:find(key, 1, true) then return true end
    end
    return false
end

function F.findFood()
    local c = F.getChar()
    local bag = LocalPlayer:FindFirstChild("Backpack")
    for _, container in ipairs({c, bag}) do
        if container then
            for _, t in ipairs(container:GetChildren()) do
                if t:IsA("Tool") and F.isFoodName(t.Name) then
                    return t
                end
            end
        end
    end
    return nil
end

-- HC food item names from dump: [Chicken] [Pizza] [Taco] [Burger]
local HC_FOOD_ITEMS = { "[Chicken]", "[Pizza]", "[Taco]", "[Burger]" }

-- Auto-buy food from shop if none in inventory
function F.buyFood()
    -- Hood Customs: BuyItem remote + FFA_MAP.Shop Grab pads
    if IsHoodCustoms and MainEvent then
        for _, item in ipairs(HC_FOOD_ITEMS) do
            pcall(function() MainEvent:FireServer("BuyItem", item) end)
            pcall(function() MainEvent:FireServer("BuyItem", item:gsub("[%[%]]", "")) end)
        end
        pcall(function() MainEvent:FireServer("BuyItem", "Chicken") end)
        pcall(function() MainEvent:FireServer("BuyItem", "Pizza") end)
        pcall(function() MainEvent:FireServer("BuyItem", "Taco") end)
        pcall(function() MainEvent:FireServer("BuyItem", "Burger") end)
    elseif MainEvent then
        for _, n in ipairs({
            "BuyChicken", "BuyPizza", "BuyTaco", "BuyHotdog", "BuyBurger",
            "Chicken", "Pizza", "Taco", "Food", "BuyFood",
        }) do
            pcall(function() MainEvent:FireServer(n) end)
            pcall(function() MainEvent:FireServer("Buy", n) end)
            pcall(function() MainEvent:FireServer("BuyItem", n) end)
        end
    end

    -- Shop pads: HC = Workspace.FFA_MAP.Shop | classic = Workspace.Ignored.Shop
    pcall(function()
        local shop = nil
        if IsHoodCustoms then
            local map = Workspace:FindFirstChild("FFA_MAP")
            shop = map and map:FindFirstChild("Shop")
        end
        if not shop then
            local ignored = Workspace:FindFirstChild("Ignored")
            shop = ignored and ignored:FindFirstChild("Shop")
        end
        if not shop then
            shop = Workspace:FindFirstChild("Shop")
                or (Workspace:FindFirstChild("MAP") and Workspace.MAP:FindFirstChild("Shop"))
        end
        if not shop then return end

        local my = F.getHRP()
        local savedCF = my and my.CFrame

        for _, m in ipairs(shop:GetDescendants()) do
            local nameOk = F.isFoodName(m.Name)
            -- HC pads named "Grab - [Chicken]" etc; also check PromptItem attribute
            if not nameOk and m:IsA("ClickDetector") then
                local item = m:GetAttribute("PromptItem")
                if item and F.isFoodName(tostring(item)) then nameOk = true end
                if m:GetAttribute("PromptKind") == "food" then nameOk = true end
            end
            if not nameOk then continue end

            local cd = m:IsA("ClickDetector") and m or m:FindFirstChildWhichIsA("ClickDetector", true)
            local part = m:IsA("BasePart") and m
                or (m.Parent and m.Parent:IsA("BasePart") and m.Parent)
                or m:FindFirstChildWhichIsA("BasePart", true)
            if cd then
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
                if F.findFood() then break end
            end
        end

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
    return F.findFood() ~= nil
end

function F.fireEatRemotes(food)
    if not MainEvent then return end

    -- Hood Customs (from dump): MainEvent:FireServer("EatFood", p167, v213)
    if IsHoodCustoms then
        if food then
            pcall(function() MainEvent:FireServer("EatFood", food, food) end)
            pcall(function() MainEvent:FireServer("EatFood", food.Name, food) end)
            pcall(function() MainEvent:FireServer("EatFood", food, food.Name) end)
            pcall(function() MainEvent:FireServer("EatFood", food) end)
            pcall(function() MainEvent:FireServer("EatFood", food.Name) end)
        else
            pcall(function() MainEvent:FireServer("EatFood") end)
        end
        return
    end

    pcall(function() MainEvent:FireServer("Eat", food) end)
    pcall(function() MainEvent:FireServer("Eat") end)
    pcall(function() MainEvent:FireServer("Eating") end)
    pcall(function() MainEvent:FireServer("Eating", food) end)
    pcall(function() MainEvent:FireServer("EatFood", food) end)
    if food then
        pcall(function() MainEvent:FireServer("Eat", food.Name) end)
        pcall(function() MainEvent:FireServer("Eat", food, food) end)
        pcall(function() MainEvent:FireServer("EatFood", food, food) end)
    end
    if UnreliableMainEvent then
        pcall(function() UnreliableMainEvent:FireServer("Eat", food) end)
        pcall(function() UnreliableMainEvent:FireServer("Eat") end)
        pcall(function() UnreliableMainEvent:FireServer("EatFood", food) end)
    end
end

function F.eatFood()
    local food = F.findFood()
    -- never shop-TP while already void-healing (yanks character out)
    if not food and not State.VoidEat then
        F.buyFood()
        food = F.findFood()
    end
    if food then
        food = F.equipTool(food, State.VoidEat and 0.9 or 0.45)
        if food then
            for _ = 1, 12 do
                if State.VoidEat then
                    F.pinToVoid()
                end
                pcall(function() food:Activate() end)
                F.activateTool(food)
                F.fireEatRemotes(food)
                -- HC: also fire ACTION on the food tool
                if IsHoodCustoms then
                    pcall(function()
                        local action = food:FindFirstChild("ACTION")
                        if action and action:IsA("RemoteEvent") then
                            action:FireServer("ACTIVATE")
                        end
                    end)
                end
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
                    if vu then vu:ClickButton1(Vector2.new(0, 0)) end
                end)
                task.wait(0.08)
            end
            return true
        end
    end
    F.fireEatRemotes(nil)
    if MainEvent then
        if IsHoodCustoms then
            for _, item in ipairs(HC_FOOD_ITEMS) do
                pcall(function() MainEvent:FireServer("BuyItem", item) end)
            end
        else
            for _, n in ipairs({
                "BuyChicken", "BuyPizza", "BuyTaco", "BuyHamburger", "BuyDonut",
                "Chicken", "Pizza", "Taco", "Hamburger", "Donut",
            }) do
                pcall(function() MainEvent:FireServer(n) end)
                pcall(function() MainEvent:FireServer("Buy", n) end)
            end
        end
    end
    return false
end

-- Focused void heal: buy if needed, equip food, eat hard while pinned
function F.getLocalBlood()
    local c = F.getChar()
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

function F.getLocalHurt()
    -- Prefer BodyEffects blood; fall back to Humanoid + KO
    local blood = F.getLocalBlood()
    if blood ~= nil and blood < 90 then return true end
    local hum = F.getHum()
    if not hum then return true end
    if hum.Health < hum.MaxHealth * 0.9 then return true end
    if F.isKO(LocalPlayer) then return true end
    return false
end

local VoidRecoverUntil = 0
local VoidMinUntil = 0       -- hard minimum time in void before any exit
local VoidBloodAtEnter = nil -- blood snapshot when we entered (ignore client writes)
local _voidEnterBusy = false
local _lastVoidEatAt = 0
local _voidCooldownUntil = 0 -- prevent instant re-void after exit

function F.pinToVoid()
    local hrp = F.getHRP()
    if not hrp then return end
    pcall(function()
        local ch = F.getChar()
        if ch and ch.PivotTo then
            ch:PivotTo(VoidCF)
        end
        hrp.CFrame = VoidCF
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)
    pcall(function()
        local h = F.getHum()
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

function F.startVoidPinRender()
    pcall(function()
        RunService:UnbindFromRenderStep("StandVoidPin")
        RunService:BindToRenderStep("StandVoidPin", Enum.RenderPriority.Camera.Value - 1, function()
            if not State.VoidEat then return end
            F.pinToVoid()
        end)
    end)
end

function F.voidHealBurst()
    if not State.VoidEat then return end
    F.pinToVoid()

    if not F.findFood() then
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
        F.pinToVoid()
        -- if still no food, brief shop trip then back to void
        if not F.findFood() then
            pcall(F.buyFood)
            F.pinToVoid()
            task.wait(0.15)
            F.pinToVoid()
        end
    end

    for _ = 1, 6 do
        if not State.VoidEat then break end
        F.pinToVoid()
        F.eatFood()
        F.pinToVoid()
        task.wait(0.1)
    end
end

function F.enterCombatVoid()
    if State.VoidEat then
        F.pinToVoid()
        return
    end
    State.InVoid = true
    State.VoidEat = true
    State.Tracking = false
    _voidEnterBusy = true
    local now = tick()
    VoidRecoverUntil = now + 4.5   -- max time in void then forced return
    VoidMinUntil = now + 2.0      -- MUST stay long enough to buy + eat
    VoidBloodAtEnter = F.getLocalBlood()

    F.clearCamlock()
    F.clearAimLock()
    F.startVoidPinRender()
    F.pinToVoid()

    pcall(function()
        local h = F.getHum()
        if h then
            h.PlatformStand = false
            h.Sit = false
            h:ChangeState(Enum.HumanoidStateType.GettingUp)
            h:ChangeState(Enum.HumanoidStateType.Running)
            h:UnequipTools()
        end
    end)

    F.pinToVoid()

    -- dedicated void heal: buy + equip + eat while pinned
    pcall(F.voidHealBurst)
    F.pinToVoid()
end

function F.getCombatReturnCF()
    -- Prefer current fight target, else owner formation
    local targetName = State.LoopKill or State.LoopKnock or State.TargetName
    if targetName then
        local plr = F.findPlayer(targetName)
        local their = plr and F.getHRP(plr)
        if their then
            return their.CFrame * CFrame.new(0, 2, 6)
        end
    end
    local owner = F.getOwner()
    local oHRP = owner and F.getHRP(owner)
    if oHRP then
        local offset = SLOT_CF[MySlot] or SLOT_CF[2]
        return oHRP.CFrame * offset
    end
    -- last resort: above origin so we leave void coords
    return CFrame.new(0, 50, 0)
end

function F.warpOutOfVoid()
    local cf = F.getCombatReturnCF()
    for _ = 1, 8 do
        if State.VoidEat then return end
        pcall(function()
            local h = F.getHum()
            if h then
                h.PlatformStand = false
                h.Sit = false
                h:ChangeState(Enum.HumanoidStateType.GettingUp)
                h:ChangeState(Enum.HumanoidStateType.Running)
            end
            local hrp = F.getHRP()
            local ch = F.getChar()
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

function F.exitCombatVoid()
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
        F.warpOutOfVoid()
    end)

    pcall(function()
        local h = F.getHum()
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
        F.notify("Combat resume")
    elseif State.CombatActive then
        State.Tracking = false
        F.notify("Combat resume")
    else
        State.Tracking = true
        F.notify("Healed — back")
        task.spawn(function()
            task.wait(0.1)
            if not State.CombatActive and not State.VoidEat then
                pcall(F.returnToOwner)
            end
        end)
    end
end

-- Slow TP / hover near target. FakePos = no movement.
-- HC: large throttle + small lerp steps so we still close distance WITHOUT
-- ERROR_CLIENT_UNSYNCED_SERVER (hard/fast TP is what triggers the red error).
local _lastHoverAt = 0
function F.hoverOverTarget(plr, height)
    if State.VoidEat or State.InVoid then return end
    if State.FakePos then return end -- never move body in FakePos
    height = height or State.HoverHeight or 4
    local my = F.getHRP()
    local their = F.getHRP(plr)
    if not my or not their then return end
    local aim = F.getAimPos(plr) or their.Position
    local vel = their.AssemblyLinearVelocity or Vector3.zero
    local speed = vel.Magnitude
    local airborne = speed > 12 or (their.Position.Y - (Workspace.FallenPartsDestroyHeight or -500) > 40
        and math.abs(vel.Y) > 4)

    local ox, oz
    local side = IsHoodCustoms and 2.8 or 1.4
    if IsHoodCustoms then
        -- Snap BEHIND the target once; skip if already close enough.
        -- No orbit — orbiting causes constant visible teleports between every shot.
        local now = tick()
        -- Throttle: don't re-snap more than once per 0.35s
        if now - _lastHoverAt < 0.35 then return end

        -- Compute behind position using their CFrame (relative to where they face)
        local behindCF = their.CFrame * CFrame.new(0, 1.6, 2.2)
        local behindPos = behindCF.Position
        local floorY2 = their.Position.Y + 1.0
        local mapFloor2 = (Workspace.FallenPartsDestroyHeight or -500) + 30
        if behindPos.Y < floorY2 then behindPos = Vector3.new(behindPos.X, floorY2, behindPos.Z) end
        if behindPos.Y < mapFloor2 then behindPos = Vector3.new(behindPos.X, mapFloor2, behindPos.Z) end

        local dist = (behindPos - my.Position).Magnitude
        -- Only snap if we're not already behind them (> 3.5 studs away from behind-slot)
        if dist <= 3.5 then return end

        _lastHoverAt = now
        local aimPos = aim or their.Position
        local look = Vector3.new(aimPos.X, their.Position.Y + 1.3, aimPos.Z)
        local toLook = look - behindPos
        if Vector3.new(toLook.X, 0, toLook.Z).Magnitude < 0.5 then
            look = look + Vector3.new(0.5, 0, 0.5)
        end
        pcall(function()
            my.CFrame = CFrame.new(behindPos, look)
            my.AssemblyLinearVelocity = Vector3.zero
            my.AssemblyAngularVelocity = Vector3.zero
        end)
        return
    elseif airborne then
        if speed > 2 then
            local flat = Vector3.new(vel.X, 0, vel.Z)
            if flat.Magnitude > 0.1 then
                flat = flat.Unit
                ox = -flat.X * 0.6 + flat.Z * side * 0.35
                oz = -flat.Z * 0.6 - flat.X * side * 0.35
            else
                ox, oz = side * 0.5, side * 0.5
            end
        else
            ox, oz = 0.9, 0.9
        end
        height = math.min(height, 2.8)
    else
        ox = 0.35
        oz = ox
    end

    local targetPos = their.Position + Vector3.new(ox, height, oz)
    local floorY = their.Position.Y + 1.2
    if targetPos.Y < floorY then
        targetPos = Vector3.new(targetPos.X, floorY, targetPos.Z)
    end
    local mapFloor = (Workspace.FallenPartsDestroyHeight or -500) + 30
    if targetPos.Y < mapFloor then
        targetPos = Vector3.new(targetPos.X, mapFloor, targetPos.Z)
    end

    pcall(function()
        local lookY = (aim and aim.Y) or (their.Position.Y + 1.2)
        local look = Vector3.new(aim.X, lookY, aim.Z)
        local toLook = look - targetPos
        local flat = Vector3.new(toLook.X, 0, toLook.Z)
        if flat.Magnitude < 0.8 then
            local push = Vector3.new(ox, 0, oz)
            if push.Magnitude < 0.1 then push = Vector3.new(1, 0, 0) end
            look = look + push.Unit * 1.2
        end

        if not IsHoodCustoms then
            -- Snap BEHIND the target (not beside); only move if we actually need to.
            -- Using their LookVector so we sit at their back, facing them.
            local behind = their.CFrame * CFrame.new(0, 1.6, 2.2) -- behind + slightly above
            local behindPos = behind.Position
            -- floor clamp
            if behindPos.Y < floorY then
                behindPos = Vector3.new(behindPos.X, floorY, behindPos.Z)
            end
            if behindPos.Y < mapFloor then
                behindPos = Vector3.new(behindPos.X, mapFloor, behindPos.Z)
            end
            local dist = (behindPos - my.Position).Magnitude
            -- Only teleport if target is moving fast enough to need a snap, OR we are far away.
            -- This avoids jitter when already in position.
            local needsSnap = dist > 4 or speed > 3
            if needsSnap then
                local cf = CFrame.new(behindPos, aim)
                local ch = F.getChar()
                if ch and ch.PivotTo then ch:PivotTo(cf) end
                my.CFrame = cf
            end
            if airborne and speed > 8 then
                my.AssemblyLinearVelocity = Vector3.new(vel.X, math.min(vel.Y, 0), vel.Z)
            else
                my.AssemblyLinearVelocity = Vector3.zero
            end
        else
            -- SLOW TP: tiny lerp alphas, never full snap (even when far)
            local dist = (targetPos - my.Position).Magnitude
            local alpha
            if dist > 40 then
                alpha = 0.18 -- far: still slow crawl toward target
            elseif dist > 18 then
                alpha = 0.22
            elseif dist > 8 then
                alpha = 0.26
            elseif dist > 3 then
                alpha = 0.30
            else
                alpha = 0 -- close enough: rotate only
            end
            local mid
            if alpha > 0 then
                mid = my.Position:Lerp(targetPos, alpha)
                if mid.Y < floorY then mid = Vector3.new(mid.X, floorY, mid.Z) end
                my.CFrame = CFrame.new(mid, look)
            else
                my.CFrame = CFrame.new(my.Position, look)
            end
            -- tiny horizontal velocity only (helps server accept move); never negative Y
            local d = targetPos - my.Position
            local hx = math.clamp(d.X * 0.35, -6, 6)
            local hz = math.clamp(d.Z * 0.35, -6, 6)
            my.AssemblyLinearVelocity = Vector3.new(hx, 0, hz)
        end
        my.AssemblyAngularVelocity = Vector3.zero
    end)
end

-- Approach target before shooting. HC: single snap behind + short settle wait.
-- No loop = no visible repeated teleports before the first shot.
function F.softApproachTarget(plr, _seconds)
    if State.FakePos or not plr then return end
    if not F.getChar(plr) then return end
    if State.VoidEat or State.InVoid then return end
    if not IsHoodCustoms then
        F.hoverOverTarget(plr)
        return
    end
    -- Force _lastHoverAt to 0 so the throttle doesn't skip the initial snap
    _lastHoverAt = 0
    F.hoverOverTarget(plr)
    -- Brief settle so the server can register the new position before shots start
    task.wait(0.18)
end

function F.beginCombat()
    State.CombatActive = true
    if State.FakePos then
        F.pinFakeFreeze()
    end
end

function F.endCombat()
    State.CombatActive = false
    State.VoidEat = false
    State.InVoid = false
    VoidRecoverUntil = 0
    VoidMinUntil = 0
    VoidBloodAtEnter = nil
    _voidEnterBusy = false
    F.clearFakeFreeze()
    pcall(function()
        RunService:UnbindFromRenderStep("StandVoidPin")
    end)
end

-- If shot during combat → void + eat, then ALWAYS leave void and resume combat
function F.combatSurviveTick()
    if IsOwner then return end

    -- CRITICAL: always process void recovery even if CombatActive became false,
    -- otherwise the stand gets permanently stuck in void.
    if State.VoidEat then
        F.pinToVoid()

        -- keep eating while voided
        if tick() - _lastVoidEatAt >= 0.55 then
            _lastVoidEatAt = tick()
            pcall(function()
                if F.findFood() then
                    F.eatFood()
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
                    F.fireEatRemotes(nil)
                end
            end)
            F.pinToVoid()
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
            if not F.getLocalHurt() then
                healed = true
            else
                local blood = F.getLocalBlood()
                if blood ~= nil and blood >= 95 then
                    healed = true
                end
                local hum = F.getHum()
                if hum and not F.isKO(LocalPlayer) and hum.Health >= hum.MaxHealth * 0.92 then
                    healed = true
                end
            end
        end

        if (minDone and healed) or maxDone then
            F.exitCombatVoid()
        end
        return
    end

    -- Auto void-heal on shot DISABLED — does not work reliably (manual .heal still works via cmdHeal)
    -- if not State.CombatActive then return end
    -- if F.getLocalHurt() and not _voidEnterBusy and tick() >= _voidCooldownUntil then
    --     ...
    -- end
end

----------------------------------------------------------------------
-- HOOD CUSTOMS helpers (defined early so shootTarget / loopkill can use them)
-- NO underground dives — they make the stand fall through the map and
-- hard TP spam triggers ERROR_CLIENT_UNSYNCED_SERVER (red client).
----------------------------------------------------------------------
local _lastHcMoveAt = 0

function F.hcSetCF(cf, vel)
    local my = F.getHRP()
    if not my then return end
    pcall(function()
        -- clamp Y so we never write an under-map CFrame
        local pos = cf.Position
        local minY = (Workspace.FallenPartsDestroyHeight or -500) + 30
        if pos.Y < minY then
            pos = Vector3.new(pos.X, minY, pos.Z)
            cf = CFrame.new(pos) * (cf - cf.Position)
        end
        my.CFrame = cf
        my.AssemblyLinearVelocity = vel or Vector3.zero
        my.AssemblyAngularVelocity = Vector3.zero
    end)
end

-- Deprecated no-op: underground dives caused falling + red errors
function F.hcGoUnderground(_plr)
    -- intentionally empty
end

-- Move behind target (throttled). Respects FakePos.
function F.hcSurfaceAbove(plr)
    if State.FakePos then return end
    if State.VoidEat or State.InVoid then return end
    local their = F.getHRP(plr)
    local my = F.getHRP()
    if not my or not their then return end
    local now = tick()
    if now - _lastHcMoveAt < 0.35 then return end

    -- Snap behind using their CFrame — consistent position, no orbit jitter
    local behindCF = their.CFrame * CFrame.new(0, 1.6, 2.2)
    local behindPos = behindCF.Position
    local floorY = their.Position.Y + 1.0
    local mapFloor = (Workspace.FallenPartsDestroyHeight or -500) + 30
    if behindPos.Y < floorY then behindPos = Vector3.new(behindPos.X, floorY, behindPos.Z) end
    if behindPos.Y < mapFloor then behindPos = Vector3.new(behindPos.X, mapFloor, behindPos.Z) end

    local dist = (behindPos - my.Position).Magnitude
    if dist <= 3.5 then return end  -- already there

    _lastHcMoveAt = now
    local aim = F.getAimPos(plr) or (their.Position + Vector3.new(0, 1.35, 0))
    local look = Vector3.new(aim.X, their.Position.Y + 1.15, aim.Z)
    local toLook = look - behindPos
    if Vector3.new(toLook.X, 0, toLook.Z).Magnitude < 0.5 then
        look = look + Vector3.new(0.5, 0, 0.5)
    end
    F.hcSetCF(CFrame.new(behindPos, look), Vector3.zero)
end

-- COMBAT: SHOOT
----------------------------------------------------------------------
function F.shootTarget(plr)
    if not plr or F.isProtected(plr) or not F.isAlive(plr) then return end
    if State.InVoid and not State.VoidEat then State.InVoid = false end
    if State.VoidEat then
        -- wait for heal void to finish (up to recover window), don't force-exit early
        local t0 = tick()
        while State.VoidEat and tick() - t0 < 4 do task.wait(0.1) end
        if State.VoidEat then
            F.exitCombatVoid()
        end
    end

    -- Hood Customs:
    --   FakePos ON  → freeze in slot, aim-only (no CFrame / camera / VIM mid-shot)
    --   FakePos OFF → SLOW TP toward target, then shoot (no hard snaps)
    if IsHoodCustoms then
        local gun = F.findGun()
        if not gun then
            F.notify("No gun: " .. PreferredGun)
            return
        end
        gun = F.equipTool(gun, 0.5)
        if not gun then
            F.notify("Could not equip gun")
            return
        end
        State.Armed = true
        F.setAimLock(plr)
        pcall(F.ensureSilentAim)

        if State.FakePos then
            F.pinFakeFreeze() -- one pin, then zero CFrame writes during shots
        else
            F.softApproachTarget(plr, 1.1) -- slow crawl into range
            F.setCamlock(plr, 3)
        end
        F.reloadGun(gun)
        task.wait(0.06)

        for shot = 1, 8 do
            if not F.isAlive(plr) or F.isKO(plr) then break end
            if State.VoidEat or State.InVoid then break end
            if gun.Parent ~= F.getChar() then
                gun = F.equipTool(F.findGun(), 0.35)
                if not gun then break end
            end
            if State.FakePos then
                -- velocity only — never CFrame while gun is firing
                pcall(function()
                    local my = F.getHRP()
                    if not my then return end
                    my.AssemblyLinearVelocity = Vector3.zero
                    my.AssemblyAngularVelocity = Vector3.zero
                end)
            else
                -- slow step closer between shots (throttled inside hoverOverTarget)
                F.hoverOverTarget(plr)
            end
            local aim = F.getAimPos(plr)
            if not aim then break end
            -- BodyEffects MousePos only (HC-safe). Skip extra MainEvent spam on FakePos.
            pcall(function()
                local be = F.getChar() and F.getChar():FindFirstChild("BodyEffects")
                if not be then return end
                local mp = be:FindFirstChild("MousePos")
                if mp and mp:IsA("Vector3Value") then mp.Value = aim end
            end)
            if not State.FakePos then
                pcall(function() F.fireMouse(aim) end)
            else
                -- FakePos: one light mouse remote max every other shot
                if shot % 2 == 1 then
                    pcall(function() F.fireMouse(aim) end)
                end
            end
            F.activateTool(gun)
            if not State.FakePos then
                pcall(function() F.forceGunHit(plr, gun) end)
            end
            if shot % 4 == 0 then F.reloadGun(gun) end
            task.wait(0.12)
        end
        F.reloadGun(gun)
        F.clearAimLock()
        if State.FakePos then
            F.clearFakeFreeze()
            F.holdFormation(true)
        end
        return
    end

    local gun = F.findGun()
    if not gun then
        F.notify("No gun: " .. PreferredGun)
        return
    end
    gun = F.equipTool(gun, 0.8)
    if not gun then
        F.notify("Could not equip gun")
        return
    end
    State.Armed = true
    F.setAimLock(plr)
    pcall(F.ensureSilentAim)
    if State.FakePos then
        F.holdFormation(true)
    else
        F.setCamlock(plr, 4)
        F.hoverOverTarget(plr)
    end
    F.reloadGun(gun)
    task.wait(0.1)

    local maxShots = IsDersHood and 18 or 16
    for shot = 1, maxShots do
        if not F.isAlive(plr) or F.isKO(plr) then break end
        -- if we got voided mid-fight, wait and resume
        if State.VoidEat or State.InVoid then
            local t0 = tick()
            while (State.VoidEat or State.InVoid) and tick() - t0 < 4 do
                task.wait(0.1)
            end
            if State.VoidEat or State.InVoid then
                F.exitCombatVoid()
            end
            gun = F.equipTool(F.findGun(), 0.5)
            if not gun then break end
            F.setAimLock(plr)
            if not State.FakePos then F.setCamlock(plr, 3) end
        end
        if gun.Parent ~= F.getChar() then
            gun = F.equipTool(F.findGun(), 0.5)
            if not gun then break end
        end

        if not State.FakePos then
            F.hoverOverTarget(plr)
        end
        local aim = F.getAimPos(plr)
        if not aim then break end

        pcall(function() F.fireMouse(aim) end)
        pcall(function()
            local be = F.getChar() and F.getChar():FindFirstChild("BodyEffects")
            local mp = be and be:FindFirstChild("MousePos")
            if mp and mp:IsA("Vector3Value") then mp.Value = aim end
        end)
        -- FakePos: no camera / VIM — only remotes + Activate
        if not State.FakePos then
            if IsDersHood then
                for _ = 1, 2 do pcall(function() F.fireMouse(aim) end) end
                pcall(function()
                    if Camera and Camera.CameraType ~= Enum.CameraType.Scriptable then
                        local origin = Camera.CFrame.Position
                        if (aim - origin).Magnitude >= 1.5 then
                            Camera.CFrame = CFrame.new(origin, aim)
                        end
                    end
                end)
                pcall(function()
                    local sp, onScreen = Camera:WorldToViewportPoint(aim)
                    if onScreen and sp.Z > 0 then
                        local vim = game:GetService("VirtualInputManager")
                        if vim then vim:SendMouseMoveEvent(sp.X, sp.Y, game) end
                    end
                end)
            else
                pcall(function()
                    if Camera and Camera.CameraType ~= Enum.CameraType.Scriptable then
                        local origin = Camera.CFrame.Position
                        if (aim - origin).Magnitude >= 1.5 then
                            Camera.CFrame = CFrame.new(origin, aim)
                        end
                    end
                end)
            end
        end

        F.activateTool(gun)
        pcall(function() F.forceGunHit(plr, gun) end)

        if not State.FakePos then
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
                if vu then vu:ClickButton1(Vector2.new(0, 0)) end
            end)
        end

        if shot % 5 == 0 then
            F.reloadGun(gun)
            task.wait(0.05)
        end
        task.wait(0.07)
    end

    F.reloadGun(gun)
end

-- COMBAT: STOMP
----------------------------------------------------------------------
-- HC stomp mechanic (from decompiled source):
--   The client does a downward raycast from LowerTorso for (UpperTorso.Size.Y * 4.5) studs.
--   The ray must hit a part that IsDescendantOf(workspace.Players).
--   Then it plays a 0.55s animation, fires "Stomp", and waits 0.5s debounce = ~1.05s total.
--   Guard conditions: K.O must be false (OUR stand), Attacking_CLIENT false, Reloading_CLIENT false,
--   Grabbed nil, no GRABBING_CONSTRAINT.
--   So we must: position LowerTorso JUST above the victim, clear our flags, then fire.
----------------------------------------------------------------------
function F.stompTarget(plr, times)
    if not plr then return end
    if IsHoodCustoms then
        times = math.min(times or 8, 6)
    else
        times = times or 16
    end
    State.Tracking = false
    F.clearAimLock()

    -- unequip so Attacking_CLIENT / tool-hold flags are cleared before stomping
    pcall(function()
        local h = F.getHum()
        if h then h:UnequipTools() end
    end)
    State.Armed = false
    task.wait(0.1)  -- give server time to clear equip state

    for i = 1, times do
        if not F.getChar(plr) then break end
        -- stop if target got back up with meaningful health
        if not F.isKO(plr) and i > 2 then
            local h = F.getHum(plr)
            if h and h.Health > 20 then break end
        end

        local my = F.getHRP()
        local myChar = F.getChar()
        local theirChar = F.getChar(plr)
        -- Target the UpperTorso/Torso — that's what the raycast needs to hit
        local standOn = theirChar and (
            theirChar:FindFirstChild("UpperTorso")
            or theirChar:FindFirstChild("Torso")
            or F.getHRP(plr)
        )

        if my and standOn then
            -- HC: position our LowerTorso just above their UpperTorso so the downward
            -- raycast hits them. LowerTorso is roughly 1.0 stud below HRP center,
            -- so set HRP to standOn.Y + 1.5 (LowerTorso ends up at ~standOn.Y + 0.5).
            -- Non-HC: snap directly on top.
            local targetY = standOn.Position.Y + (IsHoodCustoms and 1.5 or 1.8)
            local pos = Vector3.new(standOn.Position.X, targetY, standOn.Position.Z)
            local mapFloor = (Workspace.FallenPartsDestroyHeight or -500) + 30
            if pos.Y < mapFloor then pos = Vector3.new(pos.X, mapFloor, pos.Z) end

            pcall(function()
                local cf = CFrame.new(pos)
                if IsHoodCustoms then
                    -- Snap directly — we need to be ON them, not lerping toward them
                    my.CFrame = cf
                    my.AssemblyLinearVelocity = Vector3.zero
                    my.AssemblyAngularVelocity = Vector3.zero
                else
                    if myChar and myChar.PivotTo then myChar:PivotTo(cf) end
                    my.CFrame = cf
                    my.AssemblyLinearVelocity = Vector3.zero
                    my.AssemblyAngularVelocity = Vector3.zero
                end
            end)
        end

        -- Clear our own BodyEffects flags so the stomp guard doesn't block us
        pcall(function()
            local be = myChar and myChar:FindFirstChild("BodyEffects")
            if not be then return end
            local ac = be:FindFirstChild("Attacking_CLIENT")
            if ac and ac:IsA("BoolValue") then ac.Value = false end
            local rc = be:FindFirstChild("Reloading_CLIENT")
            if rc and rc:IsA("BoolValue") then rc.Value = false end
            local at = be:FindFirstChild("Attacking")
            if at and at:IsA("BoolValue") then at.Value = false end
        end)

        -- Ensure we're upright and not ragdolled (stomp guard checks K.O on our char)
        pcall(function()
            local h = F.getHum()
            if h then
                h.PlatformStand = false
                h.Sit = false
                local st = h:GetState()
                if st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Ragdoll then
                    h:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end
        end)

        -- Brief settle so CFrame registers server-side before the keypress
        task.wait(0.06)

        -- E key — the game's stomp function triggers on KeyCode.E InputBegan
        pcall(function()
            local vim = game:GetService("VirtualInputManager")
            if vim then
                vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                task.wait(0.04)
                vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
            end
        end)

        -- Fire the remote directly as well (belt + suspenders)
        if MainEvent then
            pcall(function() MainEvent:FireServer("Stomp") end)
        end
        if StompEffectEvent then
            pcall(function() StompEffectEvent:FireServer() end)
        end

        -- HC stomp has a hard 1.05s cycle (0.55s anim + 0.5s debounce).
        -- Waiting less than this means the next attempt is blocked by v69=true.
        -- Non-HC is faster.
        task.wait(IsHoodCustoms and 1.1 or 0.14)
    end
end

-- COMBAT: KNIFE / KATANA — controlled strafe + big hitbox + charge swings + stomp
----------------------------------------------------------------------
function F.forceTPTo(plr, offset)
    offset = offset or Vector3.new(0, 0.2, 0)
    local my = F.getHRP()
    local their = F.getHRP(plr)
    if not my or not their then return false end
    local pos = their.Position + offset
    local look = their.Position + Vector3.new(0, 1.0, 0)
    local cf = CFrame.new(pos, look)
    pcall(function()
        local ch = F.getChar()
        if ch and ch.PivotTo then ch:PivotTo(cf) end
        my.CFrame = cf
        my.AssemblyLinearVelocity = Vector3.zero
        my.AssemblyAngularVelocity = Vector3.zero
    end)
    return true
end

-- Soft strafe around target: orbit at human-ish speed so hits land without hard TP spam flags
function F.knifeStrafeOffset(under)
    -- ~2.1 rad/s orbit, radius 1.5–2.2 (fast enough to stay on target, not teleport-spam)
    local t = tick()
    local phase = t * 2.1
    local radius = 1.65 + math.sin(t * 0.95) * 0.45
    local height = under and -1.15 or (0.25 + math.sin(t * 1.4) * 0.2)
    local ox = math.cos(phase) * radius
    local oz = math.sin(phase) * radius
    return Vector3.new(ox, height, oz)
end

function F.knifeTarget(plr)
    if not plr or F.isProtected(plr) then return end
    if State.KnifeBusy then return end
    State.KnifeBusy = true
    State.Tracking = false
    if State.InVoid then State.InVoid = false end

    task.spawn(function()
        local knife = F.findKnife()
        if knife then knife = F.equipTool(knife, 0.6) end
        if not knife then
            F.notify("Knife: equip [Katana]/[Knife] in backpack first")
            State.KnifeBusy = false
            State.Tracking = true
            return
        end
        F.expandKnifeParts(knife)
        F.setAimLock(plr)
        pcall(F.ensureSilentAim)
        F.setCamlock(plr, 10)
        F.notify("Strafe -> " .. plr.Name)

        -- Throttled strafe lock (not every Heartbeat frame — reduces flag risk)
        local under = false
        local lastStrafeAt = 0
        local STRAFE_INTERVAL = 0.09 -- ~11 Hz position updates
        local lockConn
        lockConn = RunService.Heartbeat:Connect(function()
            if not plr or not F.getChar(plr) then return end
            local now = tick()
            if now - lastStrafeAt < STRAFE_INTERVAL then
                -- still refresh aim every frame for hit registration
                local aim = F.getAimPos(plr)
                if aim then pcall(function() F.fireMouse(aim) end) end
                return
            end
            lastStrafeAt = now
            local off = F.knifeStrafeOffset(under)
            F.forceTPTo(plr, off)
            local aim = F.getAimPos(plr)
            if aim then pcall(function() F.fireMouse(aim) end) end
        end)

        -- Keep swinging for full window — do NOT stop after first hit / false KO
        -- Only stop if target character is gone or truly dead (Health <= 0)
        local t0 = tick()
        local swing = 0
        while tick() - t0 < 5.0 do
            local theirChar = F.getChar(plr)
            if not theirChar then break end
            local theirHum = F.getHum(plr)
            if theirHum and theirHum.Health <= 0 then break end

            swing = swing + 1
            -- alternate high / low every few swings (helps connect + looks less robotic)
            under = (swing % 6) >= 4

            -- Re-equip every few swings (tool often unequips after one Activate on these games)
            if not knife or knife.Parent ~= F.getChar() or swing % 3 == 0 then
                local h = F.getHum()
                if h then pcall(function() h:UnequipTools() end) end
                task.wait(0.02)
                knife = F.equipTool(F.findKnife(), 0.35)
                if knife then F.expandKnifeParts(knife) end
            end

            F.forceTPTo(plr, F.knifeStrafeOffset(under))

            local aim = F.getAimPos(plr)
            if aim then
                for _ = 1, 3 do F.fireMouse(aim) end
            end

            F.setAttacking(true)
            if knife and knife.Parent == F.getChar() then
                -- spam Activate — some tools ignore the first click after equip
                for _ = 1, 3 do
                    F.activateTool(knife)
                end
            end
            F.fireHitRemotes(plr)

            pcall(function()
                local vim = game:GetService("VirtualInputManager")
                if vim then
                    vim:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                    task.wait(0.015)
                    vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
                end
            end)
            pcall(function()
                local vu = game:GetService("VirtualUser")
                if vu then vu:ClickButton1(Vector2.new(0, 0)) end
            end)

            -- slightly slower swing cadence than pure spam (still aggressive, less flaggy)
            task.wait(0.07)
        end

        if lockConn then pcall(function() lockConn:Disconnect() end) end
        F.setAttacking(false)

        -- Always stomp after the swing window
        task.wait(0.1)
        if F.getChar(plr) then
            local h = F.getHum(plr)
            if not h or h.Health > 0 then
                F.notify("Stomping " .. plr.Name)
                F.stompTarget(plr, 14)
            end
        end

        F.clearCamlock()
        F.clearAimLock()
        State.KnifeBusy = false
        State.Tracking = true
        F.returnToOwner()
    end)
end

----------------------------------------------------------------------
-- AUTO PERKS
----------------------------------------------------------------------
function F.applyArmorMax()
    pcall(function()
        local c = F.getChar()
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

function F.buyArmor()
    if MainEvent then
        -- BuyArmor + Armor (both used on hood clones)
        pcall(function() MainEvent:FireServer("BuyArmor") end)
        pcall(function() MainEvent:FireServer("Armor") end)
        pcall(function() MainEvent:FireServer("Buy", "Armor") end)
    end
    if UnreliableMainEvent then
        pcall(function() UnreliableMainEvent:FireServer("BuyArmor") end)
        pcall(function() UnreliableMainEvent:FireServer("Armor") end)
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
    F.applyArmorMax()
end

-- Auto-buy armor when current armor drops below threshold (default 80%)
function F.getArmorPercent()
    local c = F.getChar()
    if not c then return 100 end
    local be = c:FindFirstChild("BodyEffects")
    if not be then return 100 end
    local cur, mx = nil, nil
    for _, name in ipairs({"Armor", "CurrentArmor", "Defence", "Defense"}) do
        local v = be:FindFirstChild(name)
        if v and typeof(v.Value) == "number" then
            cur = (cur or 0) + v.Value
        end
    end
    for _, name in ipairs({"MaxArmor", "ArmorMax", "MaxDefence", "MaxDefense"}) do
        local v = be:FindFirstChild(name)
        if v and typeof(v.Value) == "number" and v.Value > 0 then
            mx = v.Value
            break
        end
    end
    if not cur then return 100 end
    -- Da Hood style: armor is often 0–100 already
    if not mx or mx <= 0 then mx = 100 end
    if cur > mx then mx = cur end
    return (cur / mx) * 100
end

local lastArmorBuyAt = 0
function F.armorMaintainTick()
    if IsOwner then return end
    -- Only if AutoArmor/Inf config (not forced for Hood Customs)
    local enabled = Config.AutoArmor or Config.Inf or Config.ArmorMax
    if not enabled then return end
    local pct = F.getArmorPercent()
    local threshold = 50
    if pct <= threshold and (tick() - lastArmorBuyAt) > 1.2 then
        lastArmorBuyAt = tick()
        F.buyArmor()
    end
end

-- Auto heal: when hurt, buy food (BuyItem / shop) + EatFood without full void unless already voiding
local lastAutoHealAt = 0
function F.autoHealTick()
    if IsOwner then return end
    if not State.AutoHeal then return end
    if State.VoidEat then return end -- void heal path already handles eating
    if State.KnifeBusy then return end
    if tick() - lastAutoHealAt < 2.0 then return end
    if not F.getLocalHurt() then return end
    lastAutoHealAt = tick()
    task.spawn(function()
        pcall(function()
            if not F.findFood() then
                F.buyFood()
            end
            if F.findFood() then
                F.eatFood()
            elseif MainEvent and IsHoodCustoms then
                -- remote-only attempt if shop TP failed
                for _, item in ipairs(HC_FOOD_ITEMS) do
                    pcall(function() MainEvent:FireServer("BuyItem", item) end)
                end
                F.fireEatRemotes(F.findFood())
            end
        end)
    end)
end

function F.buyMask()
    if MainEvent then
        pcall(function() MainEvent:FireServer("Mask") end)
        pcall(function() MainEvent:FireServer("BuyMask") end)
    end
end

function F.applyMuscle()
    if not Config.Muscle then return end
    local size = tonumber(Config.MuscleSize) or 15000
    pcall(function()
        local be = F.getChar() and F.getChar():FindFirstChild("BodyEffects")
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

function F.startAutoPerks()
pcall(F.ensureSilentAim)
    if IsOwner then return end
    task.spawn(function()
        local t0 = tick()
        while tick() - t0 < 10 do
            if F.getHRP() then break end
            task.wait(0.3)
        end
        task.wait(0.5)
        if Config.AutoArmor then F.buyArmor() end
        if Config.ArmorMax or Config.Inf then F.applyArmorMax() end
        if Config.AutoMask then F.buyMask() end
        if Config.Muscle then F.applyMuscle() end
        if Config.Inf or Config.ArmorMax then
            while true do
                if Config.Inf or Config.ArmorMax then
                    F.applyArmorMax()
                    -- only buy when below threshold (armorMaintainTick also handles this)
                    if Config.Inf and F.getArmorPercent() <= 80 then
                        F.buyArmor()
                    end
                end
                task.wait(Config.Inf and 2.5 or 4)
            end
        end
    end)
end

----------------------------------------------------------------------
-- COMMANDS
----------------------------------------------------------------------
function F.cmdVoid()
    if IsOwner then return end
    State.InVoid = true
    State.Tracking = false
    F.clearCamlock()
    F.notify("Void ON")
end

function F.cmdCall()
    if IsOwner then return end
    State.InVoid = false
    State.Tracking = true
    F.returnToOwner()
    F.notify("Call - returning")
end

function F.cmdTrack()
    if IsOwner then return end
    State.Tracking = not State.Tracking
    F.notify("Track " .. (State.Tracking and "ON" or "OFF"))
end

function F.cmdAir(arg)
    if arg == "on" or arg == "1" or arg == "true" then
        State.Air = true
    elseif arg == "off" or arg == "0" or arg == "false" then
        State.Air = false
    else
        State.Air = not State.Air
    end
    SLOT_CF = State.Air and SLOT_CF_AIR or SLOT_CF_GROUND
    if not IsOwner and State.Tracking and not State.InVoid then
        F.returnToOwner()
    end
    F.notify("Air " .. (State.Air and "ON (floating)" or "OFF (ground)"))
end

-- .fake / .fp — stay in formation (fake position). Gun kills still work via silent aim + mouse remotes.
-- Character does not hover/TP onto targets. Knife/stomp still need proximity (brief leave).
function F.cmdFake(arg)
    if arg == "on" or arg == "1" or arg == "true" then
        State.FakePos = true
    elseif arg == "off" or arg == "0" or arg == "false" then
        State.FakePos = false
    else
        State.FakePos = not State.FakePos
    end
    if State.FakePos then
        if not IsOwner and not State.InVoid then
            State.Tracking = true
            F.returnToOwner()
            F.pinFakeFreeze()
        end
        F.notify("FakePos ON — freeze in slot, gun aim only (no TP)")
    else
        F.clearFakeFreeze()
        F.notify("FakePos OFF — slow TP to targets")
    end
end

function F.cmdPos(slot)
    local n = tonumber(slot)
    if n and SLOT_CF[n] then
        MySlot = n
        F.notify("Slot " .. n)
    else
        F.notify("Usage: " .. Prefix .. "pos 1-6")
    end
end

function F.cmdArm()
    local g = F.findGun()
    if not g then F.notify("No gun found") return end
    F.stopIdleAnim()
    g = F.equipTool(g, 0.7)
    State.Armed = g ~= nil
    F.notify(State.Armed and ("Armed " .. g.Name) or "Arm failed")
end

function F.cmdUnarm()
    pcall(function()
        local h = F.getHum()
        if h then h:UnequipTools() end
    end)
    State.Armed = false
    task.defer(F.applyIdleAnim)
    F.notify("Unarmed")
end

-- .d — knock only (no stomp)
function F.cmdKnock(user)
    local plr = F.findPlayer(user)
    if not plr then F.notify("Knock: not found (" .. tostring(user) .. ")") return end
    local prot, why = F.isProtected(plr)
    if prot then
        F.notify("Knock: protected (" .. tostring(why) .. " = " .. plr.Name .. ")")
        return
    end
    State.Tracking = false
    F.beginCombat()
    task.spawn(function()
        F.shootTarget(plr)
        local t0 = tick()
        while tick() - t0 < 2.5 do
            if F.isKO(plr) then break end
            if not F.getChar(plr) then break end
            task.wait(0.15)
        end
        if not F.isKO(plr) then
            F.shootTarget(plr)
        end
        F.clearAimLock()
        F.clearCamlock()
        F.endCombat()
        State.Tracking = true
        F.returnToOwner()
    end)
end

-- .s — stomp only
function F.cmdStomp(user)
    local plr = F.findPlayer(user)
    if not plr then F.notify("Stomp: not found") return end
    State.Tracking = false
    F.beginCombat()
    task.spawn(function()
        F.stompTarget(plr, 12)
        F.endCombat()
        State.Tracking = true
        F.returnToOwner()
    end)
end

function F.cmdKnife(user)
    local plr = F.findPlayer(user)
    if not plr then F.notify("Knife: not found (" .. tostring(user) .. ")") return end
    local prot, why = F.isProtected(plr)
    if prot then
        F.notify("Knife: protected (" .. tostring(why) .. " = " .. plr.Name .. ")")
        return
    end
    F.knifeTarget(plr)
end

-- .kat <user> — loop kill with katana/knife + stomp
function F.cmdKat(user)
    local plr = F.findPlayer(user)
    if not plr then F.notify("Kat: not found (" .. tostring(user) .. ")") return end
    local prot, why = F.isProtected(plr)
    if prot then
        F.notify("Kat: protected (" .. tostring(why) .. " = " .. plr.Name .. ")")
        return
    end
    -- reuse loopkill knife mode (knifeTarget + stomp when KO)
    State.LoopKnock = nil
    State.LoopKill = plr.Name
    State.LoopKillKnife = true
    State.LoopKillBusy = false
    State.Tracking = false
    F.beginCombat()
    F.notify("Kat loopkill ON " .. plr.Name .. " (katana/knife + stomp)")
end

-- .b — bring target near owner
-- Steps:
--   1) Knock the target if alive
--   2) Teleport our stand on top of the target
--   3) Press G to pick them up (game's native grab key)
--   4) Walk our stand incrementally to the owner — target is carried via the grab
--   5) Press G again to drop them next to owner
function F.cmdBring(user)
    local plr = F.findPlayer(user)
    if not plr then
        F.notify("Bring: not found (" .. tostring(user) .. ")")
        return
    end
    local prot, why = F.isProtected(plr)
    if prot then
        F.notify("Bring: protected (" .. tostring(why) .. ")")
        return
    end

    State.Tracking = false
    F.beginCombat()

    task.spawn(function()
        local owner = F.getOwner()
        if not owner then
            F.notify("Bring: no owner")
            F.endCombat()
            State.Tracking = true
            F.returnToOwner()
            return
        end

        -- Simulate a G keypress (hold = press+release after delay, tap = instant)
        local function pressG(hold)
            local vim = pcall(function() return game:GetService("VirtualInputManager") end)
                and game:GetService("VirtualInputManager")
            if vim then
                pcall(function() vim:SendKeyEvent(true,  Enum.KeyCode.G, false, game) end)
                task.wait(hold and 0.12 or 0.07)
                pcall(function() vim:SendKeyEvent(false, Enum.KeyCode.G, false, game) end)
            end
            -- Fallback: VirtualUser
            local vu = pcall(function() return game:GetService("VirtualUser") end)
                and game:GetService("VirtualUser")
            if vu then
                pcall(function() vu:SetKeyDown("0x47") end)   -- G
                task.wait(hold and 0.12 or 0.07)
                pcall(function() vu:SetKeyUp("0x47") end)
            end
            -- Also fire the Grabbing remote so the server registers it
            if MainEvent then
                pcall(function() MainEvent:FireServer("Grabbing") end)
            end
            if UnreliableMainEvent then
                pcall(function() UnreliableMainEvent:FireServer("Grabbing") end)
            end
        end

        -- Snap our stand directly onto (just above) the target so G can reach them
        local function snapOntoTarget()
            local theirHRP = F.getHRP(plr)
            local myHRP    = F.getHRP()
            if not theirHRP or not myHRP then return false end
            local grabPos = theirHRP.Position + Vector3.new(0, 1.2, 0)
            pcall(function()
                myHRP.CFrame = CFrame.new(grabPos)
                myHRP.AssemblyLinearVelocity  = Vector3.zero
                myHRP.AssemblyAngularVelocity = Vector3.zero
            end)
            return true
        end

        -- Move our stand one step toward a target position, returns remaining distance
        local function stepToward(targetPos, stepSize)
            local myHRP = F.getHRP()
            if not myHRP then return 0 end
            local myPos  = myHRP.Position
            local dir    = targetPos - myPos
            local dist   = dir.Magnitude
            if dist < 1 then return dist end
            local step   = math.min(stepSize, dist - 1)
            local newPos = myPos + dir.Unit * step
            local safeY  = math.max(newPos.Y, (Workspace.FallenPartsDestroyHeight or -500) + 32)
            newPos = Vector3.new(newPos.X, safeY, newPos.Z)
            pcall(function()
                myHRP.CFrame = CFrame.new(newPos, Vector3.new(targetPos.X, newPos.Y, targetPos.Z))
                myHRP.AssemblyLinearVelocity  = Vector3.zero
                myHRP.AssemblyAngularVelocity = Vector3.zero
            end)
            return (targetPos - newPos).Magnitude
        end

        -- 1) Knock the target first if still alive
        if F.isAlive(plr) and not F.isKO(plr) then
            F.notify("Bring: knocking " .. plr.Name .. "...")
            F.setAimLock(plr)
            pcall(F.ensureSilentAim)
            F.setCamlock(plr, 3)
            F.shootTarget(plr)
            local t0 = tick()
            while tick() - t0 < 3.5 do
                if F.isKO(plr) or not F.getChar(plr) then break end
                task.wait(0.12)
            end
            F.clearCamlock()
            F.clearAimLock()
        end

        if not F.getChar(plr) then
            F.notify("Bring: target gone")
            F.endCombat()
            State.Tracking = true
            F.returnToOwner()
            return
        end

        -- 2) Teleport our stand on top of the knocked target
        F.notify("Bring: picking up " .. plr.Name)
        snapOntoTarget()
        task.wait(0.1)

        -- 3) Press G to grab — retry a few times if needed
        for attempt = 1, 4 do
            snapOntoTarget()         -- stay on top each attempt
            pressG(true)
            task.wait(0.15)
            -- Check if grab registered: target's HRP should now be very close to ours
            local myHRP    = F.getHRP()
            local theirHRP = F.getHRP(plr)
            if myHRP and theirHRP then
                local grabDist = (myHRP.Position - theirHRP.Position).Magnitude
                if grabDist < 4.5 then
                    break   -- grab likely attached
                end
            end
            if attempt < 4 then task.wait(0.1) end
        end

        -- 4) Walk our stand toward the owner in small steps.
        --    Target is attached via the game's grab — they ride with us.
        F.notify("Bring: hauling to owner...")
        local stepSize  = IsHoodCustoms and 3.5 or 5.0
        local stopDist  = 5.0
        local haulUntil = tick() + 7.0

        while tick() < haulUntil do
            local oHRP = F.getHRP(owner)
            if not oHRP then break end
            if not F.getChar(plr) then break end

            local remaining = stepToward(oHRP.Position, stepSize)
            if remaining <= stopDist then break end

            -- Keep re-pressing G every step so the server hold doesn't time out
            pressG(false)
            task.wait(IsHoodCustoms and 0.13 or 0.09)
        end

        -- 5) Press G once more to drop the target next to owner
        task.wait(0.1)
        pressG(true)
        F.notify("Bring: dropped " .. plr.Name .. " at owner")

        F.endCombat()
        State.Tracking = true
        F.returnToOwner()
        F.notify("Bring done → " .. plr.Name)
    end)
end

-- .l — loop kill (shoot + stomp)
function F.cmdLoopKill(user, useKnife)
    local plr = F.findPlayer(user)
    if not plr then F.notify("LoopKill: not found (" .. tostring(user) .. ")") return end
    local prot, why = F.isProtected(plr)
    if prot then
        F.notify("LoopKill: protected (" .. tostring(why) .. " = " .. plr.Name .. ")")
        return
    end
    State.LoopKnock = nil
    State.LoopKill = plr.Name
    State.LoopKillKnife = useKnife and true or false
    State.LoopKillBusy = false
    State.Tracking = false
    F.beginCombat()
    F.notify("LoopKill " .. (useKnife and "knife " or "gun ") .. "ON " .. plr.Name)
end

-- .lk — loop knock only (no stomp)
function F.cmdLoopKnock(user)
    local plr = F.findPlayer(user)
    if not plr then F.notify("LoopKnock: not found (" .. tostring(user) .. ")") return end
    local prot, why = F.isProtected(plr)
    if prot then
        F.notify("LoopKnock: protected (" .. tostring(why) .. ")")
        return
    end
    State.LoopKill = nil
    State.LoopKillKnife = false
    State.LoopKnock = plr.Name
    State.LoopKillBusy = false
    State.Tracking = false
    F.beginCombat()
    F.notify("LoopKnock ON " .. plr.Name)
end

function F.cmdUnLoopKill()
    State.LoopKill = nil
    State.LoopKillKnife = false
    State.LoopKnock = nil
    State.LoopKillBusy = false
    F.endCombat()
    F.clearCamlock()
    if not IsOwner then State.Tracking = true end
    F.notify("Loop OFF")
end

function F.parseOnOff(arg, current)
    if arg == "on" or arg == "1" or arg == "true" then return true end
    if arg == "off" or arg == "0" or arg == "false" then return false end
    return not current
end

function F.baselineSentryPlayer(plr)
    if not plr then return end
    local hum = F.getHum(plr)
    if not hum then return end
    HealthWatch[plr.UserId] = hum.Health
    KoWatch[plr.UserId] = F.isKO(plr)
    local armor = 0
    local c = F.getChar(plr)
    local be = c and c:FindFirstChild("BodyEffects")
    if be then
        for _, name in ipairs({"Armor", "Defence", "Defense", "Helmet", "CurrentArmor"}) do
            local v = be:FindFirstChild(name)
            if v and typeof(v.Value) == "number" then armor = armor + v.Value end
        end
    end
    ArmorWatch[plr.UserId] = armor
end

function F.cmdSentry(arg)
    State.Sentry = F.parseOnOff(arg, State.Sentry)
    if State.Sentry then State.Sentry2 = false end
    local o = F.getOwner()
    F.baselineSentryPlayer(o)
    F.notify("Sentry " .. (State.Sentry and "ON" or "OFF")
        .. " (knock who shoots owner)"
        .. (State.Sentry and (o and (" | owner=" .. o.Name) or " | WARNING: no owner set") or ""))
end

function F.cmdSentry2(arg)
    State.Sentry2 = F.parseOnOff(arg, State.Sentry2)
    if State.Sentry2 then State.Sentry = false end
    local o = F.getOwner()
    F.baselineSentryPlayer(o)
    F.notify("Sentry2 " .. (State.Sentry2 and "ON" or "OFF")
        .. " (knock+stomp who shoots owner)"
        .. (State.Sentry2 and (o and (" | owner=" .. o.Name) or " | WARNING: no owner set") or ""))
end

local BSentryConn = nil
local BSentryCharConn = nil

function F.hookBSentryLocal()
    if BSentryConn then pcall(function() BSentryConn:Disconnect() end) BSentryConn = nil end
    if BSentryCharConn then pcall(function() BSentryCharConn:Disconnect() end) BSentryCharConn = nil end
    if not State.BSentry then return end

    local function attach(hum)
        if not hum then return end
        F.baselineSentryPlayer(LocalPlayer)
        if BSentryConn then pcall(function() BSentryConn:Disconnect() end) end
        local last = hum.Health
        BSentryConn = hum.HealthChanged:Connect(function(hp)
            if not State.BSentry then return end
            if hp < last - 0.5 or F.isKO(LocalPlayer) then
                last = hp
                -- immediate reaction on local damage (most reliable)
                task.defer(function()
                    if State.SentryBusy then return end
                    F.onVictimDamaged(LocalPlayer, true)
                end)
            else
                last = hp
            end
        end)
    end

    attach(F.getHum(LocalPlayer))
    BSentryCharConn = LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.5)
        if State.BSentry then attach(F.getHum(LocalPlayer)) end
    end)
end

function F.cmdBSentry(arg)
    State.BSentry = F.parseOnOff(arg, State.BSentry)
    F.baselineSentryPlayer(LocalPlayer)
    F.hookBSentryLocal()
    F.notify("BSentry " .. (State.BSentry and "ON" or "OFF") .. " (knock+stomp who shoots stand)")
end

function F.cmdAssist(user)
    local plr = F.findPlayer(user)
    if not plr then F.notify("Assist: not found") return end
    State.AssistName = plr.Name
    F.baselineSentryPlayer(plr)
    F.notify("Assist ON " .. plr.Name .. " (sentry covers them too)")
end

function F.cmdUnassist()
    State.AssistName = nil
    F.notify("Assist OFF")
end

function F.cmdSay(msg)
    if not msg or msg == "" then
        F.notify("Usage: " .. Prefix .. "say <message>")
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
            chat:Chat(F.getChar() or LocalPlayer, msg)
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
function F.sentryReact(plr, doStomp)
    if not plr or F.isProtected(plr) then return end
    if plr == LocalPlayer then return end
    if not F.isAlive(plr) and not F.isKO(plr) then return end
    if State.SentryBusy then return end
    State.SentryBusy = true
    State.Tracking = false
    F.beginCombat()
    F.notify("Sentry → " .. plr.Name .. (doStomp and " (stomp)" or ""))
    task.spawn(function()
        local ok, err = pcall(function()
            -- if WE are knocked, try to stand back up so we can shoot
            pcall(function()
                local h = F.getHum()
                if h and (h.PlatformStand or F.isKO(LocalPlayer)) then
                    h.PlatformStand = false
                    h:ChangeState(Enum.HumanoidStateType.GettingUp)
                    h:ChangeState(Enum.HumanoidStateType.Running)
                end
            end)
            task.wait(0.05)

            if F.isKO(plr) and doStomp then
                F.stompTarget(plr, 14)
            else
                F.setCamlock(plr, 4)
                F.setAimLock(plr)
                -- force arm + shoot even if we just took damage
                local gun = F.findGun()
                if gun then
                    F.stopIdleAnim()
                    F.equipTool(gun, 0.5)
                    State.Armed = true
                end
                F.shootTarget(plr)
                local t0 = tick()
                while tick() - t0 < 2.8 do
                    if F.isKO(plr) then break end
                    if not F.getChar(plr) then break end
                    task.wait(0.1)
                end
                if doStomp then
                    if F.isKO(plr) then
                        F.stompTarget(plr, 14)
                    else
                        F.shootTarget(plr)
                        task.wait(0.35)
                        if F.isKO(plr) then F.stompTarget(plr, 12) end
                    end
                end
            end
        end)
        if not ok then warn("[Stand] F.sentryReact:", err) end
        F.clearAimLock()
        F.clearCamlock()
        F.endCombat()
        State.Tracking = true
        F.returnToOwner()
        task.wait(0.2)
        State.SentryBusy = false
    end)
end

function F.resolvePlayerFromValue(val)
    if not val then return nil end
    if typeof(val) == "Instance" then
        if val:IsA("Player") then return val end
        if val:IsA("Model") then return Players:GetPlayerFromCharacter(val) end
        if val:IsA("ObjectValue") and val.Value then
            return F.resolvePlayerFromValue(val.Value)
        end
    elseif type(val) == "string" then
        return F.findPlayer(val)
    elseif type(val) == "number" then
        return Players:GetPlayerByUserId(val)
    end
    return nil
end

-- Find who most likely shot `victim`
function F.findAttacker(victim)
    if not victim then return nil end
    local char = F.getChar(victim)
    local hum = F.getHum(victim)

    -- 1) Creator / attacker tags on humanoid & character
    if hum then
        for _, inst in ipairs(hum:GetChildren()) do
            local n = string.lower(inst.Name)
            if n:find("creat") or n:find("attack") or n:find("kill") or n:find("hit") or n:find("shoot") then
                local p = F.resolvePlayerFromValue(inst.Value or inst)
                if p and p ~= victim and p ~= LocalPlayer and not F.isProtected(p) then return p end
            end
        end
    end
    if char then
        local be = char:FindFirstChild("BodyEffects")
        if be then
            for _, inst in ipairs(be:GetDescendants()) do
                local n = string.lower(inst.Name)
                if n:find("creat") or n:find("attack") or n:find("kill") or n:find("shoot") or n:find("last") then
                    local p = F.resolvePlayerFromValue(inst.Value)
                    if p and p ~= victim and p ~= LocalPlayer and not F.isProtected(p) then return p end
                end
            end
        end
        for _, inst in ipairs(char:GetChildren()) do
            local n = string.lower(inst.Name)
            if n:find("creat") or n:find("attack") then
                local p = F.resolvePlayerFromValue(inst.Value)
                if p and p ~= victim and p ~= LocalPlayer and not F.isProtected(p) then return p end
            end
        end
    end

    -- 2) Player looking at victim with a gun equipped (most reliable fallback)
    local vHRP = F.getHRP(victim)
    if not vHRP then return nil end
    local best, bestScore = nil, -1
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= victim and plr ~= LocalPlayer and not F.isProtected(plr) and F.isAlive(plr) then
            local hrp = F.getHRP(plr)
            local ch = F.getChar(plr)
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
        if plr ~= victim and plr ~= LocalPlayer and not F.isProtected(plr) and F.isAlive(plr) then
            local hrp = F.getHRP(plr)
            local ch = F.getChar(plr)
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

function F.readArmor(plr)
    local c = F.getChar(plr)
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

function F.onVictimDamaged(victim, doStomp)
    if State.SentryBusy then return end
    if tick() - LastSentryAt < 0.45 then return end
    local attacker = F.findAttacker(victim)
    if not attacker then
        -- last resort: any armed player within 100 studs of victim
        local vHRP = F.getHRP(victim)
        if vHRP then
            local best, bestD = nil, 100
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= victim and plr ~= LocalPlayer and not F.isProtected(plr) and F.isAlive(plr) then
                    local hrp = F.getHRP(plr)
                    local ch = F.getChar(plr)
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
        F.sentryReact(attacker, doStomp)
    else
        F.notify("Sentry: damage on " .. (victim and victim.Name or "?") .. " — no shooter found")
    end
end

-- Multi-signal poll: health, KO, armor (Da Hood style)
function F.sentryTick()
    if IsOwner then return end
    if State.SentryBusy then return end
    if not (State.Sentry or State.Sentry2 or State.BSentry) then return end

    local function check(plr, doStomp)
        if not plr then return end
        local hum = F.getHum(plr)
        local char = F.getChar(plr)
        if not hum or not char then return end
        local key = plr.UserId

        local hp = hum.Health
        local prevHp = HealthWatch[key]
        local knocked = F.isKO(plr)
        local wasKO = KoWatch[key]
        local armor = F.readArmor(plr)
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
            F.onVictimDamaged(plr, doStomp)
        end
    end

    local owner = F.getOwner()
    if owner and (State.Sentry or State.Sentry2) then
        check(owner, State.Sentry2 and true or false)
    end
    if State.BSentry then
        check(LocalPlayer, true)
    end
    if State.AssistName and (State.Sentry or State.Sentry2 or State.BSentry) then
        local ap = F.findPlayer(State.AssistName)
        if ap then
            check(ap, (State.Sentry2 or State.BSentry) and true or false)
        end
    end
end

function F.refreshSentryWatches()
    local function baseline(plr)
        if not plr then return end
        local hum = F.getHum(plr)
        if not hum then return end
        HealthWatch[plr.UserId] = hum.Health
        KoWatch[plr.UserId] = F.isKO(plr)
        ArmorWatch[plr.UserId] = F.readArmor(plr)
    end
    baseline(F.getOwner())
    baseline(LocalPlayer)
    if State.AssistName then
        baseline(F.findPlayer(State.AssistName))
    end
end

-- MoonStand-style kill cycle:
-- close-range pressure → shoot until KO → hard stomp until dead → re-engage on get-up/respawn
-- Hood Customs: soft position (no PivotTo spam) — hard CFrame snaps trigger ERROR_CLIENT_UNSYNCED_SERVER
local _lastMoonPosAt = 0
function F.moonCloseHover(plr)
    if State.VoidEat or State.InVoid then return end
    if State.FakePos then return end -- stay in formation; silent aim still hits
    local my = F.getHRP()
    local their = F.getHRP(plr)
    if not my or not their then return end
    local aim = F.getAimPos(plr) or (their.Position + Vector3.new(0, 1.4, 0))

    -- HC: snap directly behind target, throttled. No orbit = no jitter between shots.
    if IsHoodCustoms then
        local now = tick()
        if now - _lastMoonPosAt < 0.35 then return end

        -- Behind position relative to where they face
        local behindCF = their.CFrame * CFrame.new(0, 1.6, 2.2)
        local behindPos = behindCF.Position
        local floorY2 = their.Position.Y + 1.0
        local mapFloor2 = (Workspace.FallenPartsDestroyHeight or -500) + 30
        if behindPos.Y < floorY2 then behindPos = Vector3.new(behindPos.X, floorY2, behindPos.Z) end
        if behindPos.Y < mapFloor2 then behindPos = Vector3.new(behindPos.X, mapFloor2, behindPos.Z) end

        local dist = (behindPos - my.Position).Magnitude
        if dist <= 3.5 then return end  -- already behind them, don't move

        _lastMoonPosAt = now
        local look = Vector3.new(aim.X, their.Position.Y + 1.1, aim.Z)
        local toLook = look - behindPos
        if Vector3.new(toLook.X, 0, toLook.Z).Magnitude < 0.5 then
            look = look + Vector3.new(0.5, 0, 0.5)
        end
        pcall(function()
            my.CFrame = CFrame.new(behindPos, look)
            my.AssemblyLinearVelocity = Vector3.zero
            my.AssemblyAngularVelocity = Vector3.zero
        end)
        return
    end

    -- other places: snap directly behind target, only when needed.
    -- No side-oscillation — just clean behind position facing them.
    local behindCF = their.CFrame * CFrame.new(0, 1.6, 2.2)
    local behindPos = behindCF.Position
    local floorY = their.Position.Y + 1.0
    if behindPos.Y < floorY then
        behindPos = Vector3.new(behindPos.X, floorY, behindPos.Z)
    end
    local vel2 = their.AssemblyLinearVelocity or Vector3.zero
    local speed2 = vel2.Magnitude
    local dist2 = (behindPos - my.Position).Magnitude
    -- Only snap if far away OR target is actively moving
    local needsSnap2 = dist2 > 4 or speed2 > 3
    pcall(function()
        if needsSnap2 then
            local cf = CFrame.new(behindPos, aim)
            local ch = F.getChar()
            if ch and ch.PivotTo then ch:PivotTo(cf) end
            my.CFrame = cf
        end
        my.AssemblyLinearVelocity = Vector3.zero
        my.AssemblyAngularVelocity = Vector3.zero
    end)
end

function F.moonShootBurst(plr, maxShots)
    if not plr or not F.isAlive(plr) then return end
    local gun = F.findGun()
    if not gun then return end
    gun = F.equipTool(gun, 0.5)
    if not gun then return end
    State.Armed = true
    F.setAimLock(plr)
    pcall(F.ensureSilentAim)
    F.setCamlock(plr, 3)
    maxShots = maxShots or (IsHoodCustoms and 6 or 12)

    for shot = 1, maxShots do
        if not State.LoopKill and not State.LoopKnock then break end
        if not F.isAlive(plr) or F.isKO(plr) then break end
        if State.VoidEat or State.InVoid then break end

        F.moonCloseHover(plr)
        local aim = F.getAimPos(plr)
        if not aim then break end

        if IsHoodCustoms then
            pcall(function()
                local be = F.getChar() and F.getChar():FindFirstChild("BodyEffects")
                local mp = be and be:FindFirstChild("MousePos")
                if mp and mp:IsA("Vector3Value") then mp.Value = aim end
            end)
            if shot % 2 == 1 then
                pcall(function() F.fireMouse(aim) end)
            end
        else
            pcall(function() F.fireMouse(aim) end)
            pcall(function()
                local be = F.getChar() and F.getChar():FindFirstChild("BodyEffects")
                local mp = be and be:FindFirstChild("MousePos")
                if mp and mp:IsA("Vector3Value") then mp.Value = aim end
            end)
        end

        if gun.Parent ~= F.getChar() then
            gun = F.equipTool(F.findGun(), 0.3)
            if not gun then break end
        end
        F.activateTool(gun)
        pcall(function() F.forceGunHit(plr, gun) end)

        if not IsHoodCustoms then
            pcall(function()
                local vim = game:GetService("VirtualInputManager")
                if vim then
                    vim:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                    task.wait(0.012)
                    vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
                end
            end)
        end

        if shot % 4 == 0 then
            F.reloadGun(gun)
        end
        task.wait(IsHoodCustoms and 0.09 or 0.055)
    end
end

function F.moonStompHard(plr)
    if not plr then return end
    -- HC: one lighter stomp pass (hard multi-TP stomp = CLIENT_UNSYNCED_SERVER)
    if IsHoodCustoms then
        if not F.getChar(plr) then return end
        F.stompTarget(plr, 6)
        return
    end
    for pass = 1, 3 do
        if not State.LoopKill then break end
        if not F.getChar(plr) then break end
        if F.isAlive(plr) and not F.isKO(plr) then break end
        F.stompTarget(plr, 12)
        task.wait(0.08)
        if F.isAlive(plr) and not F.isKO(plr) then break end
    end
end

----------------------------------------------------------------------
-- HOOD CUSTOMS: soft surface shoot only (no underground, no hard TP)
----------------------------------------------------------------------
function F.hcShootBurst(plr, maxShots)
    if not plr or not F.isAlive(plr) then return end
    local gun = F.findGun()
    if not gun then return end
    gun = F.equipTool(gun, 0.4)
    if not gun then return end
    State.Armed = true
    F.setAimLock(plr)
    pcall(F.ensureSilentAim)
    if State.FakePos then
        F.pinFakeFreeze()
    else
        F.softApproachTarget(plr, 0.9)
        F.setCamlock(plr, 2)
    end
    maxShots = maxShots or 6

    for shot = 1, maxShots do
        if not State.LoopKill and not State.LoopKnock and not State.CombatActive then break end
        if not F.isAlive(plr) or F.isKO(plr) then break end
        if State.VoidEat or State.InVoid then break end

        if State.FakePos then
            pcall(function()
                local my = F.getHRP()
                if my then
                    my.AssemblyLinearVelocity = Vector3.zero
                    my.AssemblyAngularVelocity = Vector3.zero
                end
            end)
        else
            F.hoverOverTarget(plr)
        end

        local aim = F.getAimPos(plr)
        if not aim then break end

        pcall(function()
            local be = F.getChar() and F.getChar():FindFirstChild("BodyEffects")
            local mp = be and be:FindFirstChild("MousePos")
            if mp and mp:IsA("Vector3Value") then mp.Value = aim end
        end)
        if not State.FakePos or (shot % 2 == 1) then
            pcall(function() F.fireMouse(aim) end)
        end

        if gun.Parent ~= F.getChar() then
            gun = F.equipTool(F.findGun(), 0.3)
            if not gun then break end
        end
        F.activateTool(gun)
        if not State.FakePos then
            pcall(function() F.forceGunHit(plr, gun) end)
        end

        if shot % 4 == 0 then
            F.reloadGun(gun)
        end
        task.wait(0.14)
    end
end

-- Full HC kill pass: slow approach + shoot (FakePos = freeze + aim only)
function F.hcKillCycle(plr)
    if not plr then return end
    F.beginCombat()
    F.setAimLock(plr)
    pcall(F.ensureSilentAim)

    local gun = F.findGun()
    if gun then
        F.equipTool(gun, 0.4)
        State.Armed = true
        F.reloadGun(gun)
    end

    if State.FakePos then
        F.pinFakeFreeze()
    else
        F.softApproachTarget(plr, 1.0)
    end

    local t0 = tick()
    while tick() - t0 < 12 do
        if not State.LoopKill and not State.LoopKnock and not State.CombatActive then break end
        if not F.getChar(plr) then break end
        if F.isKO(plr) or not F.isAlive(plr) then break end
        if State.VoidEat or State.InVoid then
            local w = tick()
            while (State.VoidEat or State.InVoid) and tick() - w < 3 do task.wait(0.08) end
            if State.VoidEat or State.InVoid then F.exitCombatVoid() end
        end

        if not State.FakePos then
            F.hoverOverTarget(plr)
        end
        F.hcShootBurst(plr, 6)

        if F.isKO(plr) or not F.isAlive(plr) then break end
        task.wait(0.08)
    end

    if F.isKO(plr) and not State.FakePos then
        F.hoverOverTarget(plr)
        task.wait(0.05)
        F.moonStompHard(plr)
    elseif F.isKO(plr) and State.FakePos then
        -- FakePos: still try a light stomp then snap back to slot
        F.moonStompHard(plr)
        F.holdFormation(true)
    end
end

-- One full attack cycle for loopkill (gun or knife).
function F.loopKillCycle(plr)
    if not plr then return end
    if State.LoopKillKnife then
        if State.KnifeBusy then return end
        F.knifeTarget(plr)
        local t0 = tick()
        while State.KnifeBusy and tick() - t0 < 12 and State.LoopKill do
            task.wait(0.15)
        end
        if F.isKO(plr) then
            F.moonStompHard(plr)
        end
    else
        if IsHoodCustoms then
            -- HC: soft surface hover + shoot (no underground / no hard TP)
            F.hcKillCycle(plr)
        else
            local t0 = tick()
            while State.LoopKill and tick() - t0 < 6 do
                if not F.getChar(plr) then break end
                if F.isKO(plr) then break end
                if not F.isAlive(plr) then break end
                F.moonShootBurst(plr, 7)
                if F.isKO(plr) then break end
                task.wait(0.05)
            end
            if F.isKO(plr) or (F.getHum(plr) and F.getHum(plr).Health <= 0) then
                F.moonStompHard(plr)
            elseif F.isAlive(plr) then
                F.shootTarget(plr)
                if F.isKO(plr) then F.moonStompHard(plr) end
            end
        end
    end
end

function F.cmdSweep()
    if State.Sweep then
        F.notify("Sweep already ON")
        return
    end
    State.Sweep = true
    State.Tracking = false
    F.notify("Sweep ON — clearing server")
    task.spawn(function()
        while State.Sweep do
            local targets = {}
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer and not F.isProtected(plr) then
                    if F.isAlive(plr) or F.isKO(plr) then
                        targets[#targets + 1] = plr
                    end
                end
            end
            if #targets == 0 then
                task.wait(1)
            else
                for _, plr in ipairs(targets) do
                    if not State.Sweep then break end
                    if F.isProtected(plr) then continue end
                    if F.isKO(plr) then
                        F.stompTarget(plr, 10)
                    elseif F.isAlive(plr) then
                        F.setAimLock(plr)
                        pcall(F.ensureSilentAim)
                        F.setCamlock(plr, 3)
                        F.shootTarget(plr)
                        local t0 = tick()
                        while tick() - t0 < 2 and State.Sweep do
                            if F.isKO(plr) then break end
                            if not F.getChar(plr) then break end
                            task.wait(0.15)
                        end
                        if F.isKO(plr) then
                            F.stompTarget(plr, 12)
                        end
                    end
                    task.wait(0.2)
                end
            end
            task.wait(0.35)
        end
        F.clearAimLock()
        F.clearCamlock()
        State.Tracking = true
        F.returnToOwner()
        F.notify("Sweep OFF")
    end)
end

function F.cmdUnSweep()
    State.Sweep = false
    F.notify("Sweep stopping...")
end

function F.cmdProtect(user)
    local plr = F.findPlayer(user)
    if not plr then F.notify("Protect: not found") return end
    State.ProtectName = plr.Name
    F.notify("Protect " .. plr.Name)
end

function F.cmdUnprotect()
    State.ProtectName = nil
    F.notify("Protect OFF")
end

function F.cmdWL(user)
    local plr = F.findPlayer(user)
    if not plr then F.notify("WL: not found") return end
    Whitelist[plr.UserId] = true
    F.notify("WL " .. plr.Name)
end

function F.cmdUWL(user)
    if user and user ~= "" then
        local plr = F.findPlayer(user)
        if plr then
            Whitelist[plr.UserId] = nil
            F.notify("UWL " .. plr.Name)
            return
        end
    end
    Whitelist = {}
    F.notify("WL cleared")
end

function F.cmdTarget(user)
    local plr = F.findPlayer(user)
    if not plr then F.notify("Target: not found") return end
    if F.isProtected(plr) then F.notify("Target: protected") return end
    State.TargetName = plr.Name
    F.setCamlock(plr, 0)
    F.notify("Target " .. plr.Name)
end

function F.cmdUntarget()
    State.TargetName = nil
    F.clearCamlock()
    F.notify("Target OFF")
end

function F.cmdArmor()
    F.buyArmor()
    F.notify("Armor")
end

function F.cmdMask()
    F.buyMask()
    F.notify("Mask")
end

function F.cmdFix()
    -- Full reset + real respawn (HC uses MainEvent RespawnCharacter / ResetCharacter)
    F.notify("Fix — respawning...")
    F.clearCamlock()
    F.clearAimLock()
    pcall(function() RunService:UnbindFromRenderStep("StandVoidPin") end)
    pcall(function() RunService:UnbindFromRenderStep(CAM_BIND) end)

    State.LoopKill = nil
    State.LoopKillKnife = false
    State.LoopKnock = nil
    State.LoopKillBusy = false
    State.Sweep = false
    State.TargetName = nil
    State.KnifeBusy = false
    State.SentryBusy = false
    State.InVoid = false
    State.VoidEat = false
    State.CombatActive = false
    State.Tracking = false
    State.Armed = false
    VoidRecoverUntil = 0
    VoidMinUntil = 0
    VoidBloodAtEnter = nil
    _voidEnterBusy = false
    F.setAttacking(false)

    local oldChar = F.getChar()
    local oldHum = F.getHum()

    pcall(function()
        if oldHum then
            oldHum.PlatformStand = false
            oldHum.Sit = false
            pcall(function() oldHum:UnequipTools() end)
        end
    end)

    -- 1) Game-native respawn remotes (Hood Customs + most hood clones)
    if MainEvent then
        pcall(function() MainEvent:FireServer("RespawnCharacter") end)
        pcall(function() MainEvent:FireServer("ResetCharacter") end)
        pcall(function() MainEvent:FireServer("GiveUp") end)
        pcall(function() MainEvent:FireServer("RequestKOUpdate") end)
    end
    if UnreliableMainEvent then
        pcall(function() UnreliableMainEvent:FireServer("RespawnCharacter") end)
        pcall(function() UnreliableMainEvent:FireServer("ResetCharacter") end)
    end
    if MainFunction then
        pcall(function() MainFunction:InvokeServer("RespawnCharacter") end)
        pcall(function() MainFunction:InvokeServer("ResetCharacter") end)
    end

    -- 2) Fallback: kill humanoid so server respawns
    pcall(function()
        if oldHum and oldHum.Health > 0 then
            oldHum.Health = 0
        end
    end)

    -- 3) Last resort LoadCharacter (often blocked on custom char systems)
    task.delay(0.35, function()
        if F.getChar() == oldChar then
            pcall(function() LocalPlayer:LoadCharacter() end)
        end
    end)

    task.spawn(function()
        -- wait until character actually changes / is alive
        local t0 = tick()
        local newChar = nil
        while tick() - t0 < 10 do
            local c = F.getChar()
            local h = F.getHum()
            if c and c ~= oldChar and h and h.Health > 0 then
                newChar = c
                break
            end
            -- if same char recovered somehow, still accept if alive + HRP
            if c and h and h.Health > 0 and F.getHRP() and (tick() - t0) > 1.5 then
                newChar = c
                break
            end
            -- keep pressing respawn if stuck
            if MainEvent and (tick() - t0) > 2 and (math.floor((tick() - t0) * 2) % 3 == 0) then
                pcall(function() MainEvent:FireServer("RespawnCharacter") end)
                pcall(function() MainEvent:FireServer("ResetCharacter") end)
            end
            task.wait(0.15)
        end

        task.wait(0.4)

        -- clean humanoid state
        pcall(function()
            local h = F.getHum()
            if h then
                h.PlatformStand = false
                h.Sit = false
                h.WalkSpeed = 16
                h.JumpPower = 50
                pcall(function() h.JumpHeight = 7.2 end)
                h:ChangeState(Enum.HumanoidStateType.GettingUp)
                h:ChangeState(Enum.HumanoidStateType.Running)
                h:UnequipTools()
            end
        end)

        -- re-apply perks after respawn
        if Config.AutoArmor then pcall(F.buyArmor) end
        if Config.ArmorMax or Config.Inf then pcall(F.applyArmorMax) end
        if Config.AutoMask then pcall(F.buyMask) end
        if Config.Muscle then pcall(F.applyMuscle) end

        State.Tracking = true
        State.InVoid = false
        State.VoidEat = false
        State.CombatActive = false
        State.KnifeBusy = false
        State.LoopKillBusy = false
        State.SentryBusy = false

        if not IsOwner then
            for _ = 1, 6 do
                pcall(F.returnToOwner)
                task.wait(0.08)
            end
        end

        F.notify(newChar and "Fix — respawned" or "Fix — reset (respawn may be delayed)")
    end)
end

function F.cmdKick()
    -- Rejoin: TeleportAsync is the modern API and does NOT trigger "restricted experience"
    -- errors that the old Teleport/TeleportToPlaceInstance do on most hood games.
    F.notify("Rejoining...")
    task.spawn(function()
        task.wait(0.25)
        -- Try same server first (TeleportAsync with job id), fall back to any server
        local placeId = game.PlaceId
        local jobId   = game.JobId
        local opts = Instance.new("TeleportOptions")

        local ok = false
        -- Attempt 1: same server (requires a valid JobId)
        if jobId and jobId ~= "" then
            pcall(function()
                opts.ServerInstanceId = jobId
                ok = true
            end)
            if ok then
                ok = false
                pcall(function()
                    TeleportService:TeleportAsync(placeId, {LocalPlayer}, opts)
                    ok = true
                end)
            end
        end

        -- Attempt 2: any server in the same place
        if not ok then
            pcall(function()
                local opts2 = Instance.new("TeleportOptions")
                TeleportService:TeleportAsync(placeId, {LocalPlayer}, opts2)
                ok = true
            end)
        end

        -- Attempt 3: last resort – old API (may show error on some places but won't crash)
        if not ok then
            pcall(function()
                TeleportService:Teleport(placeId)
            end)
        end
    end)
end

function F.cmdBuyFood()
    State.Tracking = false
    F.notify("Buying food...")
    task.spawn(function()
        local ok, err = pcall(function()
            local had = F.findFood() ~= nil
            if not had then
                F.buyFood()
            end
            task.wait(0.25)
            if F.findFood() then
                F.notify("Food ready: " .. tostring(F.findFood().Name))
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
                if F.findFood() then
                    F.notify("Food ready: " .. tostring(F.findFood().Name))
                else
                    F.notify("No food — try near shop")
                end
            end
        end)
        if not ok then warn("[Stand] buyfood:", err) end
        if not State.CombatActive and not State.VoidEat then
            State.Tracking = true
            F.returnToOwner()
        end
    end)
end

function F.cmdHeal()
    if State.VoidEat then
        F.notify("Already healing")
        return
    end
    F.notify("Heal — void + eat")
    State.Tracking = false
    task.spawn(function()
        local ok, err = pcall(function()
            -- force combat-void style heal even outside combat
            local wasCombat = State.CombatActive
            State.CombatActive = true
            F.enterCombatVoid()
            -- wait until void heal finishes (exitCombatVoid clears VoidEat)
            local t0 = tick()
            while State.VoidEat and tick() - t0 < 6 do
                task.wait(0.15)
            end
            if State.VoidEat then
                F.exitCombatVoid()
            end
            if not wasCombat then
                State.CombatActive = false
            end
            -- ensure out of void and near owner/target
            F.warpOutOfVoid()
            if not State.CombatActive then
                State.Tracking = true
                F.returnToOwner()
            end
            F.notify("Heal done")
        end)
        if not ok then
            warn("[Stand] heal:", err)
            pcall(F.exitCombatVoid)
            State.Tracking = true
        end
    end)
end

function F.cmdHelp()
    F.notify("See F9 for command list")
    print("[Stand] Commands:")
    print("  " .. Prefix .. "void / call / track / air [on|off] / pos <1-6>")
    print("  " .. Prefix .. "fake [on|off] / fp  -- stay in formation; gun kills still work")
    print("  " .. Prefix .. "arm / unarm")
    print("  " .. Prefix .. "d <user>   -- knock")
    print("  " .. Prefix .. "b <user>   -- bring")
    print("  " .. Prefix .. "s <user>   -- stomp")
    print("  " .. Prefix .. "l <user>   -- loop kill (gun + stomp)")
    print("  " .. Prefix .. "lk <user>  -- loop knock")
    print("  " .. Prefix .. "kat <user> -- loop kill katana/knife + stomp")
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
    print("  " .. Prefix .. "autoheal [on|off]  -- auto buy+eat when hurt (HC: BuyItem/EatFood)")
    print("  " .. Prefix .. "reload / autoreload / fix / kick / help")
end

----------------------------------------------------------------------
-- CHAT HANDLER
----------------------------------------------------------------------
function F.onControlChat(msg, speaker)
    if type(msg) ~= "string" then return end
    if not F.canControl(speaker) then return end

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

    if cmd == "void" then F.cmdVoid()
    elseif cmd == "call" or cmd == "come" then F.cmdCall()
    elseif cmd == "track" or cmd == "follow" then F.cmdTrack()
    elseif cmd == "air" or cmd == "float" or cmd == "summon" then F.cmdAir(a1)
    elseif cmd == "fake" or cmd == "fp" or cmd == "fakepos" then F.cmdFake(a1)
    elseif cmd == "pos" or cmd == "slot" then F.cmdPos(a1)
    elseif cmd == "arm" then F.cmdArm()
    elseif cmd == "unarm" then F.cmdUnarm()
    -- combat shortcuts
    elseif cmd == "d" or cmd == "knock" or cmd == "k" then F.cmdKnock(a1)
    elseif cmd == "b" or cmd == "bring" then F.cmdBring(a1)
    elseif cmd == "s" or cmd == "stomp" then F.cmdStomp(a1)
    elseif cmd == "l" or cmd == "loopkill" then F.cmdLoopKill(a1, false)
    elseif cmd == "lk" then F.cmdLoopKnock(a1)
    elseif cmd == "lkk" then F.cmdLoopKill(a1, true)
    elseif cmd == "kat" or cmd == "katana" then F.cmdKat(a1)
    elseif cmd == "knife" then F.cmdKnife(a1)
    elseif cmd == "unlk" or cmd == "unloopkill" or cmd == "unl" then F.cmdUnLoopKill()
    -- protection
    elseif cmd == "sentry" then F.cmdSentry(a1)
    elseif cmd == "sentry2" then F.cmdSentry2(a1)
    elseif cmd == "bsentry" then F.cmdBSentry(a1)
    elseif cmd == "assist" then F.cmdAssist(a1)
    elseif cmd == "unassist" then F.cmdUnassist()
    elseif cmd == "say" then F.cmdSay(sayMsg or "")
    elseif cmd == "sweep" then F.cmdSweep()
    elseif cmd == "unsweep" or cmd == "stopsweep" then F.cmdUnSweep()
    elseif cmd == "protect" or cmd == "prot" then F.cmdProtect(a1)
    elseif cmd == "unprotect" or cmd == "unprot" then F.cmdUnprotect()
    elseif cmd == "wl" or cmd == "whitelist" then F.cmdWL(a1)
    elseif cmd == "uwl" or cmd == "unwhitelist" then F.cmdUWL(a1)
    elseif cmd == "target" or cmd == "t" then F.cmdTarget(a1)
    elseif cmd == "untarget" or cmd == "unt" then F.cmdUntarget()
    elseif cmd == "armor" then F.cmdArmor()
    elseif cmd == "mask" then F.cmdMask()
    elseif cmd == "buyfood" or cmd == "food" or cmd == "bf" then F.cmdBuyFood()
    elseif cmd == "heal" or cmd == "eat" then F.cmdHeal()
    elseif cmd == "reload" then
        F.reloadGun(F.findGun())
        F.notify("Reload")
    elseif cmd == "autoreload" then
        State.AutoReload = not State.AutoReload
        F.notify("AutoReload " .. (State.AutoReload and "ON" or "OFF"))
    elseif cmd == "autoheal" or cmd == "ah" then
        local a1 = parts[2]
        if a1 == "on" or a1 == "1" or a1 == "true" then
            State.AutoHeal = true
        elseif a1 == "off" or a1 == "0" or a1 == "false" then
            State.AutoHeal = false
        else
            State.AutoHeal = not State.AutoHeal
        end
        F.notify("AutoHeal " .. (State.AutoHeal and "ON" or "OFF"))
    elseif cmd == "fix" then F.cmdFix()
    elseif cmd == "kick" or cmd == "rejoin" then F.cmdKick()
    elseif cmd == "help" or cmd == "cmds" then F.cmdHelp()
    end
end

function F.hookPlayerChat(plr)
    pcall(function()
        plr.Chatted:Connect(function(msg)
            F.onControlChat(msg, plr)
        end)
    end)
end

for _, plr in ipairs(Players:GetPlayers()) do
    F.hookPlayerChat(plr)
end
Players.PlayerAdded:Connect(F.hookPlayerChat)

pcall(function()
    local tcs = game:GetService("TextChatService")
    if not tcs then return end
    tcs.MessageReceived:Connect(function(message)
        local src = message.TextSource
        if not src then return end
        local plr = Players:GetPlayerByUserId(src.UserId)
        if plr then F.onControlChat(message.Text, plr) end
    end)
end)

----------------------------------------------------------------------
-- MAIN LOOP
----------------------------------------------------------------------
Connections.Main = RunService.Heartbeat:Connect(function()
    if IsOwner then return end
    -- FakePos: ALWAYS hold formation slot (even mid gun combat / loopkill).
    -- Silent aim + mouse remotes still kill from the slot. Knife briefly leaves.
    if State.FakePos then
        if not State.KnifeBusy and not State.InVoid and not State.VoidEat then
            F.holdFormation(true)
        end
    elseif not State.KnifeBusy and not State.LoopKillBusy and not State.Sweep
        and not State.LoopKill and not State.LoopKnock and not State.SentryBusy then
        F.followOwner()
    end
    F.autoReloadTick()
    pcall(F.sentryTick)
    pcall(F.combatSurviveTick)
    pcall(F.armorMaintainTick)
    pcall(F.autoHealTick)

    -- LoopKnock: shoot only, no stomp
    if State.LoopKnock and not State.LoopKillBusy and not State.KnifeBusy then
        local hum = F.getHum()
        if hum and hum.Health <= 0 then return end
        local lk = F.findPlayer(State.LoopKnock)
        if not lk then return end
        if F.isProtected(lk) then
            F.notify("LoopKnock stopped: protected " .. lk.Name)
            State.LoopKnock = nil
            State.Tracking = true
            return
        end
        State.LoopKillBusy = true
        task.spawn(function()
            local ok, err = pcall(function()
                if F.isAlive(lk) then
                    F.setCamlock(lk, 2)
                    F.shootTarget(lk)
                    task.wait(0.4)
                else
                    task.wait(0.5)
                end
            end)
            if not ok then warn("[Stand] LoopKnock error:", err) end
            State.LoopKillBusy = false
            if not State.LoopKnock and not IsOwner then
                State.Tracking = true
                F.clearCamlock()
            end
        end)
    end

    -- LoopKill: MoonStand-style single-flight worker
    -- KO → hard stomp spam | alive → close burst + stomp | dead → wait respawn then re-engage
    if State.LoopKill and not State.LoopKillBusy and not State.KnifeBusy then
        local hum = F.getHum()
        if hum and hum.Health <= 0 then return end
        local name = State.LoopKill
        local lk = F.findPlayer(name)
        if not lk then
            return
        end
        local prot = F.isProtected(lk)
        if prot then
            F.notify("LoopKill stopped: protected " .. lk.Name)
            State.LoopKill = nil
            State.LoopKillBusy = false
            State.Tracking = true
            return
        end

        State.LoopKillBusy = true
        task.spawn(function()
            local ok, err = pcall(function()
                F.beginCombat()
                if F.isKO(lk) then
                    -- already down: finish them
                    F.moonStompHard(lk)
                    -- hold pressure briefly in case they try to get up mid-stomp
                    local t0 = tick()
                    while tick() - t0 < 2.5 and State.LoopKill do
                        if not F.getChar(lk) then break end
                        if F.isAlive(lk) and not F.isKO(lk) then
                            -- got up — shoot again immediately
                            F.setCamlock(lk, 2)
                            F.loopKillCycle(lk)
                            break
                        end
                        if F.isKO(lk) then
                            F.stompTarget(lk, 4)
                        end
                        task.wait(0.2)
                    end
                    task.wait(0.15)
                elseif F.isAlive(lk) then
                    F.setCamlock(lk, 3)
                    F.loopKillCycle(lk)
                    -- if still alive after cycle, tiny gap then next worker pass
                    task.wait(0.12)
                else
                    -- dead / no char — wait for respawn, then snap back on
                    local t0 = tick()
                    while tick() - t0 < 8 and State.LoopKill do
                        local p = F.findPlayer(name)
                        if p and F.getChar(p) and (F.isAlive(p) or F.isKO(p)) then
                            break
                        end
                        task.wait(0.25)
                    end
                    task.wait(0.2)
                end
            end)
            if not ok then
                warn("[Stand] LoopKill error:", err)
            end
            State.LoopKillBusy = false
            if not State.LoopKill and not IsOwner then
                State.Tracking = true
                F.clearCamlock()
            end
        end)
    end
end)

----------------------------------------------------------------------
-- SENTRY HEALTH WATCH (shot detection)
----------------------------------------------------------------------
task.spawn(function()
    while true do
        pcall(F.refreshSentryWatches)
        task.wait(1.5)
    end
end)

LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(1)
    F.hookToolWatch(char)
    pcall(F.refreshSentryWatches)
    if Config.AutoArmor then F.buyArmor() end
    if Config.ArmorMax or Config.Inf then F.applyArmorMax() end
    if Config.AutoMask then F.buyMask() end
    if Config.Muscle then F.applyMuscle() end
    if not State.Armed and not F.isHoldingTool() then
        F.applyIdleAnim()
    else
        F.stopIdleAnim()
    end
end)

-- Initial character (already spawned)
task.spawn(function()
    local t0 = tick()
    while tick() - t0 < 8 do
        if F.getHum() then
            task.wait(0.8)
            local c = F.getChar()
            F.hookToolWatch(c)
            pcall(F.refreshSentryWatches)
            if not State.Armed and not F.isHoldingTool() then
                F.applyIdleAnim()
            end
            break
        end
        task.wait(0.25)
    end
end)

-- Config override for auto heal (default ON)
if Config.AutoHeal == false or Config.AutoHeal == "off" then
    State.AutoHeal = false
elseif Config.AutoHeal == true or Config.AutoHeal == "on" then
    State.AutoHeal = true
end

F.startAutoPerks()
pcall(F.ensureSilentAim)

do
    local n = 0
    for _ in pairs(StandTeam) do n = n + 1 end
    print("[Stand] Team protect:", n, "names (alts + owner + controllers) — stands will not kill each other")
end
print("[Stand] AutoHeal", State.AutoHeal and "ON" or "OFF",
    "| HC remotes:", IsHoodCustoms and "EatFood/BuyItem/ACTION" or "classic")

print("[Stand] Main v2 loaded |", IsOwner and "OWNER" or ("ALT slot " .. tostring(MySlot)),
    "| prefix", Prefix, "| owner", OwnerName, "| anim", tostring(Config.Anim or "none"))
F.notify(IsOwner and "Owner ready" or ("Alt slot " .. tostring(MySlot)))
