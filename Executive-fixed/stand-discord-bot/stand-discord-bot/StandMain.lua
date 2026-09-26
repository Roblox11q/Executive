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
local PreferredGun = Config.Gun or "[DoubleBarrel]"

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
    Camlock = false, -- camera hard-locked onto CamTarget
}

local Whitelist = {}
local Connections = {}
local SavedCF = nil
local VoidCF = CFrame.new(0, -480, 0)
local CamTarget = nil -- Player instance currently camlocked
local CamlockUntil = 0 -- tick() until which camlock stays forced

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
    if not pos then return end
    if MainEvent then
        pcall(function() MainEvent:FireServer(MouseRemote, pos) end)
        pcall(function() MainEvent:FireServer("MousePos", pos) end)
        pcall(function() MainEvent:FireServer("MousePosUpdate", pos) end)
        pcall(function() MainEvent:FireServer("UpdateMousePos", pos) end)
        pcall(function() MainEvent:FireServer("UpdateMousePosI", pos) end)
    end
end

local function getAimPart(plr)
    local c = getChar(plr)
    if not c then return nil end
    return c:FindFirstChild("Head")
        or c:FindFirstChild("UpperTorso")
        or c:FindFirstChild("Torso")
        or getHRP(plr)
end

local function getTargetAimPos(plr)
    local part = getAimPart(plr)
    if not part then return nil end
    local aim = part.Position
    local their = getHRP(plr)
    if their then
        local vel = their.AssemblyLinearVelocity or Vector3.zero
        aim = aim + Vector3.new(vel.X, math.clamp(vel.Y, -15, 15) * 0.25, vel.Z) * 0.18
    end
    return aim
end

local CamlockHighlight = nil
local CamlockConn = nil
local origMinZoom, origMaxZoom, origCamMode = nil, nil, nil

local function removeCamESP()
    if CamlockHighlight then
        pcall(function() CamlockHighlight:Destroy() end)
        CamlockHighlight = nil
    end
end

local function createCamESP(character)
    removeCamESP()
    if not character then return end
    pcall(function()
        local h = Instance.new("Highlight")
        h.Name = "StandCamlockESP"
        h.Adornee = character
        h.FillColor = Color3.fromRGB(255, 40, 40)
        h.OutlineColor = Color3.fromRGB(255, 255, 255)
        h.FillTransparency = 0.6
        h.OutlineTransparency = 0
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.Parent = character
        CamlockHighlight = h
    end)
end

local function clearCamlock()
    CamTarget = nil
    State.Camlock = false
    CamlockUntil = 0
    removeCamESP()
    if origCamMode ~= nil then
        pcall(function()
            LocalPlayer.CameraMode = origCamMode
            LocalPlayer.CameraMinZoomDistance = origMinZoom
            LocalPlayer.CameraMaxZoomDistance = origMaxZoom
        end)
        origCamMode = nil
    end
end

-- Move real cursor onto target head so crosshair is ON them (not off to the side)
local function moveCursorToWorld(worldPos)
    Camera = Workspace.CurrentCamera
    if not Camera or not worldPos then return end
    local sp, onScreen = Camera:WorldToViewportPoint(worldPos)
    if not onScreen or sp.Z < 0 then return end
    local x, y = sp.X, sp.Y
    pcall(function()
        if mousemoveabs then mousemoveabs(x, y) return end
    end)
    pcall(function()
        if syn and syn.mousemoveabs then syn.mousemoveabs(x, y) return end
    end)
    pcall(function()
        local vim = game:GetService("VirtualInputManager")
        if vim then vim:SendMouseMoveEvent(x, y, game) end
    end)
end

-- Camlock: camera lookAt head + cursor on head + mouse remote
local function camlockStep()
    if not State.Camlock then return end
    if CamlockUntil > 0 and tick() > CamlockUntil then
        clearCamlock()
        return
    end
    local plr = CamTarget
    if not plr or not plr.Parent then
        if State.TargetName then
            plr = findPlayer(State.TargetName)
            CamTarget = plr
        end
    end
    if not plr or not isAlive(plr) then
        clearCamlock()
        return
    end
    local head = getChar(plr) and getChar(plr):FindFirstChild("Head")
    if not head then
        clearCamlock()
        return
    end
    -- dead center on head (minimal lead so cursor stays on them)
    local aim = head.Position
    local their = getHRP(plr)
    if their then
        local vel = their.AssemblyLinearVelocity or Vector3.zero
        aim = aim + Vector3.new(vel.X, 0, vel.Z) * 0.06
    end
    Camera = Workspace.CurrentCamera
    if Camera then
        pcall(function()
            Camera.CFrame = CFrame.lookAt(Camera.CFrame.Position, aim)
        end)
    end
    moveCursorToWorld(aim)
    fireMouse(aim)
    fireMouse(aim)
