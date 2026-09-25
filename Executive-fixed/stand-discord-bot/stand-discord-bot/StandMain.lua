--[[
    STAND BOT MAIN — Hood Customs
    Controlled by owner chat commands (Prefix from config)
    Inject on ALTS only — owner just types commands in public chat.
]]

local Config = rawget(_G, "StandConfig") or (getgenv and getgenv().StandConfig) or nil
if not Config then
    warn("[Stand] No StandConfig — use the loader")
    return
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local StarterGui = game:GetService("StarterGui")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local OwnerName = Config.Owner or ""
local Prefix = Config.Prefix or "."
local PreferredGun = Config.Gun or "[Double-Barrel SG]"

local SLOT_CF = {
    [1] = CFrame.new(-3.5, 0, 0.5),   -- left
    [2] = CFrame.new(3.5, 0, 0.5),    -- right
    [3] = CFrame.new(0, 0, 3.5),      -- behind
    [4] = CFrame.new(0, 0, -3.5),     -- front
    [5] = CFrame.new(-6, 0, 1),       -- left2
    [6] = CFrame.new(0, 0, 6),        -- behind2
    [0] = CFrame.new(2.5, 0, 2.5),    -- auto
}

local function getMySlot()
    local alts = Config.Alts or {}
    local s = alts[LocalPlayer.Name]
    if s == nil then
        s = Config.Slot or 2
    end
    return tonumber(s) or 2
end

local IsOwner = (string.lower(LocalPlayer.Name) == string.lower(OwnerName))
local IsAlt = (Config.Alts and Config.Alts[LocalPlayer.Name] ~= nil) or (not IsOwner)
local MySlot = getMySlot()

-- State
local State = {
    InVoid = false,
    Tracking = true,
    KillAura = false,
    StompAura = false,
    BodyShield = false,
    RageKA = false,
    Taunt = false,
    TargetName = nil,
    ProtectName = nil,
    FPSBoost = false,
    Armed = false,
}

local Whitelist = {}
local Connections = {}
local SavedCF = nil
local VoidCF = CFrame.new(0, -480, 0)

local function notify(msg)
    if IsOwner then
        pcall(function()
            StarterGui:SetCore("SendNotification", {Title = "Stand", Text = tostring(msg), Duration = 2})
        end)
    end
    print("[Stand]", LocalPlayer.Name, msg)
end

local function disc(n)
    if Connections[n] then pcall(function() Connections[n]:Disconnect() end) Connections[n] = nil end
end

----------------------------------------------------------------------
-- HOOD CUSTOMS HELPERS
----------------------------------------------------------------------
local MainEvent = nil
local MouseRemote = "MousePosUpdate"
pcall(function()
    MainEvent = ReplicatedStorage:FindFirstChild("MainEvent") or ReplicatedStorage:FindFirstChild("MainEventt")
    local pid = game.PlaceId
    if pid == 2788229376 or pid == 16033173781 then MouseRemote = "UpdateMousePosI"
    elseif pid == 9825515356 then MouseRemote = "MousePosUpdate"
    elseif pid == 5602055394 then MouseRemote = "MousePos"
    else MouseRemote = "UpdateMousePos" end
end)

local function getChar(p) return (p or LocalPlayer).Character end
local function getHRP(p)
    local c = getChar(p)
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHum(p)
    local c = getChar(p)
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function isKO(p)
    local c = getChar(p)
    if not c then return false end
    local be = c:FindFirstChild("BodyEffects")
    if be then
        local ko = be:FindFirstChild("K.O") or be:FindFirstChild("KO")
        if ko and ko.Value == true then return true end
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
    for _, plr in ipairs(Players:GetPlayers()) do
        if string.lower(plr.Name) == string.lower(OwnerName) then
            return plr
        end
    end
    return nil
end

local function findPlayer(name)
    if not name or name == "" then return nil end
    name = string.lower(name)
    for _, plr in ipairs(Players:GetPlayers()) do
        if string.lower(plr.Name) == name then return plr end
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        if string.find(string.lower(plr.Name), name, 1, true) then return plr end
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.DisplayName and string.find(string.lower(plr.DisplayName), name, 1, true) then
            return plr
        end
    end
    return nil
end

local function isWL(p)
    return p and Whitelist[p.UserId]
end

