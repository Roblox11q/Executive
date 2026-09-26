--[[
    STAND BOT MAIN — Da Hood + DERS/Des Hood + Hood Customs
    Controlled by owner chat commands (Prefix from config)
    Inject on ALTS only — owner just types commands in public chat.
    Supported places:
      - Da Hood          (2788229376)
      - [RANKED] Da Hood / related (16033173781)
      - DERS HOOD        (96247461091106)
      - Des Hood         (128413479081937)
      - Hood Customs     (9825515356)
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
-- normalize so bot config "[DoubleBarrel]" still finds Da Hood / DERS HOOD's "[Double-Barrel SG]"
do
    local pid = game.PlaceId
    -- Da Hood-style places (including DERS HOOD clones)
    local daHoodStyle = (pid == 2788229376 or pid == 16033173781 or pid == 96247461091106 or pid == 128413479081937)
    local g = tostring(PreferredGun)
    local low = string.lower(g:gsub("[%[%]]", ""):gsub("%s+", ""))
    if low == "doublebarrel" or low == "doublebarrelsg" or low == "db" then
        PreferredGun = daHoodStyle and "[Double-Barrel SG]" or "[DoubleBarrel]"
    end
end
-- Rank: free < premium < bypass (shield). Higher can command lower stands in-server.
local MyRank = string.lower(tostring(Config.Rank or "free"))
if MyRank ~= "premium" and MyRank ~= "bypass" then MyRank = "free" end
local RANK_POWER = { free = 0, premium = 1, bypass = 2 }
local function rankPower(r)
    return RANK_POWER[string.lower(tostring(r or "free"))] or 0
end
-- Known higher-tier owners in this server (from loader) so free scripts obey them
local RankedOwners = {} -- name lower -> rank string
do
    local list = Config.RankedOwners or {}
    if type(list) == "table" then
        for k, v in pairs(list) do
            if type(k) == "string" and type(v) == "string" then
                RankedOwners[string.lower(k)] = string.lower(v)
            elseif type(k) == "number" and type(v) == "table" then
                local n, r = v.name or v[1], v.rank or v[2]
                if n then RankedOwners[string.lower(tostring(n))] = string.lower(tostring(r or "premium")) end
            end
        end
    end
end
RankedOwners[string.lower(OwnerName)] = MyRank

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
    BodyShield = false, -- now ORBIT around owner (not sticky)
    RageKA = false,
    Taunt = false,
    TargetName = nil,
    ProtectName = nil,
    FPSBoost = false,
    Armed = false,
    Camlock = false,
    LoopKill = nil, -- player name string, or nil
    LoopKillKnife = false, -- if true, loopkill uses knife instead of gun/punch
    Carrying = nil, -- player name being carried to owner
    KnifeMode = false,
    StealthKnife = false, -- invisible while knifing
}

local Whitelist = {} -- UserId -> true (don't attack)
local Connections = {}
local SavedCF = nil
local VoidCF = CFrame.new(0, -480, 0)
local CamTarget = nil
local CamlockUntil = 0
local OrbitAngle = 0

-- forward decls (defined later with knife helpers)
local setStealthVisible
local knifeAttackTarget
local findKnife
local expandKnifeHitbox
local knifeInstantTP

-- Extra Roblox usernames allowed to issue commands (from config)
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

local function canControl(plr)
    if not plr then return false end
    local n = string.lower(plr.Name)
    if n == string.lower(OwnerName) then return true end
    if Controllers[n] then return true end
    -- Higher-rank owners in this server can issue limited cmds against lower-rank stands
    local theirRank = RankedOwners[n]
    if theirRank and rankPower(theirRank) > rankPower(MyRank) then
        return true -- they can try rank cmds; handler filters which cmds
    end
    return false
end

local function speakerCanAffectUs(speaker)
    if not speaker then return false end
    local n = string.lower(speaker.Name)
    if n == string.lower(OwnerName) then return true end
    if Controllers[n] then return true end
    local theirRank = RankedOwners[n] or "free"
    -- bypass can affect free+premium; premium can affect free only; cannot affect same/higher
    return rankPower(theirRank) > rankPower(MyRank)
end

local function isRankCommand(cmd)
    return cmd == "benx" or cmd == "unbenx" or cmd == "pkick" or cmd == "forcevoid"
        or cmd == "swag" or cmd == "swagmode" or cmd == "fakeban" or cmd == "fb"
        or cmd == "forcefix" or cmd == "ranklock" or cmd == "silence"
end

local function isProtected(plr)
    if not plr then return false end
    if Whitelist[plr.UserId] then return true end
    if State.ProtectName and string.lower(plr.Name) == string.lower(State.ProtectName) then
        return true
    end
    if string.lower(plr.Name) == string.lower(OwnerName) then return true end
    return false
end

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
-- DA HOOD / DERS HOOD / HOOD CUSTOMS HELPERS
----------------------------------------------------------------------
local PlaceId = game.PlaceId
-- Da Hood + ranked + DERS HOOD (same MainEvent / mouse remote family)
local IsDaHood = (PlaceId == 2788229376 or PlaceId == 16033173781)
local IsDersHood = (PlaceId == 96247461091106 or PlaceId == 128413479081937) -- DERS HOOD + Des Hood
local IsDaHoodStyle = IsDaHood or IsDersHood -- shared remotes & gun names
local IsHoodCustoms = (PlaceId == 9825515356)
local IsHoodGame = IsDaHoodStyle or IsHoodCustoms or true -- default to hood-style remotes

local MainEvent = nil
local MouseRemote = "MousePosUpdate"
pcall(function()
    MainEvent = ReplicatedStorage:FindFirstChild("MainEvent")
        or ReplicatedStorage:FindFirstChild("MainEventt")
        or ReplicatedStorage:FindFirstChild("MAINEVENT")
    -- Place-correct mouse remote (wrong name = error_sum spam / no aim)
    if IsDaHoodStyle then
        -- classic Da Hood, ranked, and DERS HOOD clones
        MouseRemote = "UpdateMousePosI"
    elseif IsHoodCustoms then
        MouseRemote = "MousePosUpdate"
    elseif PlaceId == 5602055394 then
        MouseRemote = "MousePos"
    else
        -- fallback: try common names used across hood clones
        MouseRemote = "UpdateMousePos"
        if MainEvent then
            pcall(function()
                if MainEvent:FindFirstChild("UpdateMousePosI") then
                    MouseRemote = "UpdateMousePosI"
                end
            end)
        end
    end
end)

local placeLabel =
    (PlaceId == 128413479081937 and "Des Hood")
    or (PlaceId == 96247461091106 and "DERS HOOD")
    or (IsDaHood and "Da Hood")
    or (IsHoodCustoms and "Hood Customs")
    or "unknown hood"
print("[Stand] Place", PlaceId, placeLabel, "| MouseRemote =", MouseRemote)

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
    -- Only the place-correct remote (spamming wrong args = red error_sum on Hood Customs)
    if MainEvent then
        pcall(function() MainEvent:FireServer(MouseRemote, pos) end)
    end
    -- BodyEffects.MousePos (Da Hood / Hood Customs gun aim value)
    pcall(function()
        local c = getChar()
        local be = c and c:FindFirstChild("BodyEffects")
        local mp = be and (be:FindFirstChild("MousePos") or be:FindFirstChild("MousePosition"))
        if mp then
            if mp:IsA("Vector3Value") or mp:IsA("CFrameValue") then
                mp.Value = typeof(mp.Value) == "CFrame" and CFrame.new(pos) or pos
            elseif mp:IsA("ObjectValue") then
                -- some places store differently
            end
        end
    end)
end

local function getAimPart(plr)
    local ok, part = pcall(function()
        local c = getChar(plr)
        if not c then return nil end
        return c:FindFirstChild("Head")
            or c:FindFirstChild("UpperTorso")
            or c:FindFirstChild("Torso")
            or c:FindFirstChild("HumanoidRootPart")
    end)
    if ok then return part end
    return nil
end

local function getTargetAimPos(plr)
    local part = getAimPart(plr)
    if not part then
        local hrp = getHRP(plr)
        return hrp and (hrp.Position + Vector3.new(0, 1.5, 0)) or nil
    end
    local ok, aim = pcall(function()
        local p = part.Position
        -- always bias toward head center for consistent hits
        if part.Name == "Head" then
            p = p + Vector3.new(0, 0.05, 0)
        else
            p = p + Vector3.new(0, 0.35, 0)
        end
        local their = getHRP(plr)
        local my = getHRP()
        if their then
            local vel = their.AssemblyLinearVelocity or Vector3.zero
            -- distance-based lead so shots land at range
            local dist = my and (their.Position - my.Position).Magnitude or 20
            local lead = math.clamp(0.12 + (dist / 180), 0.14, 0.38)
            p = p + Vector3.new(vel.X * lead, math.clamp(vel.Y, -25, 25) * 0.08, vel.Z * lead)
        end
        return p
    end)
    return ok and aim or nil
end

-- Force-hit: spam aim + hit remotes so guns register even on lag / partial misses
-- (must be AFTER getTargetAimPos so it is not nil)
local function forceHit(plr, gun)
    if not plr then return end
    local aim = getTargetAimPos(plr)
    if not aim then
        local hrp = getHRP(plr)
        aim = hrp and (hrp.Position + Vector3.new(0, 1.4, 0)) or nil
    end
    if not aim then return end
    for _ = 1, 6 do
        fireMouse(aim)
    end
    pcall(function()
        local cam = Workspace.CurrentCamera
        if cam then
            cam.CFrame = CFrame.lookAt(cam.CFrame.Position, aim)
            cam.Focus = CFrame.new(aim)
        end
    end)
    if gun then
        pcall(function() gun:Activate() end)
    end
    if MainEvent then
        pcall(function() MainEvent:FireServer("Shoot", aim) end)
        pcall(function() MainEvent:FireServer("Hit", plr.Character) end)
        pcall(function() MainEvent:FireServer("Hit", plr) end)
        pcall(function() MainEvent:FireServer(MouseRemote, aim) end)
        if gun then
            pcall(function() MainEvent:FireServer("Shoot", gun.Name, aim) end)
            pcall(function() MainEvent:FireServer("Fire", gun.Name) end)
        end
    end
    if gun then
        pcall(function()
            for _, v in ipairs(gun:GetDescendants()) do
                local n = string.lower(v.Name)
                if v:IsA("RemoteEvent") and (string.find(n, "shoot", 1, true) or string.find(n, "fire", 1, true) or string.find(n, "hit", 1, true)) then
                    pcall(function() v:FireServer(aim) end)
                    pcall(function() v:FireServer() end)
                end
            end
        end)
    end
end

local CamlockHighlight = nil
local origMinZoom, origMaxZoom, origCamMode, origCamType = nil, nil, nil, nil
local CAMLOCK_BIND = "StandCamlockPriority"

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
        h.FillTransparency = 0.55
        h.OutlineTransparency = 0
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.Parent = character
        CamlockHighlight = h
    end)
end

local function moveCursorToWorld(worldPos)
    local cam = Workspace.CurrentCamera
    if not cam or not worldPos then return end
    local sp, onScreen = cam:WorldToViewportPoint(worldPos)
    -- still move even if slightly off-screen edge
    local x, y = sp.X, sp.Y
    local vs = cam.ViewportSize
    x = math.clamp(x, 0, vs.X)
    y = math.clamp(y, 0, vs.Y)
    pcall(function()
        if mousemoveabs then mousemoveabs(x, y) end
    end)
    pcall(function()
        if mousemoverel then
            local mx, my = 0, 0
            if UserInputService.GetMouseLocation then
                local m = UserInputService:GetMouseLocation()
                mx, my = m.X, m.Y
            end
            mousemoverel(x - mx, y - my)
        end
    end)
    pcall(function()
        if syn and syn.mousemoveabs then syn.mousemoveabs(x, y) end
    end)
    pcall(function()
        local vim = game:GetService("VirtualInputManager")
        if vim then vim:SendMouseMoveEvent(x, y, game) end
    end)
    -- center fallback: if executor mouse APIs fail, at least screen-center is head via Scriptable cam
end

local function clearCamlock()
    CamTarget = nil
    State.Camlock = false
    CamlockUntil = 0
    removeCamESP()
    pcall(function()
        RunService:UnbindFromRenderStep(CAMLOCK_BIND)
    end)
    pcall(function()
        local cam = Workspace.CurrentCamera
        if cam and origCamType ~= nil then
            cam.CameraType = origCamType
        end
        if origCamMode ~= nil then
            LocalPlayer.CameraMode = origCamMode
            LocalPlayer.CameraMinZoomDistance = origMinZoom or 0.5
            LocalPlayer.CameraMaxZoomDistance = origMaxZoom or 128
        end
    end)
    origCamMode, origCamType = nil, nil
end

-- Runs AFTER default camera (priority Camera+1) so lock sticks every frame
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
    if not plr or not getChar(plr) then
        clearCamlock()
        return
    end

    -- prefer predicted aim pos (velocity lead) over raw head
    local aim = getTargetAimPos(plr)
    if not aim then
        local hrp = getHRP(plr)
        aim = hrp and (hrp.Position + Vector3.new(0, 1.5, 0)) or nil
    end
    if not aim then return end

    local cam = Workspace.CurrentCamera
    if not cam then return end

    pcall(function()
        if cam.CameraType ~= Enum.CameraType.Scriptable then
            cam.CameraType = Enum.CameraType.Scriptable
        end
        local my = getHRP()
        local camPos
        if my then
            camPos = my.Position + Vector3.new(0, 2.4, 0) - my.CFrame.LookVector * 0.25
        else
            camPos = cam.CFrame.Position
        end
        cam.CFrame = CFrame.lookAt(camPos, aim)
        cam.Focus = CFrame.new(aim)
    end)

    moveCursorToWorld(aim)
    -- spam mouse pos so server always has latest aim (hits more consistently)
    for _ = 1, 6 do
        fireMouse(aim)
    end
end

local function setCamlock(plr, seconds)
    if not plr then return end
    -- allow KO targets for bring
    if not getChar(plr) and not isAlive(plr) then return end
    CamTarget = plr
    State.Camlock = true
    if seconds and seconds > 0 then
        CamlockUntil = tick() + seconds
    else
        CamlockUntil = tick() + 999999
    end

    local cam = Workspace.CurrentCamera
    if origCamType == nil and cam then
        origCamType = cam.CameraType
        origMinZoom = LocalPlayer.CameraMinZoomDistance
        origMaxZoom = LocalPlayer.CameraMaxZoomDistance
        origCamMode = LocalPlayer.CameraMode
    end
    pcall(function()
        LocalPlayer.CameraMode = Enum.CameraMode.Classic
        if cam then cam.CameraType = Enum.CameraType.Scriptable end
    end)
    if plr.Character then createCamESP(plr.Character) end

    pcall(function()
        RunService:UnbindFromRenderStep(CAMLOCK_BIND)
    end)
    -- higher than default camera so we win every frame
    RunService:BindToRenderStep(
        CAMLOCK_BIND,
        Enum.RenderPriority.Camera.Value + 1,
        camlockStep
    )
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
    -- also map common aliases across Da Hood / Hood Customs
    local n = string.lower((tostring(name):gsub("[%[%]]", ""):gsub("%s+", " ")):match("^%s*(.-)%s*$") or "")
    -- aliases so config "DoubleBarrel" finds "[Double-Barrel SG]" and vice versa
    if n == "doublebarrel" or n == "double barrel" or n == "double-barrel" or n == "db" then
        return "double-barrel sg"
    end
    if n == "double-barrel sg" or n == "doublebarrel sg" then
        return "double-barrel sg"
    end
    return n
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

-- Instant TP once, then walk. Spam TP = ERROR_CLIENT_PATTERN_UNSYNCED_SERVER
local lastBodyLock = 0
local TP_COOLDOWN = 1.25
local StateBenx = false

local function ensureVisible()
    local c = getChar()
    if not c then return end
    pcall(function()
        for _, d in ipairs(c:GetDescendants()) do
            if d:IsA("BasePart") then
                d.LocalTransparencyModifier = 0
                if d.Name ~= "HumanoidRootPart" and d.Transparency >= 1 then
                    d.Transparency = 0
                end
            end
        end
    end)
end

local function getBehindPos(plr, behindDist)
    behindDist = behindDist or 7.0
    local their = getHRP(plr)
    if not their then return nil end
    local back = -their.CFrame.LookVector
    if back.Magnitude < 0.05 then
        back = Vector3.new(0, 0, 1)
    end
    return Vector3.new(
        their.Position.X + back.X * behindDist,
        their.Position.Y,
        their.Position.Z + back.Z * behindDist
    )
end

-- force=true: one instant TP (cooldown). else: walk only
local function lockOnTarget(plr, behindDist, height, force)
    local my = getHRP()
    local their = getHRP(plr)
    if not my or not their then return false end

    if State.InVoid then State.InVoid = false end
    ensureVisible()

    local pos = getBehindPos(plr, behindDist or 7.0)
    if not pos then return false end
    local head = nil
    pcall(function()
        local c = getChar(plr)
        head = c and c:FindFirstChild("Head")
    end)
    local lookAt = (head and head.Position) or (their.Position + Vector3.new(0, 1.5, 0))
    local cf = CFrame.new(pos, lookAt)

    local now = tick()
    local dist = (my.Position - pos).Magnitude
    local canTP = force and (now - lastBodyLock) >= TP_COOLDOWN and dist > 4

    if canTP then
        lastBodyLock = now
        pcall(function()
            local h = getHum()
            local char = getChar()
            if h then
                h.PlatformStand = false
                h:ChangeState(Enum.HumanoidStateType.Running)
            end
            if char and char.PivotTo then
                char:PivotTo(cf)
            end
            my.CFrame = cf
            my.AssemblyLinearVelocity = Vector3.zero
            my.AssemblyAngularVelocity = Vector3.zero
        end)
        -- wait for server to accept position (stops UNSYNCED_SERVER)
        task.wait(0.2)
        return true
    end

    pcall(function()
        local h = getHum()
        if h then
            h.PlatformStand = false
            h:MoveTo(pos)
        end
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
    if not lockOnTarget(plr, 5.0, 0, true) then return end
    aimAt(plr)
    activateTool(equipCombat())
    if MainEvent then
        pcall(function() MainEvent:FireServer("Punch") end)
        pcall(function() MainEvent:FireServer("Hit", plr.Character) end)
    end
end

local function stomp(plr)
    if not plr then return end
    if isProtected(plr) then return end
    local my = getHRP()
    local their = getHRP(plr)
    if not my or not their then return end
    -- get close to KO body then stomp hard
    pcall(function()
        local h = getHum()
        if h then
            h.PlatformStand = false
            h:MoveTo(their.Position)
        end
        -- soft snap if close enough (helps land stomp)
        local dist = (my.Position - their.Position).Magnitude
        if dist < 12 then
            my.CFrame = CFrame.new(their.Position + Vector3.new(0, 2.5, 0))
            my.AssemblyLinearVelocity = Vector3.zero
        end
    end)
    task.wait(0.04)
    local tool = equipCombat()
    activateTool(tool)
    if MainEvent then
        pcall(function() MainEvent:FireServer("Stomp") end)
        pcall(function() MainEvent:FireServer("Stomp", plr.Character) end)
        pcall(function() MainEvent:FireServer("Stomp", plr) end)
    end
    task.wait(0.06)
    activateTool(tool)
    if MainEvent then
        pcall(function() MainEvent:FireServer("Stomp") end)
        pcall(function() MainEvent:FireServer("Stomp", plr.Character) end)
    end
    task.wait(0.04)
    activateTool(tool)
end

local function softReload(gun)
    -- reload IN PLACE only — never teleports / void
    if not gun then return end
    if MainEvent then
        pcall(function() MainEvent:FireServer("Reload") end)
        pcall(function() MainEvent:FireServer("Reload", gun.Name) end)
    end
    pcall(function()
        local vim = game:GetService("VirtualInputManager")
        if vim then
            vim:SendKeyEvent(true, Enum.KeyCode.R, false, game)
            task.wait(0.03)
            vim:SendKeyEvent(false, Enum.KeyCode.R, false, game)
        end
    end)
end

local function shoot(plr)
    if not plr or isProtected(plr) then return end
    if not getHRP(plr) then return end

    -- leave void before shooting so owner can see the alt
    if State.InVoid then
        State.InVoid = false
        task.wait(0.05)
    end
    ensureVisible()
    setCamlock(plr, 2.5)

    local gun = equipGun()
    if not gun then return end
    muteGunSounds()

    -- soft reload only, stay on target
    if needsReload(gun) then
        softReload(gun)
        task.wait(0.06)
        gun = equipGun()
        if not gun then return end
    end

    -- closer range = more reliable hits on Hood Customs
    lockOnTarget(plr, 5.5, 0, true)
    local aim0 = getTargetAimPos(plr)
    if aim0 then
        for _ = 1, 4 do fireMouse(aim0) end
    end
    aimAt(plr)

    for i = 1, 14 do
        if not isAlive(plr) then break end
        gun = findToolByName(PreferredGun, false)
        if not gun or not isToolEquipped(gun) then
            gun = equipGun()
            if not gun then break end
        end
        if needsReload(gun) then
            softReload(gun)
            gun = equipGun()
            if not gun then break end
        end
        -- stay glued behind target + force hit every shot
        lockOnTarget(plr, 5.5, 0, false)
        local aim = getTargetAimPos(plr) or aimAt(plr)
        forceHit(plr, gun)
        activateTool(gun)
        task.wait(0.02)
        forceHit(plr, gun)
        activateTool(gun)
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
        -- ORBIT around owner (harder to shoot) instead of sticky bodyblock
        OrbitAngle = OrbitAngle + 0.085
        local radius = 3.6
        local y = 1.2
        local offset = Vector3.new(math.cos(OrbitAngle + MySlot) * radius, y, math.sin(OrbitAngle + MySlot) * radius)
        pcall(function()
            my.CFrame = CFrame.new(oHRP.Position + offset, oHRP.Position)
            my.AssemblyLinearVelocity = Vector3.zero
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
    if isProtected(plr) then
        notify("Knock: target is protected")
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
        setCamlock(plr, 8)
        -- one instant TP behind target, then shoot
        lockOnTarget(plr, 7.0, 0, true)
        aimAt(plr)
        task.wait(0.05)
        for i = 1, 45 do
            if not isAlive(plr) then break end
            if useGun then
                shoot(plr)
            else
                punch(plr)
            end
            task.wait(0.05)
        end
        if isKO(plr) then
            for _ = 1, 12 do
                if not isKO(plr) then break end
                stomp(plr)
                task.wait(0.12)
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
        -- walk in only — no sky teleport (triggers UNSYNCED_SERVER)
        pcall(function()
            local h = getHum()
            if h and their then h:MoveTo(their.Position) end
        end)
        task.wait(0.15)
        for i = 1, 40 do
            if not isAlive(plr) then break end
            their = getHRP(plr)
            if their then
                if useGun then
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
    if State.BodyShield then
        State.Tracking = true
        State.InVoid = false
    end
    notify("Orbit " .. (State.BodyShield and "ON" or "OFF"))
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
    if not plr then
        notify("Stomp: player not found")
        return
    end
    if isProtected(plr) then
        notify("Stomp: target protected")
        return
    end
    task.spawn(function()
        local savedTrack = State.Tracking
        State.Tracking = false
        setCamlock(plr, 6)
        -- if not already KO, knock them first
        if not isKO(plr) and isAlive(plr) then
            notify("Stomp: knocking " .. plr.Name)
            local useGun = PreferredGun and PreferredGun ~= "" and equipGun() ~= nil
            for i = 1, 35 do
                if isKO(plr) or not getChar(plr) then break end
                if useGun then shoot(plr) else punch(plr) end
                task.wait(0.05)
            end
        end
        if isKO(plr) then
            for _ = 1, 18 do
                if not isKO(plr) then break end
                stomp(plr)
                task.wait(0.1)
            end
            notify("Stomp done " .. plr.Name)
        else
            notify("Stomp: failed to KO " .. plr.Name)
        end
        clearCamlock()
        State.Tracking = savedTrack
        if not State.InVoid and savedTrack and not IsOwner then
            followOwner()
        end
    end)
end

local function cmdRK()
    State.RageKA = not State.RageKA
    if State.RageKA then
        -- when turning on, also clear target so it picks nearest / owner-down targets
        if not State.TargetName then
            -- keep target if set
        end
        State.KillAura = false -- rk is separate from regular KA
    else
        clearCamlock()
    end
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
    if not user or user == "" then
        notify("Protect: need a name")
        return
    end
    local plr = findPlayer(user)
    if plr then
        State.ProtectName = plr.Name
        Whitelist[plr.UserId] = true
        notify("Protect ON " .. plr.Name)
    else
        -- allow protecting offline / by name string
        State.ProtectName = user
        notify("Protect ON (name) " .. user)
    end
end

local function cmdUnprotect()
    if State.ProtectName then
        local plr = findPlayer(State.ProtectName)
        if plr then Whitelist[plr.UserId] = nil end
    end
    State.ProtectName = nil
    notify("Protect cleared")
end

local function cmdLoopKill(user)
    if not user or user == "" then
        notify("loopkill: need a name")
        return
    end
    local plr = findPlayer(user)
    if not plr then
        notify("loopkill: not found")
        return
    end
    State.LoopKill = plr.Name
    State.LoopKillKnife = false
    State.Tracking = false
    setCamlock(plr, 0)
    notify("LoopKill ON " .. plr.Name)
end

local function cmdLoopKillKnife(user)
    if not user or user == "" then
        notify("lkk: need a name")
        return
    end
    local plr = findPlayer(user)
    if not plr then
        notify("lkk: not found")
        return
    end
    if isProtected(plr) then
        notify("lkk: target protected")
        return
    end
    State.LoopKill = plr.Name
    State.LoopKillKnife = true
    State.Tracking = false
    setCamlock(plr, 0)
    notify("LoopKill Knife (stealth) ON " .. plr.Name)
end

local function cmdUnLoopKill()
    State.LoopKill = nil
    State.LoopKillKnife = false
    setStealthVisible(true)
    ensureVisible()
    clearCamlock()
    if not IsOwner then State.Tracking = true end
    notify("LoopKill OFF")
end

-- Forced crouch / "benx" (higher rank used this on us)
local function setBenx(on)
    StateBenx = on and true or false
    notify(StateBenx and "BENX ON (forced crouch)" or "BENX OFF")
end

task.spawn(function()
    while true do
        task.wait(0.15)
        if StateBenx and not IsOwner then
            pcall(function()
                local h = getHum()
                local my = getHRP()
                if h then
                    h.WalkSpeed = 8
                    h.JumpPower = 0
                    h.JumpHeight = 0
                    -- crouch-like: sink and lock
                    h:ChangeState(Enum.HumanoidStateType.Crouching)
                end
                if my then
                    my.CFrame = my.CFrame * CFrame.new(0, -0.4, 0)
                    my.AssemblyLinearVelocity = Vector3.new(0, my.AssemblyLinearVelocity.Y, 0)
                end
            end)
        end
    end
end)

local function cmdBenx(user, speaker)
    -- If targeting us (or no arg from higher rank targeting this alt name)
    local me = string.lower(LocalPlayer.Name)
    if user and user ~= "" then
        local t = findPlayer(user)
        if t and string.lower(t.Name) ~= me then
            -- we only apply to ourselves when targeted
            return
        end
        if user and not string.find(me, string.lower(user), 1, true) and string.lower(user) ~= me then
            return
        end
    end
    if speaker and not speakerCanAffectUs(speaker) and string.lower(speaker.Name) ~= string.lower(OwnerName) then
        return
    end
    setBenx(true)
end

local function cmdUnBenx(speaker)
    if speaker and not speakerCanAffectUs(speaker) and string.lower(speaker.Name) ~= string.lower(OwnerName) then
        return
    end
    setBenx(false)
    pcall(function()
        local h = getHum()
        if h then
            h.WalkSpeed = 16
            h.JumpPower = 50
        end
    end)
end

local function cmdPKick(user, speaker)
    local me = string.lower(LocalPlayer.Name)
    if user and user ~= "" then
        if not string.find(me, string.lower(user), 1, true) and string.lower(user) ~= me then
            return
        end
    end
    if speaker and not speakerCanAffectUs(speaker) then
        return
    end
    -- only lower ranks get force-kicked
    if rankPower(MyRank) >= rankPower(RankedOwners[string.lower(speaker and speaker.Name or "")] or "premium")
        and string.lower(speaker.Name) ~= string.lower(OwnerName) then
        return
    end
    notify("PKICK by higher rank")
    pcall(function()
        TeleportService:Teleport(game.PlaceId, LocalPlayer)
    end)
    task.delay(1, function()
        pcall(function() LocalPlayer:Kick("Stand: pkick by higher rank") end)
    end)
end

local function cmdForceVoid(user, speaker)
    local me = string.lower(LocalPlayer.Name)
    if user and user ~= "" then
        if not string.find(me, string.lower(user), 1, true) and string.lower(user) ~= me then
            return
        end
    end
    if speaker and not speakerCanAffectUs(speaker) then return end
    State.InVoid = true
    State.Tracking = false
    notify("Force void")
end

local function carryStep()
    if IsOwner or not State.Carrying then return end
    local victim = findPlayer(State.Carrying)
    if not victim then
        State.Carrying = nil
        return
    end
    -- if they got up, re-knock quickly
    if not isKO(victim) and isAlive(victim) then
        punch(victim)
        return
    end
    local vHRP = getHRP(victim)
    local my = getHRP()
    if not vHRP or not my then return end

    -- hard hold body in front of alt every frame
    pcall(function()
        vHRP.CFrame = my.CFrame * CFrame.new(0, 0.7, -1.6)
        vHRP.AssemblyLinearVelocity = Vector3.zero
        vHRP.AssemblyAngularVelocity = Vector3.zero
    end)
    if MainEvent then
        pcall(function() MainEvent:FireServer("Grabbing", true) end)
        pcall(function() MainEvent:FireServer("Grabbing") end)
        pcall(function() MainEvent:FireServer("Carry", true) end)
        pcall(function() MainEvent:FireServer("PickUp") end)
    end

    -- move toward owner fast
    local owner = getOwner()
    local oHRP = owner and getHRP(owner)
    if oHRP then
        local dist = (oHRP.Position - my.Position).Magnitude
        if dist > 4 then
            pcall(function()
                local targetPos = oHRP.Position + oHRP.CFrame.LookVector * 3.5 + Vector3.new(0, 0.5, 0)
                my.CFrame = CFrame.new(my.Position:Lerp(targetPos, 0.55), oHRP.Position)
                my.AssemblyLinearVelocity = Vector3.zero
            end)
        else
            pcall(function()
                my.CFrame = CFrame.new(oHRP.Position + oHRP.CFrame.LookVector * 3.5 + Vector3.new(0, 0.5, 0), oHRP.Position)
                my.AssemblyLinearVelocity = Vector3.zero
            end)
        end
    end
end

local function cmdDrop()
    if not State.Carrying then
        notify("Drop: not carrying")
        return
    end
    local name = State.Carrying
    local victim = findPlayer(name)
    State.Carrying = nil
    if MainEvent then
        pcall(function() MainEvent:FireServer("Grabbing", false) end)
    end
    if victim then
        local vHRP = getHRP(victim)
        local my = getHRP()
        if vHRP and my then
            pcall(function()
                vHRP.CFrame = my.CFrame * CFrame.new(0, 0, -4)
                vHRP.AssemblyLinearVelocity = Vector3.zero
            end)
        end
    end
    if not IsOwner then State.Tracking = true end
    clearCamlock()
    notify("Dropped " .. tostring(name))
end

local function cmdBring(user)
    if IsOwner then return end
    local plr = findPlayer(user)
    if not plr then
        notify("Bring: player not found")
        return
    end
    if isProtected(plr) then
        notify("Bring: target protected")
        return
    end
    task.spawn(function()
        local savedTrack = State.Tracking
        State.Tracking = false
        State.LoopKill = nil
        State.Carrying = nil
        setCamlock(plr, 20)
        notify("Bring: knocking " .. plr.Name)

        local useGun = false
        if PreferredGun and PreferredGun ~= "" then
            local g = equipGun()
            useGun = g ~= nil
            State.Armed = useGun
        end

        -- aggressive knock until KO
        for i = 1, 80 do
            if isKO(plr) then break end
            if not getChar(plr) then break end
            lockOnTarget(plr, 5.0, 0, i % 8 == 1)
            if useGun then shoot(plr) else punch(plr) end
            task.wait(0.035)
        end

        if not isKO(plr) then
            for _ = 1, 25 do
                if isKO(plr) then break end
                punch(plr)
                task.wait(0.035)
            end
        end

        if isKO(plr) then
            for _ = 1, 8 do
                stomp(plr)
                task.wait(0.07)
            end
            State.Carrying = plr.Name
            State.Tracking = false
            -- grab remotes (multiple hood variants)
            if MainEvent then
                pcall(function() MainEvent:FireServer("Grabbing", true) end)
                pcall(function() MainEvent:FireServer("Grabbing") end)
                pcall(function() MainEvent:FireServer("Carry", true) end)
                pcall(function() MainEvent:FireServer("PickUp") end)
            end
            -- hard snap body to us repeatedly so carry sticks
            for _ = 1, 6 do
                local vHRP = getHRP(plr)
                local my = getHRP()
                if vHRP and my then
                    pcall(function()
                        vHRP.CFrame = my.CFrame * CFrame.new(0, 0.8, -1.8)
                        vHRP.AssemblyLinearVelocity = Vector3.zero
                        vHRP.AssemblyAngularVelocity = Vector3.zero
                    end)
                end
                task.wait(0.05)
            end
            -- walk toward owner immediately
            local owner = getOwner()
            local oHRP = owner and getHRP(owner)
            local my = getHRP()
            if oHRP and my then
                pcall(function()
                    my.CFrame = CFrame.new(oHRP.Position + oHRP.CFrame.LookVector * 4 + Vector3.new(0, 0.5, 0), oHRP.Position)
                end)
            end
            notify("Bring: carrying " .. plr.Name .. " → owner (use .drop to release)")
        else
            notify("Bring: failed to KO " .. plr.Name)
            State.Tracking = savedTrack
            clearCamlock()
        end
    end)
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
    -- hard reset everything — does NOT toggle benx on; forces it OFF only
    State.InVoid = false
    State.Tracking = not IsOwner
    State.KillAura = false
    State.StompAura = false
    State.BodyShield = false
    State.RageKA = false
    State.LoopKill = nil
    State.LoopKillKnife = false
    State.Carrying = nil
    State.TargetName = nil
    State.KnifeMode = false
    State.StealthKnife = false
    FrozenTargets = {}
    clearCamlock()
    unequip()
    -- force benx off without toggling (direct set)
    StateBenx = false
    pcall(function()
        if setStealthVisible then setStealthVisible(true) end
        ensureVisible()
    end)
    pcall(function()
        local h = getHum()
        if h then
            h.WalkSpeed = 16
            h.JumpPower = 50
            h.JumpHeight = 7.2
            h.PlatformStand = false
            h:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
        local my = getHRP()
        if my then
            my.AssemblyLinearVelocity = Vector3.zero
        end
    end)
    if MainEvent then
        pcall(function() MainEvent:FireServer("Grabbing", false) end)
    end
    notify("Fix (all states cleared, benx OFF)")
end

local function cmdKick()
    pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
end

local function cmdFPS(off)
    if off then
        State.FPSBoost = false
        pcall(function()
            settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic
            Lighting.GlobalShadows = true
            Lighting.FogEnd = 100000
            Lighting.Brightness = 2
        end)
        notify("FPS off")
        return
    end
    State.FPSBoost = true
    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
        settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level01
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 1e9
        Lighting.Brightness = 1
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.EnvironmentSpecularScale = 0
        for _, v in ipairs(Workspace:GetDescendants()) do
            if v:IsA("ParticleEmitter") or v:IsA("Trail") or v:IsA("Smoke") or v:IsA("Fire") or v:IsA("Sparkles") then
                v.Enabled = false
            end
            if v:IsA("Decal") or v:IsA("Texture") then
                v.Transparency = 1
            end
            if v:IsA("Beam") then
                v.Enabled = false
            end
            if v:IsA("PointLight") or v:IsA("SpotLight") or v:IsA("SurfaceLight") then
                v.Enabled = false
            end
        end
        -- disable terrain decorations if present
        pcall(function()
            local terrain = Workspace:FindFirstChildOfClass("Terrain")
            if terrain then
                terrain.Decoration = false
            end
        end)
    end)
    notify("FPS on (max boost)")
end

local function cmdView()
    local lines = {"=== Players in server ==="}
    for _, plr in ipairs(Players:GetPlayers()) do
        local rank = RankedOwners[string.lower(plr.Name)]
        local tag = rank and string.upper(rank) or "unknown"
        local you = (plr == LocalPlayer) and " (you)" or ""
        local ko = isKO(plr) and " [KO]" or ""
        lines[#lines + 1] = string.format("%s | %s%s%s", plr.Name, tag, you, ko)
    end
    lines[#lines + 1] = "Your rank: " .. MyRank
    local text = table.concat(lines, "\n")
    print(text)
    notify("View: " .. #Players:GetPlayers() .. " players (see F9)")
end

findKnife = function()
    -- Da Hood uses "Knife"; Hood Customs often uses "[Knife]"
    local exact = findToolByName("[Knife]", true) or findToolByName("Knife", true)
    if exact then return exact end
    local c = getChar()
    local bag = LocalPlayer:FindFirstChild("Backpack")
    for _, container in ipairs({c, bag}) do
        if container then
            local t = container:FindFirstChild("[Knife]")
            if t and t:IsA("Tool") then return t end
        end
    end
    return findToolByName("[Knife]", false)
        or findToolByName("Knife", false)
        or findToolByName("Combat Knife", false)
end

-- Expand knife / character hit parts so swings reach the target
expandKnifeHitbox = function(knife, scale)
    scale = scale or 3.5
    pcall(function()
        if knife then
            for _, part in ipairs(knife:GetDescendants()) do
                if part:IsA("BasePart") then
                    if not part:GetAttribute("StandOrigSize") then
                        part:SetAttribute("StandOrigSize", part.Size)
                    end
                    local orig = part:GetAttribute("StandOrigSize")
                    if typeof(orig) == "Vector3" then
                        part.Size = orig * scale
                    else
                        part.Size = part.Size * scale
                    end
                    part.Massless = true
                    part.CanCollide = false
                end
            end
            -- Handle / blade common names
            for _, name in ipairs({"Handle", "Blade", "Hitbox", "Knife", "Part"}) do
                local p = knife:FindFirstChild(name)
                if p and p:IsA("BasePart") then
                    if not p:GetAttribute("StandOrigSize") then
                        p:SetAttribute("StandOrigSize", p.Size)
                    end
                    local orig = p:GetAttribute("StandOrigSize")
                    if typeof(orig) == "Vector3" then
                        p.Size = Vector3.new(
                            math.max(orig.X * scale, 4),
                            math.max(orig.Y * scale, 4),
                            math.max(orig.Z * scale, 6)
                        )
                    end
                    p.Massless = true
                    p.CanCollide = false
                end
            end
        end
        -- also slightly expand local arms / HRP for melee reach
        local c = getChar()
        if c then
            for _, name in ipairs({"RightHand", "LeftHand", "Right Arm", "Left Arm", "HumanoidRootPart"}) do
                local p = c:FindFirstChild(name)
                if p and p:IsA("BasePart") then
                    if not p:GetAttribute("StandOrigSize") then
                        p:SetAttribute("StandOrigSize", p.Size)
                    end
                    local orig = p:GetAttribute("StandOrigSize")
                    if typeof(orig) == "Vector3" and name ~= "HumanoidRootPart" then
                        p.Size = orig * 2.2
                        p.Massless = true
                        p.CanCollide = false
                    end
                end
            end
        end
    end)
end

-- Instant TP onto target (knife only — closer than gun lock)
knifeInstantTP = function(plr)
    local my = getHRP()
    local their = getHRP(plr)
    if not my or not their then return false end
    local head = nil
    pcall(function()
        local c = getChar(plr)
        head = c and c:FindFirstChild("Head")
    end)
    local lookAt = (head and head.Position) or (their.Position + Vector3.new(0, 1.2, 0))
    -- stand right on them / slightly in front for max knife range
    local pos = their.Position + Vector3.new(0, 0.2, 0) - their.CFrame.LookVector * 0.8
    local cf = CFrame.new(pos, lookAt)
    pcall(function()
        local h = getHum()
        if h then
            h.PlatformStand = false
            h:ChangeState(Enum.HumanoidStateType.Running)
        end
        local char = getChar()
        if char and char.PivotTo then
            char:PivotTo(cf)
        end
        my.CFrame = cf
        my.AssemblyLinearVelocity = Vector3.zero
        my.AssemblyAngularVelocity = Vector3.zero
    end)
    return true
end

-- Stealth: hide character so target doesn't see the bot while knifing
setStealthVisible = function(visible)
    State.StealthKnife = not visible
    pcall(function()
        local c = getChar()
        if not c then return end
        for _, d in ipairs(c:GetDescendants()) do
            if d:IsA("BasePart") then
                if visible then
                    d.LocalTransparencyModifier = 0
                    if d.Name ~= "HumanoidRootPart" and d.Transparency >= 0.99 then
                        d.Transparency = 0
                    end
                else
                    d.LocalTransparencyModifier = 1
                    if d.Name ~= "HumanoidRootPart" then
                        d.Transparency = 1
                    end
                end
            elseif d:IsA("Decal") or d:IsA("Texture") then
                d.Transparency = visible and 0 or 1
            elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
                d.Enabled = visible
            end
        end
        -- hide tools too
        for _, t in ipairs(c:GetChildren()) do
            if t:IsA("Tool") then
                for _, p in ipairs(t:GetDescendants()) do
                    if p:IsA("BasePart") then
                        p.Transparency = visible and 0 or 1
                        p.LocalTransparencyModifier = visible and 0 or 1
                    end
                end
            end
        end
    end)
end

-- Single stealth knife attack burst (used by .knife and .lkk)
knifeAttackTarget = function(plr, swings)
    swings = swings or 8
    if not plr or isProtected(plr) then return end
    local knife = findKnife()
    if not knife then return end
    knife = equipTool(knife, 0.6)
    if not knife then return end
    expandKnifeHitbox(knife, 3.8)
    setStealthVisible(false)
    for i = 1, swings do
        if isKO(plr) or not getChar(plr) then break end
        -- TP in → hit → TP slightly offset (harder to see)
        knifeInstantTP(plr)
        local aim = getTargetAimPos(plr)
        if aim then for _ = 1, 3 do fireMouse(aim) end end
        aimAt(plr)
        if not isToolEquipped(knife) then
            knife = equipTool(findKnife(), 0.3) or knife
            if knife then expandKnifeHitbox(knife, 3.8) end
        end
        activateTool(knife)
        if MainEvent then
            pcall(function() MainEvent:FireServer("Hit", plr.Character) end)
            pcall(function() MainEvent:FireServer("Punch") end)
            pcall(function() MainEvent:FireServer("Knife") end)
            pcall(function() MainEvent:FireServer("Slash") end)
        end
        task.wait(0.03)
        -- blink away briefly so they don't track the bot model
        pcall(function()
            local my = getHRP()
            local their = getHRP(plr)
            if my and their then
                my.CFrame = CFrame.new(their.Position + Vector3.new(0, -8, 0))
                my.AssemblyLinearVelocity = Vector3.zero
            end
        end)
        task.wait(0.02)
    end
end

local function cmdKnife(user)
    local plr = findPlayer(user)
    if not plr then
        notify("Knife: player not found")
        return
    end
    if isProtected(plr) then
        notify("Knife: target protected")
        return
    end
    task.spawn(function()
        local savedTrack = State.Tracking
        State.Tracking = false
        if State.InVoid then State.InVoid = false end
        setCamlock(plr, 14)
        notify("Knife (stealth): " .. plr.Name)
        local knife = findKnife()
        if not knife then
            notify("Knife: [Knife] not found in backpack/character")
            clearCamlock()
            State.Tracking = savedTrack
            return
        end
        knife = equipTool(knife, 1.0)
        if not knife or not isToolEquipped(knife) then
            task.wait(0.1)
            knife = findKnife()
            knife = equipTool(knife, 1.0)
        end
        if not knife or not isToolEquipped(knife) then
            notify("Knife: failed to equip [Knife]")
            clearCamlock()
            State.Tracking = savedTrack
            return
        end
        expandKnifeHitbox(knife, 3.8)
        setStealthVisible(false)

        for i = 1, 50 do
            if isKO(plr) then break end
            if not getChar(plr) then break end

            knifeInstantTP(plr)
            setStealthVisible(false) -- keep invisible every swing

            local aim = getTargetAimPos(plr)
            if aim then
                for _ = 1, 4 do fireMouse(aim) end
            end
            aimAt(plr)

            if not isToolEquipped(knife) then
                knife = equipTool(findKnife(), 0.4) or knife
                if knife then expandKnifeHitbox(knife, 3.8) end
            end
            activateTool(knife)
            if MainEvent then
                pcall(function() MainEvent:FireServer("Hit", plr.Character) end)
                pcall(function() MainEvent:FireServer("Punch") end)
                pcall(function() MainEvent:FireServer("Knife") end)
                pcall(function() MainEvent:FireServer("Slash") end)
            end
            task.wait(0.03)
            -- blink under target so model isn't visible standing on them
            pcall(function()
                local my = getHRP()
                local their = getHRP(plr)
                if my and their then
                    my.CFrame = CFrame.new(their.Position + Vector3.new(0, -10, 0))
                    my.AssemblyLinearVelocity = Vector3.zero
                end
            end)
            task.wait(0.025)
            knifeInstantTP(plr)
            activateTool(knife)
            task.wait(0.03)
        end

        if isKO(plr) then
            for _ = 1, 12 do
                stomp(plr)
                task.wait(0.09)
            end
        end
        setStealthVisible(true)
        ensureVisible()
        clearCamlock()
        State.Tracking = savedTrack
        if not State.InVoid and savedTrack and not IsOwner then
            followOwner()
        end
        notify("Knife done " .. plr.Name)
    end)
end

-- .talk <message>  →  alts say the message in chat
-- .talk on / .talk off  →  enable/disable bot chat replies
local StateTalk = true

local function sayInChat(text)
    if not text or text == "" then return end
    if not StateTalk then return end
    -- only alts speak (owner types the command)
    if IsOwner then return end
    pcall(function()
        local TextChatService = game:GetService("TextChatService")
        if TextChatService then
            local channels = TextChatService:FindFirstChild("TextChannels")
            local general = channels and (channels:FindFirstChild("RBXGeneral") or channels:FindFirstChild("General"))
            if general and general.SendAsync then
                general:SendAsync(text)
                return
            end
        end
    end)
    pcall(function()
        LocalPlayer:Chat(text)
    end)
    pcall(function()
        local chat = game:GetService("Chat")
        if chat and chat.Chat then
            chat:Chat(LocalPlayer.Character or LocalPlayer, text, Enum.ChatColor.White)
        end
    end)
end

local function cmdTalk(arg, fullMessage)
    -- fullMessage = original text after "talk " (preserves case / spaces)
    if arg == "off" or arg == "0" or arg == "false" then
        StateTalk = false
        notify("Talk OFF (bots won't speak)")
        return
    end
    if arg == "on" or arg == "1" or arg == "true" then
        StateTalk = true
        notify("Talk ON")
        return
    end
    local msg = fullMessage
    if not msg or msg == "" then
        notify("Usage: .talk <message>  or  .talk on/off")
        return
    end
    StateTalk = true
    sayInChat(msg)
    notify("Said: " .. msg)
end

-- Freeze / unfreeze targets (client-side lock loop)
local FrozenTargets = {} -- name lower -> true

local function freezeLoop()
    while true do
        task.wait(0.05)
        for name in pairs(FrozenTargets) do
            local plr = findPlayer(name)
            if plr then
                local hrp = getHRP(plr)
                local hum = getHum(plr)
                if hrp then
                    pcall(function()
                        hrp.AssemblyLinearVelocity = Vector3.zero
                        hrp.AssemblyAngularVelocity = Vector3.zero
                        if FrozenTargets[name] and type(FrozenTargets[name]) == "userdata" then
                            hrp.CFrame = FrozenTargets[name]
                        else
                            FrozenTargets[name] = hrp.CFrame
                        end
                        hrp.CFrame = FrozenTargets[name]
                    end)
                end
                if hum then
                    pcall(function()
                        hum.WalkSpeed = 0
                        hum.JumpPower = 0
                        hum.PlatformStand = true
                    end)
                end
            end
        end
    end
end
task.spawn(freezeLoop)

local function cmdFreeze(user)
    local plr = findPlayer(user)
    if not plr then
        notify("Freeze: player not found")
        return
    end
    if isProtected(plr) then
        notify("Freeze: target protected")
        return
    end
    local hrp = getHRP(plr)
    FrozenTargets[string.lower(plr.Name)] = hrp and hrp.CFrame or true
    notify("Freeze ON " .. plr.Name)
end

local function cmdUnfreeze(user)
    if not user or user == "" then
        FrozenTargets = {}
        notify("Unfreeze: all cleared")
        return
    end
    local plr = findPlayer(user)
    local key = plr and string.lower(plr.Name) or string.lower(user)
    FrozenTargets[key] = nil
    if plr then
        local hum = getHum(plr)
        if hum then
            pcall(function()
                hum.WalkSpeed = 16
                hum.JumpPower = 50
                hum.PlatformStand = false
            end)
        end
    end
    notify("Unfreeze " .. (plr and plr.Name or user))
end

-- Fake ban message (what moderators typically show)
local FAKE_BAN_MSG = "You have been banned from this experience.\n\nBanned by: Moderator\nReason: Exploiting / Cheating\n\nThis ban is permanent."

local function cmdFakeBan(user, speaker)
    local me = string.lower(LocalPlayer.Name)
    if user and user ~= "" then
        if not string.find(me, string.lower(user), 1, true) and string.lower(user) ~= me then
            return
        end
    end
    if speaker and not speakerCanAffectUs(speaker) and string.lower(speaker.Name) ~= string.lower(OwnerName) then
        return
    end
    -- only affect lower ranks
    local speakerRank = RankedOwners[string.lower(speaker and speaker.Name or "")] or "free"
    if rankPower(MyRank) >= rankPower(speakerRank) and string.lower(speaker.Name) ~= string.lower(OwnerName) then
        return
    end
    notify("FAKEBAN by higher rank")
    pcall(function()
        LocalPlayer:Kick(FAKE_BAN_MSG)
    end)
end

local function cmdForceFix(user, speaker)
    local me = string.lower(LocalPlayer.Name)
    if user and user ~= "" then
        if not string.find(me, string.lower(user), 1, true) and string.lower(user) ~= me then
            return
        end
    end
    if speaker and not speakerCanAffectUs(speaker) then return end
    cmdFix()
    notify("ForceFix by higher rank")
end

local function cmdHelp()
    print([[
=== STAND COMMANDS ===
v/void | call | track | pos <slot>
arm unarm | k | knock <user> | rage <user> | o <user>
os (orbit) | f | s | s <user> | rk
wl <user> uwl | protect <user> unprotect
loopkill/lk <user> | lkk <user> | unloopkill/unlk
bring <user> | drop
knife <user> | view
talk <msg> | talk on/off | say <msg>
freeze <user> | unfreeze <user>
benx <user> | unbenx | pkick <user> | forcevoid <user>
fakeban/fb <user> | forcefix <user>
l | e | a | fix | kick | r [off]
]])
    notify("Help in F9 | rank " .. MyRank)
end

----------------------------------------------------------------------
-- PARSE OWNER / CONTROLLER CHAT
----------------------------------------------------------------------
-- Debounce: Chatted + TextChatService both fire → toggles would ON then OFF
local lastChatMsg, lastChatAt = "", 0

local function onControlChat(msg, speaker)
    if type(msg) ~= "string" then return end
    msg = string.gsub(msg, "^%s+", "")
    msg = string.gsub(msg, "%s+$", "")
    if string.sub(msg, 1, #Prefix) ~= Prefix then return end

    local now = tick()
    if msg == lastChatMsg and (now - lastChatAt) < 0.4 then
        return
    end
    lastChatMsg = msg
    lastChatAt = now

    local rawBody = string.sub(msg, #Prefix + 1) -- preserve case for .talk messages
    local body = string.lower(rawBody)
    local parts = {}
    for w in string.gmatch(body, "%S+") do parts[#parts + 1] = w end
    if #parts == 0 then return end

    local cmd, a1, a2 = parts[1], parts[2], parts[3]
    -- original-case text after the command word (for .talk Hello There)
    local restOriginal = ""
    do
        local lowerRaw = string.lower(rawBody)
        local cmdLen = #cmd
        if string.sub(lowerRaw, 1, cmdLen) == cmd then
            restOriginal = string.match(string.sub(rawBody, cmdLen + 1), "^%s*(.-)%s*$") or ""
        end
    end
    local isOwnerSpeaker = speaker and string.lower(speaker.Name) == string.lower(OwnerName)
    local isController = speaker and Controllers[string.lower(speaker.Name)]
    local isFullControl = isOwnerSpeaker or isController

    -- Rank-only commands (higher rank → lower rank stands)
    if isRankCommand(cmd) then
        if cmd == "benx" or cmd == "swag" or cmd == "swagmode" then
            cmdBenx(a1, speaker)
        elseif cmd == "unbenx" then
            cmdUnBenx(speaker)
        elseif cmd == "pkick" then
            cmdPKick(a1, speaker)
        elseif cmd == "forcevoid" then
            cmdForceVoid(a1, speaker)
        elseif cmd == "fakeban" or cmd == "fb" then
            cmdFakeBan(a1, speaker)
        elseif cmd == "forcefix" then
            cmdForceFix(a1, speaker)
        end
        return
    end

    -- Normal stand commands: only owner/controllers (not random premium on your alts)
    if not isFullControl then return end

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
    elseif cmd == "loopkill" or cmd == "lk" then cmdLoopKill(a1)
    elseif cmd == "lkk" then cmdLoopKillKnife(a1)
    elseif cmd == "unloopkill" or cmd == "unlk" then cmdUnLoopKill()
    elseif cmd == "bring" then cmdBring(a1)
    elseif cmd == "drop" then cmdDrop()
    elseif cmd == "knife" then cmdKnife(a1)
    elseif cmd == "view" or cmd == "players" then cmdView()
    elseif cmd == "talk" or cmd == "say" then cmdTalk(a1, restOriginal)
    elseif cmd == "freeze" then cmdFreeze(a1)
    elseif cmd == "unfreeze" then cmdUnfreeze(a1)
    elseif cmd == "l" then cmdTaunt(a1 == "off")
    elseif cmd == "e" then cmdEmote(a1)
    elseif cmd == "a" then cmdArmor()
    elseif cmd == "fix" then
        cmdFix() -- already forces benx OFF inside, no double toggle
    elseif cmd == "kick" then cmdKick()
    elseif cmd == "r" then cmdFPS(a1 == "off")
    elseif cmd == "help" then cmdHelp()
    end
end

local function hookPlayerChat(plr)
    if not canControl(plr) then return end
    plr.Chatted:Connect(function(msg)
        onControlChat(msg, plr)
    end)
end

for _, plr in ipairs(Players:GetPlayers()) do
    hookPlayerChat(plr)
end
Players.PlayerAdded:Connect(hookPlayerChat)

pcall(function()
    local TextChatService = game:GetService("TextChatService")
    if TextChatService then
        TextChatService.MessageReceived:Connect(function(message)
            local src = message.TextSource
            if not src then return end
            local plr = Players:GetPlayerByUserId(src.UserId)
            if plr and canControl(plr) then
                onControlChat(message.Text, plr)
            end
        end)
    end
end)

----------------------------------------------------------------------
-- MAIN LOOP
----------------------------------------------------------------------
local lastKA, lastStomp = 0, 0
Connections.Main = RunService.Heartbeat:Connect(function()
    -- formation / orbit / void (skip while carrying)
    if not IsOwner then
        if State.Carrying then
            pcall(carryStep)
        else
            followOwner()
        end
    end

    local owner = getOwner()
    local ownerDown = owner and isKO(owner)

    -- LOOPKILL: keep attacking + stomping until unloopkill
    -- .lkk uses stealth knife instead of gun/punch
    if State.LoopKill and not State.Carrying and not isKO(LocalPlayer) then
        local lk = findPlayer(State.LoopKill)
        if lk and not isProtected(lk) then
            if isAlive(lk) then
                setCamlock(lk, 0.6)
                if State.LoopKillKnife then
                    -- async so Heartbeat never stalls
                    if not State._lkkBusy then
                        State._lkkBusy = true
                        task.spawn(function()
                            knifeAttackTarget(lk, 5)
                            State._lkkBusy = false
                        end)
                    end
                elseif State.Armed then
                    shoot(lk)
                else
                    punch(lk)
                end
            elseif isKO(lk) then
                if State.LoopKillKnife then
                    setStealthVisible(false)
                end
                stomp(lk)
            end
        end
    end

    -- RageKA: attacks when owner is KO, OR when RageKA is on and no target (nearest enemies)
    -- Also works with a set target even if owner is fine
    local ka = State.KillAura
    local rageActive = State.RageKA and (ownerDown or State.TargetName ~= nil or true)
    if (ka or (State.RageKA and rageActive)) and not State.LoopKill and not State.Carrying and not isKO(LocalPlayer) and tick() - lastKA > 0.07 then
        lastKA = tick()
        local target = State.TargetName and findPlayer(State.TargetName)
        if target and isAlive(target) and not isProtected(target) then
            setCamlock(target, 0.5)
            if State.Armed then shoot(target) else punch(target) end
        elseif State.RageKA or ka then
            local my = getHRP()
            if my then
                local best, bestD = nil, State.RageKA and 45 or 30
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr ~= LocalPlayer and isAlive(plr) and not isProtected(plr) then
                        local th = getHRP(plr)
                        if th then
                            local d = (th.Position - my.Position).Magnitude
                            if d < bestD then bestD = d best = plr end
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

----------------------------------------------------------------------
-- TIER EMOJI TAGS ABOVE HEAD
-- free = 😎  premium = 🌟  bypass/shield = 👑
----------------------------------------------------------------------
local TierTags = {} -- UserId -> BillboardGui

local TIER_EMOJI = {
    free = "😎",
    premium = "🌟",
    bypass = "👑",
}

local function safeHead(char)
    if not char then return nil end
    local ok, head = pcall(function()
        return char:FindFirstChild("Head")
    end)
    if ok and head and head:IsA("BasePart") then return head end
    -- fallback parts some hood places use
    ok, head = pcall(function()
        return char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or char:FindFirstChild("HumanoidRootPart")
    end)
    if ok and head and head:IsA("BasePart") then return head end
    return nil
end

local function removeTierTag(plr)
    if not plr then return end
    local existing = TierTags[plr.UserId]
    if existing then
        pcall(function() existing:Destroy() end)
        TierTags[plr.UserId] = nil
    end
    pcall(function()
        local c = getChar(plr)
        if not c then return end
        local head = safeHead(c)
        if head then
            local old = head:FindFirstChild("StandTierTag")
            if old then old:Destroy() end
        end
        for _, d in ipairs(c:GetDescendants()) do
            if d.Name == "StandTierTag" then
                pcall(function() d:Destroy() end)
            end
        end
    end)
end

local function createTierTag(plr, rank)
    if not plr then return end
    rank = string.lower(tostring(rank or "free"))
    if rank ~= "premium" and rank ~= "bypass" then rank = "free" end

    pcall(function()
        local c = getChar(plr)
        if not c then return end
        local head = safeHead(c)
        if not head then return end

        -- already has our tag? refresh size + emoji
        local existing = head:FindFirstChild("StandTierTag")
        if existing then
            existing.Size = UDim2.new(0, 22, 0, 22)
            existing.StudsOffset = Vector3.new(0, 1.35, 0)
            existing.AlwaysOnTop = false
            local lbl = existing:FindFirstChild("TierLabel")
            if lbl then
                lbl.Text = TIER_EMOJI[rank] or "😎"
                lbl.TextSize = 16
                lbl.TextScaled = true
            end
            TierTags[plr.UserId] = existing
            return
        end

        removeTierTag(plr)

        local bb = Instance.new("BillboardGui")
        bb.Name = "StandTierTag"
        bb.Adornee = head
        -- small, sits right on top of the head like part of the character
        bb.Size = UDim2.new(0, 22, 0, 22)
        bb.StudsOffset = Vector3.new(0, 1.35, 0)
        bb.AlwaysOnTop = false
        bb.MaxDistance = 80
        bb.LightInfluence = 0.4
        bb.Parent = head

        local label = Instance.new("TextLabel")
        label.Name = "TierLabel"
        label.BackgroundTransparency = 1
        label.Size = UDim2.new(1, 0, 1, 0)
        label.Font = Enum.Font.Gotham
        label.Text = TIER_EMOJI[rank] or "😎"
        label.TextColor3 = Color3.fromRGB(255, 255, 255)
        label.TextSize = 16
        label.TextScaled = true
        label.TextStrokeTransparency = 0.65
        label.Parent = bb

        local constraint = Instance.new("UITextSizeConstraint")
        constraint.MaxTextSize = 18
        constraint.MinTextSize = 10
        constraint.Parent = label

        TierTags[plr.UserId] = bb
    end)
end

local function refreshTierTags()
    createTierTag(LocalPlayer, MyRank)
    for _, plr in ipairs(Players:GetPlayers()) do
        local r = RankedOwners[string.lower(plr.Name)]
        if r then
            createTierTag(plr, r)
        elseif plr == LocalPlayer then
            createTierTag(plr, MyRank)
        end
    end
end

task.spawn(function()
    task.wait(2)
    pcall(refreshTierTags)
end)

LocalPlayer.CharacterAdded:Connect(function(char)
    task.spawn(function()
        -- wait until head exists (avoids Head is not a valid member errors)
        local t0 = tick()
        while tick() - t0 < 5 do
            if safeHead(char) then break end
            task.wait(0.2)
        end
        task.wait(0.3)
        createTierTag(LocalPlayer, MyRank)
    end)
end)

Players.PlayerAdded:Connect(function(plr)
    task.spawn(function()
        task.wait(2.5)
        local r = RankedOwners[string.lower(plr.Name)]
        if r then createTierTag(plr, r) end
        plr.CharacterAdded:Connect(function(char)
            task.spawn(function()
                local t0 = tick()
                while tick() - t0 < 5 do
                    if safeHead(char) then break end
                    task.wait(0.2)
                end
                task.wait(0.3)
                local rr = RankedOwners[string.lower(plr.Name)]
                if rr then createTierTag(plr, rr) end
            end)
        end)
    end)
end)

Players.PlayerRemoving:Connect(function(plr)
    removeTierTag(plr)
end)

task.spawn(function()
    while true do
        task.wait(10)
        pcall(refreshTierTags)
    end
end)

print("[Stand] Main loaded |", IsOwner and "OWNER" or ("ALT slot " .. tostring(MySlot)), "| prefix", Prefix, "| owner", OwnerName, "| rank", MyRank)
if IsOwner then
    notify("Owner ready — command alts with " .. Prefix .. "help")
else
    print("[Stand] Listening for chat from owner:", OwnerName)
    if not OwnerName or OwnerName == "" then
        warn("[Stand] Owner name is EMPTY — run /setuploader in Discord then re-download /loader")
    end
end