end

if CamlockConn then pcall(function() CamlockConn:Disconnect() end) end
CamlockConn = RunService.RenderStepped:Connect(camlockStep)
Connections.Camlock = CamlockConn

local function setCamlock(plr, seconds)
    if not plr or not isAlive(plr) then return end
    CamTarget = plr
    State.Camlock = true
    if seconds and seconds > 0 then
        CamlockUntil = tick() + seconds
    else
        CamlockUntil = tick() + 999999
    end
    if origCamMode == nil then
        origMinZoom = LocalPlayer.CameraMinZoomDistance
        origMaxZoom = LocalPlayer.CameraMaxZoomDistance
        origCamMode = LocalPlayer.CameraMode
    end
    pcall(function()
        LocalPlayer.CameraMode = Enum.CameraMode.Classic
        LocalPlayer.CameraMinZoomDistance = 8
        LocalPlayer.CameraMaxZoomDistance = 18
    end)
    if plr.Character then createCamESP(plr.Character) end
end

local function reloadGun(gun)
    gun = gun or findToolByName(PreferredGun, false)
    if not gun then return false end
    local wasParent = gun.Parent

    -- 1) Server reload remotes (most hood places)
    if MainEvent then
        pcall(function() MainEvent:FireServer("Reload") end)
        pcall(function() MainEvent:FireServer("Reload", gun.Name) end)
        pcall(function() MainEvent:FireServer("Reload", gun) end)
    end

    -- 2) Tool-local remotes / functions
    pcall(function()
        for _, v in ipairs(gun:GetDescendants()) do
            local n = string.lower(v.Name)
            if string.find(n, "reload", 1, true) then
                if v:IsA("RemoteEvent") then pcall(function() v:FireServer() end) end
                if v:IsA("RemoteFunction") then pcall(function() v:InvokeServer() end) end
                if v:IsA("BindableEvent") then pcall(function() v:Fire() end) end
            end
        end
    end)

    -- 3) Simulate R key (many hood scripts bind reload to R)
    pcall(function()
        local vim = game:GetService("VirtualInputManager")
        if vim then
            vim:SendKeyEvent(true, Enum.KeyCode.R, false, game)
            task.wait(0.05)
            vim:SendKeyEvent(false, Enum.KeyCode.R, false, game)
        end
    end)

    -- 4) Do NOT unequip mid-fight (caused "Activate when not equipped")
    --    Keep gun in hand; only soft-refresh ammo values below.

    -- 5) Local ammo values (client-side display / some anti-cheat weak places)
    pcall(function()
        local g = findToolByName(PreferredGun, false) or gun
        if not g then return end
        for _, v in ipairs(g:GetDescendants()) do
            if v:IsA("IntValue") or v:IsA("NumberValue") then
                local n = string.lower(v.Name)
                if n == "ammo" or n == "clip" or n == "bullets" or n == "mag" or n == "ammo.val" then
                    local maxv = g:FindFirstChild("MaxAmmo") or g:FindFirstChild("MaxClip")
                        or g:FindFirstChild("Max") or g:FindFirstChild("MagazineSize")
                    if maxv and (maxv:IsA("IntValue") or maxv:IsA("NumberValue")) then
                        v.Value = maxv.Value
                    elseif v.Value <= 2 then
                        v.Value = 25
                    end
                end
            end
        end
    end)

    return true
end

local function normalizeGunName(name)
    if not name then return "" end
    -- strip brackets/spaces for fuzzy match: "[Double-Barrel SG]" -> "double-barrel sg"
    return string.lower((tostring(name):gsub("[%[%]]", ""):gsub("%s+", " ")):match("^%s*(.-)%s*$") or "")
end