local function fireMouse(pos)
    if MainEvent and pos then
        pcall(function() MainEvent:FireServer(MouseRemote, pos) end)
    end
end

local function equipToolByName(name)
    local c = getChar()
    local bag = LocalPlayer.Backpack
    local function find(container)
        if not container then return nil end
        local t = container:FindFirstChild(name)
        if t then return t end
        for _, x in ipairs(container:GetChildren()) do
            if x:IsA("Tool") and string.find(string.lower(x.Name), string.lower(name:gsub("%[%]", "")), 1, true) then
                return x
            end
        end
        return nil
    end
    local tool = find(c) or find(bag)
    if tool and tool.Parent == bag then
        pcall(function()
            local h = getHum()
            if h then h:EquipTool(tool) end
        end)
    end
    return tool
end

local function equipCombat()
    return equipToolByName("Combat") or (getChar() and getChar():FindFirstChildOfClass("Tool"))
end

local function equipGun()
    local g = equipToolByName(PreferredGun)
    if not g then
        -- fallback any gun-like
        local bag = LocalPlayer.Backpack
        local c = getChar()
        for _, container in ipairs({c, bag}) do
            if container then
                for _, t in ipairs(container:GetChildren()) do
                    if t:IsA("Tool") and t.Name ~= "Combat" then
                        pcall(function()
                            local h = getHum()
                            if h and t.Parent == bag then h:EquipTool(t) end
                        end)
                        return t
                    end
                end
            end
        end
    end
    State.Armed = true
    return g
end

local function unequip()
    pcall(function()
        local h = getHum()
        if h then h:UnequipTools() end
    end)
    State.Armed = false
end

local function muteGunSounds()
    if not Config.MuteGunSounds then return end
    local c = getChar()
    if not c then return end
    for _, s in ipairs(c:GetDescendants()) do
        if s:IsA("Sound") then
            pcall(function() s.Volume = 0 end)
        end
    end
end

local function punch(plr)
    if not plr or isWL(plr) then return end
    if State.ProtectName and string.lower(plr.Name) == string.lower(State.ProtectName) then return end
    local my = getHRP()
    local their = getHRP(plr)
    if not my or not their then return end
    pcall(function()
        my.CFrame = CFrame.new(my.Position, Vector3.new(their.Position.X, my.Position.Y, their.Position.Z))
    end)
    local head = getChar(plr) and getChar(plr):FindFirstChild("Head")
    fireMouse(head and head.Position or their.Position)
    local tool = State.Armed and equipGun() or equipCombat()
    if tool then pcall(function() tool:Activate() end) end
    if MainEvent then pcall(function() MainEvent:FireServer("Punch") end) end
end

local function stomp(plr)
    if not plr then return end
    local my = getHRP()
    local their = getHRP(plr)
    if not my or not their then return end
    pcall(function()
        my.CFrame = CFrame.new(their.Position + Vector3.new(0, 2.8, 0), their.Position)
    end)
    local tool = equipCombat()
    if tool then pcall(function() tool:Activate() end) end
    if MainEvent then pcall(function() MainEvent:FireServer("Stomp") end) end
end

local function shoot(plr)
    if not plr or isWL(plr) then return end
    local my = getHRP()
    local their = getHRP(plr)
    if not my or not their then return end
    local head = getChar(plr) and getChar(plr):FindFirstChild("Head")
    local aim = head and head.Position or their.Position
    local vel = their.AssemblyLinearVelocity
    aim = aim + Vector3.new(vel.X, vel.Y * 0.2, vel.Z) * 0.14
    pcall(function()
        my.CFrame = CFrame.new(my.Position, Vector3.new(their.Position.X, my.Position.Y, their.Position.Z))
        Camera.CFrame = CFrame.new(Camera.CFrame.Position, aim)
    end)
    fireMouse(aim)
    local gun = equipGun()
    if gun then pcall(function() gun:Activate() end) end
end

----------------------------------------------------------------------
-- FORMATION / VOID / TRACK (alts)
----------------------------------------------------------------------
local function followOwner()
    if IsOwner then return end
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
    local my = getHRP()
    if not oHRP or not my then return end

    if State.BodyShield then
        pcall(function()
            my.CFrame = oHRP.CFrame * CFrame.new(0, 0, 0.15)
        end)
        return
    end

    local offset = SLOT_CF[MySlot] or SLOT_CF[2]
    pcall(function()
        my.CFrame = oHRP.CFrame * offset
    end)
end

----------------------------------------------------------------------
-- COMMANDS (executed on each client that should act)
----------------------------------------------------------------------
local function shouldAct()
    -- Alts always act on owner commands; owner can also act for local helpers
    return true
end

local function cmdVoid()
    if IsOwner then return end -- owner doesn't void themselves from .v (alts do)
    local hrp = getHRP()
    if hrp and not State.InVoid then SavedCF = hrp.CFrame end
    State.InVoid = true
    State.Tracking = false
    notify("Void")
end

local function cmdCall()
    if IsOwner then return end
    State.InVoid = false
    State.Tracking = true
    notify("Call")
end

local function cmdTrack()
    if IsOwner then return end
    State.Tracking = true
    State.InVoid = false
    notify("Track")
end

local function cmdPos(slot)
    if IsOwner then return end
    local n = tonumber(slot)
    local map = {left=1, right=2, behind=3, front=4, left2=5, behind2=6}
    if not n and slot then n = map[string.lower(slot)] end
    if n and SLOT_CF[n] then
        MySlot = n
        State.Tracking = true
        State.InVoid = false
        notify("Pos " .. tostring(n))
    end
end

local function cmdArm()
    equipGun()
    muteGunSounds()
    State.Armed = true
    notify("Arm")
end

local function cmdUnarm()
    unequip()
    notify("Unarm")
end

local function cmdKA()
    State.KillAura = not State.KillAura
    notify("KA " .. (State.KillAura and "ON" or "OFF"))
end

local function cmdKnock(user)
    local plr = findPlayer(user)
    if not plr then return end
    task.spawn(function()
        for i = 1, 30 do
            if not isAlive(plr) then break end
            if State.Armed then shoot(plr) else punch(plr) end
            task.wait(0.08)
        end
    end)
end

local function cmdRage(user)
    local plr = findPlayer(user)
    if not plr then return end
    local my = getHRP()
    local their = getHRP(plr)
    if not my or not their then return end
    local saved = my.CFrame
    task.spawn(function()
        pcall(function() my.CFrame = CFrame.new(their.Position + Vector3.new(0, 40, 0), their.Position) end)
        task.wait(0.12)
        for i = 1, 25 do
            if not isAlive(plr) then break end
            their = getHRP(plr)
            if their then
                pcall(function() my.CFrame = CFrame.new(their.Position + Vector3.new(0, 2.5, 0), their.Position) end)
                if State.Armed then shoot(plr) else punch(plr) end
            end
            task.wait(0.07)
        end
        task.wait(0.1)
        if not State.InVoid then
            pcall(function() my.CFrame = saved end)
        end
    end)
end

local function cmdTarget(user)
    if not user then
        State.TargetName = nil
        notify("Target cleared")
        return
    end
    local plr = findPlayer(user)
    if plr then
        State.TargetName = plr.Name
        notify("Target " .. plr.Name)
    end
end

local function cmdOS()
    if IsOwner then return end
    State.BodyShield = not State.BodyShield
    notify("OS " .. (State.BodyShield and "ON" or "OFF"))
end

local function cmdSweep()
    task.spawn(function()
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and isAlive(plr) and not isWL(plr) then
                if string.lower(plr.Name) == string.lower(OwnerName) then
                    -- never attack owner
                elseif State.ProtectName and string.lower(plr.Name) == string.lower(State.ProtectName) then
                    -- skip
                else
                    for i = 1, 20 do
                        if not isAlive(plr) then break end
                        if State.Armed then shoot(plr) else punch(plr) end
                        task.wait(0.07)
                    end
                    if isKO(plr) then stomp(plr) task.wait(0.25) end
                end
            end
        end
    end)
end

local function cmdStompAura()
    State.StompAura = not State.StompAura
    notify("StompAura " .. (State.StompAura and "ON" or "OFF"))
end

local function cmdStompUser(user)
    local plr = findPlayer(user)
    if plr and isKO(plr) then stomp(plr) end
end

local function cmdRK()
    State.RageKA = not State.RageKA
    notify("RageKA " .. (State.RageKA and "ON" or "OFF"))
end