local function findToolByName(name, exactOnly)
    if not name or name == "" then return nil end
    local c = getChar()
    local bag = LocalPlayer:FindFirstChild("Backpack")
    local want = normalizeGunName(name)
    local wantExact = string.lower(tostring(name))

    local function scan(container)
        if not container then return nil end
        -- exact name first
        local t = container:FindFirstChild(name)
        if t and t:IsA("Tool") then return t end
        for _, x in ipairs(container:GetChildren()) do
            if x:IsA("Tool") then
                if string.lower(x.Name) == wantExact then return x end
            end
        end
        if exactOnly then return nil end
        for _, x in ipairs(container:GetChildren()) do
            if x:IsA("Tool") then
                local xn = normalizeGunName(x.Name)
                if xn == want or (want ~= "" and string.find(xn, want, 1, true))
                    or (want ~= "" and string.find(want, xn, 1, true)) then
                    return x
                end
            end
        end
        return nil
    end

    return scan(c) or scan(bag)
end

local function isToolEquipped(tool)
    local c = getChar()
    return tool ~= nil and c ~= nil and tool.Parent == c
end

-- Equip and WAIT until tool is on character (fixes "Activate when not equipped")
local function equipTool(tool, timeout)
    if not tool then return nil end
    timeout = timeout or 0.65
    local c = getChar()
    if not c then return nil end
    if tool.Parent == c then return tool end
    local bag = LocalPlayer:FindFirstChild("Backpack")
    pcall(function()
        local h = getHum()
        if h then h:EquipTool(tool) end
    end)
    local t0 = tick()
    while tick() - t0 < timeout do
        c = getChar()
        if tool.Parent == c then return tool end
        task.wait(0.03)
        pcall(function()
            local h = getHum()
            if h and bag and tool.Parent == bag then h:EquipTool(tool) end
        end)
    end
    return (tool.Parent == getChar()) and tool or nil
end

local function equipToolByName(name)
    return equipTool(findToolByName(name, false))
end

local function equipCombat()
    local t = findToolByName("Combat", true) or findToolByName("Combat", false)
    if t then return equipTool(t) end
    local c = getChar()
    if c then
        local held = c:FindFirstChild("Combat")
        if held and held:IsA("Tool") then return held end
    end
    return nil
end

local function activateTool(tool)
    if not tool then return false end
    if not isToolEquipped(tool) then
        tool = equipTool(tool, 0.45)
    end
    if tool and isToolEquipped(tool) then
        pcall(function() tool:Activate() end)
        return true
    end
    return false
end

-- ONLY the preferred gun from config — never random other tools
local function equipGun()
    local g = findToolByName(PreferredGun, false)
    if not g then
        warn("[Stand] Preferred gun not found:", PreferredGun)
        return nil
    end
    g = equipTool(g, 0.7)
    if g and isToolEquipped(g) then
        State.Armed = true
        return g
    end
    task.wait(0.05)
    g = findToolByName(PreferredGun, false)
    g = equipTool(g, 0.5)
    if g and isToolEquipped(g) then
        State.Armed = true
        return g
    end
    warn("[Stand] Failed to equip gun")
    return nil
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

local function aimAt(plr)
    local aim = getTargetAimPos(plr)
    if not aim then return nil end
    fireMouse(aim)
    pcall(function()
        Camera = Workspace.CurrentCamera
        if Camera then
            Camera.CFrame = CFrame.new(Camera.CFrame.Position, aim)
        end
    end)
    return aim
end

local function lockOnTarget(plr, sideDist, height)
    sideDist = sideDist or 1.6
    height = height or 0.6
    local my = getHRP()
    local their = getHRP(plr)
    local head = getAimPart(plr)
    if not my or not their then return false end
    -- stand in FRONT of them (along look vector), not off to the side
    -- so camera/cursor line up with the head
    local look = their.CFrame.LookVector
    local pos = their.Position + look * sideDist + Vector3.new(0, height, 0)
    local lookAt = (head and head.Position) or their.Position
    pcall(function()
        my.CFrame = CFrame.new(pos, lookAt)
        my.AssemblyLinearVelocity = Vector3.zero
        my.AssemblyAngularVelocity = Vector3.zero
    end)
    return true
end

local function needsReload(gun)
    if not gun then return true end
    local lowest = nil
    pcall(function()
        for _, v in ipairs(gun:GetDescendants()) do
            if v:IsA("IntValue") or v:IsA("NumberValue") then
                local n = string.lower(v.Name)
                if n == "ammo" or n == "clip" or n == "bullets" or n == "mag"
                    or n == "ammo.val" or n == "ammovalue" then
                    if lowest == nil or v.Value < lowest then
                        lowest = v.Value
                    end
                end
            end
        end
    end)
    -- if we found an ammo value and it's empty/low → reload
    if lowest ~= nil then return lowest <= 1 end
    -- no ammo values found → still try reload periodically when shooting
    return false