local function cmdWL(user)
    local plr = findPlayer(user)
    if plr then Whitelist[plr.UserId] = true notify("WL " .. plr.Name) end
end

local function cmdUWL()
    Whitelist = {}
    notify("WL cleared")
end

local function cmdProtect(user)
    local plr = findPlayer(user)
    if plr then
        State.ProtectName = plr.Name
        Whitelist[plr.UserId] = true
        notify("Protect " .. plr.Name)
    end
end

local function cmdUnprotect()
    State.ProtectName = nil
    notify("Protect cleared")
end

local function cmdTaunt(off)
    State.Taunt = not off and not State.Taunt or (not off and true)
    if off then State.Taunt = false end
    notify("Taunt " .. (State.Taunt and "ON" or "OFF"))
end

local function cmdEmote(arg)
    pcall(function()
        if arg == "f" then LocalPlayer:Chat("/e floss")
        elseif arg == "l" then LocalPlayer:Chat("/e laugh")
        else
            local h = getHum()
            if h then h:ChangeState(Enum.HumanoidStateType.GettingUp) end
        end
    end)
end

local function cmdArmor()
    pcall(function()
        if MainEvent then
            MainEvent:FireServer("BuyArmor")
            MainEvent:FireServer("Purchase", "High-Medium Armor")
        end
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("ClickDetector") then
                local n = string.lower(obj.Parent and obj.Parent.Name or "")
                if string.find(n, "armor") then
                    pcall(function() fireclickdetector(obj) end)
                end
            end
        end
    end)
end

local function cmdFix()
    State.InVoid = false
    State.Tracking = not IsOwner
    State.KillAura = false
    State.BodyShield = false
    unequip()
    local h = getHum()
    if h then pcall(function() h:ChangeState(Enum.HumanoidStateType.GettingUp) end) end
    notify("Fix")
end

local function cmdKick()
    pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
end

local function cmdFPS(off)
    if off then
        pcall(function()
            settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic
            Lighting.GlobalShadows = true
        end)
        notify("FPS off")
        return
    end
    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 1e9
        for _, v in ipairs(Workspace:GetDescendants()) do
            if v:IsA("ParticleEmitter") or v:IsA("Trail") then v.Enabled = false end
            if v:IsA("Decal") or v:IsA("Texture") then v.Transparency = 1 end
        end
    end)
    notify("FPS on")
end

local function cmdHelp()
    if not IsOwner then return end
    print([[
.v .void .vanish | .call .retrieve | .track | .pos <slot>
.arm .unarm | .k | .knock <user> | .rage <user> | .o <user>
.os | .f | .s | .s <user> | .rk
.wl <user> .uwl | .protect <user> .unprotect
.l .l off | .e .e f .e l | .a | .fix | .kick | .r .r off
]])
    notify("Help in F9")
end