end

local function punch(plr)
    if not plr or isWL(plr) then return end
    if State.ProtectName and string.lower(plr.Name) == string.lower(State.ProtectName) then return end
    setCamlock(plr, 0.8)
    if not lockOnTarget(plr, 1.6, 0.4) then return end
    aimAt(plr)
    activateTool(equipCombat())
    if MainEvent then
        pcall(function() MainEvent:FireServer("Punch") end)
        pcall(function() MainEvent:FireServer("Hit", plr.Character) end)
    end
end

local function stomp(plr)
    if not plr then return end
    local my = getHRP()
    local their = getHRP(plr)
    if not my or not their then return end
    setCamlock(plr, 0.5)
    pcall(function()
        my.CFrame = CFrame.new(their.Position + Vector3.new(0, 2.55, 0), their.Position)
        my.AssemblyLinearVelocity = Vector3.zero
    end)
    aimAt(plr)
    activateTool(equipCombat())
    if MainEvent then
        pcall(function() MainEvent:FireServer("Stomp") end)
        pcall(function() MainEvent:FireServer("Stomp", plr.Character) end)
    end
end

local function shoot(plr)
    if not plr or isWL(plr) then return end
    if State.ProtectName and string.lower(plr.Name) == string.lower(State.ProtectName) then return end
    if not getHRP(plr) then return end

    setCamlock(plr, 1.5)

    local gun = equipGun()
    if not gun then return end
    muteGunSounds()

    -- soft reload only — never unequip mid-fight (that caused Activate errors)
    if needsReload(gun) then
        if MainEvent then
            pcall(function() MainEvent:FireServer("Reload") end)
            pcall(function() MainEvent:FireServer("Reload", gun.Name) end)
        end
        pcall(function()
            local vim = game:GetService("VirtualInputManager")
            if vim then
                vim:SendKeyEvent(true, Enum.KeyCode.R, false, game)
                task.wait(0.04)
                vim:SendKeyEvent(false, Enum.KeyCode.R, false, game)
            end
        end)
        task.wait(0.08)
        gun = equipGun()
        if not gun then return end
    end

    for i = 1, 10 do
        if not isAlive(plr) then break end
        gun = findToolByName(PreferredGun, false)
        if not gun or not isToolEquipped(gun) then
            gun = equipGun()
            if not gun then break end
        end
        lockOnTarget(plr, 1.4 + (i % 3) * 0.1, 0.7)
        local aim = aimAt(plr)
        if aim then
            fireMouse(aim)
            fireMouse(aim)
        end
        activateTool(gun)
        if MainEvent then
            pcall(function() MainEvent:FireServer("Shoot") end)
        end
        task.wait(0.03)
    end
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
    unequip() -- clear anything currently held so we only pull preferred gun
    task.wait(0.05)
    local g = equipGun()
    muteGunSounds()
    if g then
        State.Armed = true
        notify("Arm " .. tostring(g.Name))
    else
        State.Armed = false
        notify("Gun not found: " .. tostring(PreferredGun))
    end
end

local function cmdUnarm()
    unequip()
    notify("Unarm")
end

local function cmdKA()
    State.KillAura = not State.KillAura
    if State.KillAura and State.TargetName then
        local plr = findPlayer(State.TargetName)
        if plr then setCamlock(plr, 0) end -- hold until KA off
    elseif not State.KillAura then
        clearCamlock()
    end
    notify("KA " .. (State.KillAura and "ON" or "OFF"))
end

local function cmdKnock(user)
    local plr = findPlayer(user)
    if not plr then
        notify("Knock: player not found")
        return
    end
    task.spawn(function()
        local useGun = false
        if PreferredGun and PreferredGun ~= "" then
            local g = equipGun()
            useGun = g ~= nil
            State.Armed = useGun
            muteGunSounds()
        end
        local savedTrack = State.Tracking
        State.Tracking = false
        setCamlock(plr, 8) -- camlock whole knock
        for i = 1, 45 do
            if not isAlive(plr) then break end
            if useGun then
                if i % 6 == 0 then reloadGun(equipGun()) end
                shoot(plr)
            else
                punch(plr)
            end
            task.wait(0.05)
        end
        if isKO(plr) then
            for _ = 1, 10 do
                if not isKO(plr) then break end
                stomp(plr)
                task.wait(0.1)
            end
        end
        clearCamlock()
        State.Tracking = savedTrack
        if not State.InVoid and savedTrack and not IsOwner then
            followOwner()
        end
        notify("Knock done " .. plr.Name)
    end)
end

local function cmdRage(user)
    local plr = findPlayer(user)
    if not plr then
        notify("Rage: player not found")
        return
    end
    local my = getHRP()
    local their = getHRP(plr)
    if not my or not their then return end
    local saved = my.CFrame
    task.spawn(function()
        local useGun = false
        if PreferredGun and PreferredGun ~= "" then
            local g = equipGun()
            useGun = g ~= nil
            State.Armed = useGun
            muteGunSounds()
        end
        local savedTrack = State.Tracking
        State.Tracking = false
        setCamlock(plr, 8)
        pcall(function() my.CFrame = CFrame.new(their.Position + Vector3.new(0, 35, 0), their.Position) end)
        task.wait(0.08)
        for i = 1, 40 do
            if not isAlive(plr) then break end
            their = getHRP(plr)
            if their then
                if useGun then
                    if i % 6 == 0 then reloadGun(equipGun()) end
                    shoot(plr)
                else
                    punch(plr)
                end
            end
            task.wait(0.05)
        end
        if isKO(plr) then
            for _ = 1, 8 do
                stomp(plr)
                task.wait(0.1)
            end
        end
        clearCamlock()
        State.Tracking = savedTrack
        if not State.InVoid then
            pcall(function() my.CFrame = saved end)
        end
        notify("Rage done " .. plr.Name)
    end)
end

local function cmdTarget(user)
    if not user then
        State.TargetName = nil
        clearCamlock()
        notify("Target cleared")
        return
    end
    local plr = findPlayer(user)
    if plr then
        State.TargetName = plr.Name
        setCamlock(plr, 0) -- permanent until cleared / fix
        notify("Target " .. plr.Name .. " (camlock ON)")
    end
end

local function cmdOS()
    if IsOwner then return end
    State.BodyShield = not State.BodyShield
    notify("OS " .. (State.BodyShield and "ON" or "OFF"))
end