----------------------------------------------------------------------
-- PARSE OWNER CHAT
----------------------------------------------------------------------
local function onOwnerChat(msg)
    if type(msg) ~= "string" then return end
    msg = string.gsub(msg, "^%s+", "")
    msg = string.gsub(msg, "%s+$", "")
    if string.sub(msg, 1, #Prefix) ~= Prefix then return end

    local body = string.lower(string.sub(msg, #Prefix + 1))
    local parts = {}
    for w in string.gmatch(body, "%S+") do parts[#parts + 1] = w end
    if #parts == 0 then return end

    local cmd, a1, a2 = parts[1], parts[2], parts[3]

    if cmd == "v" or cmd == "void" or cmd == "vanish" then cmdVoid()
    elseif cmd == "call" or cmd == "retrieve" then cmdCall()
    elseif cmd == "track" then cmdTrack()
    elseif cmd == "pos" then cmdPos(a1)
    elseif cmd == "arm" then cmdArm()
    elseif cmd == "unarm" then cmdUnarm()
    elseif cmd == "k" then cmdKA()
    elseif cmd == "knock" then cmdKnock(a1)
    elseif cmd == "rage" then cmdRage(a1)
    elseif cmd == "o" then cmdTarget(a2 or a1)
    elseif cmd == "os" then cmdOS()
    elseif cmd == "f" then cmdSweep()
    elseif cmd == "s" then
        if a1 then cmdStompUser(a1) else cmdStompAura() end
    elseif cmd == "rk" then cmdRK()
    elseif cmd == "wl" then cmdWL(a1)
    elseif cmd == "uwl" then cmdUWL()
    elseif cmd == "protect" then cmdProtect(a1)
    elseif cmd == "unprotect" then cmdUnprotect()
    elseif cmd == "l" then cmdTaunt(a1 == "off")
    elseif cmd == "e" then cmdEmote(a1)
    elseif cmd == "a" then cmdArmor()
    elseif cmd == "fix" then cmdFix()
    elseif cmd == "kick" then cmdKick()
    elseif cmd == "r" then cmdFPS(a1 == "off")
    elseif cmd == "help" then cmdHelp()
    end
end

-- Listen to owner chat only
local function hookPlayerChat(plr)
    if string.lower(plr.Name) ~= string.lower(OwnerName) then return end
    plr.Chatted:Connect(onOwnerChat)
end

for _, plr in ipairs(Players:GetPlayers()) do
    hookPlayerChat(plr)
end
Players.PlayerAdded:Connect(hookPlayerChat)

-- Owner also triggers from own chat
if IsOwner then
    LocalPlayer.Chatted:Connect(onOwnerChat)
end

pcall(function()
    local TextChatService = game:GetService("TextChatService")
    if TextChatService then
        TextChatService.MessageReceived:Connect(function(message)
            local src = message.TextSource
            if not src then return end
            local plr = Players:GetPlayerByUserId(src.UserId)
            if plr and string.lower(plr.Name) == string.lower(OwnerName) then
                onOwnerChat(message.Text)
            end
        end)
    end
end)

----------------------------------------------------------------------
-- MAIN LOOP
----------------------------------------------------------------------
local lastKA, lastStomp = 0, 0
Connections.Main = RunService.Heartbeat:Connect(function()
    -- formation
    if not IsOwner then
        followOwner()
    end

    local owner = getOwner()
    local ownerDown = owner and isKO(owner)

    local ka = State.KillAura or (State.RageKA and ownerDown)
    if ka and not isKO(LocalPlayer) and tick() - lastKA > 0.1 then
        lastKA = tick()
        local target = State.TargetName and findPlayer(State.TargetName)
        if target and isAlive(target) then
            if State.Armed then shoot(target) else punch(target) end
        else
            local my = getHRP()
            if my then
                local best, bestD = nil, 20
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr ~= LocalPlayer and isAlive(plr) and not isWL(plr)
                        and string.lower(plr.Name) ~= string.lower(OwnerName) then
                        local th = getHRP(plr)
                        if th then
                            local d = (th.Position - my.Position).Magnitude
                            if d < bestD then bestD = d best = plr end
                        end
                    end
                end
                if best then
                    if State.Armed then shoot(best) else punch(best) end
                end
            end
        end
    end

    if State.StompAura and tick() - lastStomp > 0.15 then
        lastStomp = tick()
        local my = getHRP()
        if my then
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer and isKO(plr) and not isWL(plr)
                    and string.lower(plr.Name) ~= string.lower(OwnerName) then
                    local th = getHRP(plr)
                    if th and (th.Position - my.Position).Magnitude < 14 then
                        stomp(plr)
                        break
                    end
                end
            end
        end
    end
end)

-- optional idle anim
if Config.Anim and Config.Anim ~= "" and not IsOwner then
    task.spawn(function()
        task.wait(1)
        pcall(function()
            local h = getHum()
            if not h then return end
            local anim = Instance.new("Animation")
            anim.AnimationId = Config.Anim
            local track = h:LoadAnimation(anim)
            track.Looped = true
            track:Play()
        end)
    end)
end

-- auto armor on join
if Config.AutoArmor and not IsOwner then
    task.delay(2, cmdArmor)
end

LocalPlayer.Idled:Connect(function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

print("[Stand] Main loaded |", IsOwner and "OWNER" or ("ALT slot " .. tostring(MySlot)), "| prefix", Prefix, "| owner", OwnerName)
if IsOwner then
    notify("Owner ready — command alts with " .. Prefix .. "help")
else
    print("[Stand] Listening for chat from owner:", OwnerName)
    if not OwnerName or OwnerName == "" then
        warn("[Stand] Owner name is EMPTY — run /setuploader in Discord then re-download /loader")
    end
end