local function cmdSweep()
    task.spawn(function()
        local savedTrack = State.Tracking
        State.Tracking = false
        if PreferredGun and PreferredGun ~= "" then
            local g = equipGun()
            State.Armed = g ~= nil
            muteGunSounds()
        end
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and isAlive(plr) and not isWL(plr) then
                if string.lower(plr.Name) == string.lower(OwnerName) then
                    -- never attack owner
                elseif State.ProtectName and string.lower(plr.Name) == string.lower(State.ProtectName) then
                    -- skip
                else
                    for i = 1, 25 do
                        if not isAlive(plr) then break end
                        if State.Armed then shoot(plr) else punch(plr) end
                        task.wait(0.06)
                    end
                    if isKO(plr) then
                        for _ = 1, 5 do
                            stomp(plr)
                            task.wait(0.1)
                        end
                    end
                end
            end
        end
        State.Tracking = savedTrack
        notify("Sweep done")
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
    State.StompAura = false
    State.BodyShield = false
    State.RageKA = false
    State.TargetName = nil
    clearCamlock()
    unequip() -- fully unequip; next .arm will only pull preferred gun
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
    if ka and not isKO(LocalPlayer) and tick() - lastKA > 0.08 then
        lastKA = tick()
        local target = State.TargetName and findPlayer(State.TargetName)
        if target and isAlive(target) then
            setCamlock(target, 0.5)
            if State.Armed then shoot(target) else punch(target) end
        else
            local my = getHRP()
            if my then
                local best, bestD = nil, 25
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr ~= LocalPlayer and isAlive(plr) and not isWL(plr)
                        and string.lower(plr.Name) ~= string.lower(OwnerName) then
                        if State.ProtectName and string.lower(plr.Name) == string.lower(State.ProtectName) then
                            -- skip
                        else
                            local th = getHRP(plr)
                            if th then
                                local d = (th.Position - my.Position).Magnitude
                                if d < bestD then bestD = d best = plr end
                            end
                        end
                    end
                end
                if best then
                    setCamlock(best, 0.5)
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

----------------------------------------------------------------------
-- INTRO GUI (slide up)
----------------------------------------------------------------------
local function showIntroGui()
    pcall(function()
        local pg = LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5)
        if not pg then return end
        local old = pg:FindFirstChild("ExecutiveStandIntro")
        if old then old:Destroy() end

        local gui = Instance.new("ScreenGui")
        gui.Name = "ExecutiveStandIntro"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 999
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.Parent = pg

        local holder = Instance.new("Frame")
        holder.Name = "Holder"
        holder.AnchorPoint = Vector2.new(0.5, 0.5)
        holder.Position = UDim2.new(0.5, 0, 0.62, 0) -- start slightly below center
        holder.Size = UDim2.new(0, 320, 0, 64)
        holder.BackgroundColor3 = Color3.fromRGB(55, 72, 92)
        holder.BackgroundTransparency = 0.12
        holder.BorderSizePixel = 0
        holder.Parent = gui

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 14)
        corner.Parent = holder

        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(120, 150, 180)
        stroke.Thickness = 1.2
        stroke.Transparency = 0.45
        stroke.Parent = holder

        local grad = Instance.new("UIGradient")
        grad.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(70, 90, 115)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(45, 58, 78)),
        })
        grad.Rotation = 90
        grad.Parent = holder

        local label = Instance.new("TextLabel")
        label.Name = "Title"
        label.BackgroundTransparency = 1
        label.Size = UDim2.new(1, -24, 1, 0)
        label.Position = UDim2.new(0, 12, 0, 0)
        label.Font = Enum.Font.GothamMedium
        label.Text = "Executive Stand"
        label.TextColor3 = Color3.fromRGB(245, 248, 252)
        label.TextSize = 26
        label.TextXAlignment = Enum.TextXAlignment.Center
        label.TextYAlignment = Enum.TextYAlignment.Center
        label.Parent = holder

        local sub = Instance.new("TextLabel")
        sub.BackgroundTransparency = 1
        sub.Size = UDim2.new(1, -24, 0, 18)
        sub.Position = UDim2.new(0, 12, 1, -22)
        sub.Font = Enum.Font.Gotham
        sub.Text = IsOwner and "Owner ready" or ("Alt slot " .. tostring(MySlot))
        sub.TextColor3 = Color3.fromRGB(180, 200, 220)
        sub.TextSize = 12
        sub.TextTransparency = 0.15
        sub.Parent = holder

        -- start transparent + lower, slide up + fade in
        holder.BackgroundTransparency = 1
        label.TextTransparency = 1
        sub.TextTransparency = 1
        stroke.Transparency = 1

        local ti = TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
        TweenService:Create(holder, ti, {
            Position = UDim2.new(0.5, 0, 0.5, 0),
            BackgroundTransparency = 0.12,
        }):Play()
        TweenService:Create(label, ti, { TextTransparency = 0 }):Play()
        TweenService:Create(sub, ti, { TextTransparency = 0.15 }):Play()
        TweenService:Create(stroke, ti, { Transparency = 0.45 }):Play()

        -- hold, then slide up further + fade out
        task.delay(2.4, function()
            if not gui.Parent then return end
            local to = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
            TweenService:Create(holder, to, {
                Position = UDim2.new(0.5, 0, 0.38, 0),
                BackgroundTransparency = 1,
            }):Play()
            TweenService:Create(label, to, { TextTransparency = 1 }):Play()
            TweenService:Create(sub, to, { TextTransparency = 1 }):Play()
            TweenService:Create(stroke, to, { Transparency = 1 }):Play()
            task.delay(0.55, function()
                if gui then gui:Destroy() end
            end)
        end)
    end)
end

-- background auto-reload while armed (aggressive — works even without ammo values)
task.spawn(function()
    local lastForce = 0
    while true do
        task.wait(0.35)
        if State.Armed and not State.InVoid then
            local gun = findToolByName(PreferredGun, false)
            if gun then
                if needsReload(gun) or (tick() - lastForce > 2.5) then
                    lastForce = tick()
                    reloadGun(gun)
                    if State.Armed then equipGun() end
                end
            end
        end
    end
end)

showIntroGui()

print("[Stand] Main loaded |", IsOwner and "OWNER" or ("ALT slot " .. tostring(MySlot)), "| prefix", Prefix, "| owner", OwnerName)
if IsOwner then
    notify("Owner ready — command alts with " .. Prefix .. "help")
else
    print("[Stand] Listening for chat from owner:", OwnerName)
    if not OwnerName or OwnerName == "" then
        warn("[Stand] Owner name is EMPTY — run /setuploader in Discord then re-download /loader")
    end
end
