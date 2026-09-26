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
    BodyShield = false, -- now ORBIT around owner (not sticky)
    RageKA = false,
    Taunt = false,
    TargetName = nil,
    ProtectName = nil,
    FPSBoost = false,
    Armed = false,
    Camlock = false,
    LoopKill = nil, -- player name string, or nil
    Carrying = nil, -- player name being carried to owner
}

local Whitelist = {} -- UserId -> true (don't attack)
local Connections = {}
local SavedCF = nil
local VoidCF = CFrame.new(0, -480, 0)
local CamTarget = nil
local CamlockUntil = 0
local OrbitAngle = 0

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
    return Controllers[n] == true
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
        return hrp and hrp.Position or nil
    end
    local ok, aim = pcall(function()
        local p = part.Position
        local their = getHRP(plr)
        if their then
            local vel = their.AssemblyLinearVelocity or Vector3.zero
            p = p + Vector3.new(vel.X, math.clamp(vel.Y, -15, 15) * 0.25, vel.Z) * 0.18
        end
        return p
    end)
    return ok and aim or nil
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

    local head = nil
    pcall(function()
        local c = getChar(plr)
        head = c and c:FindFirstChild("Head")
    end)
    local aim
    if head then
        aim = head.Position
    else
        local hrp = getHRP(plr)
        aim = hrp and (hrp.Position + Vector3.new(0, 1.5, 0)) or nil
    end
    if not aim then return end

    local cam = Workspace.CurrentCamera
    if not cam then return end

    pcall(function()
        -- Scriptable = engine won't override our CFrame
        if cam.CameraType ~= Enum.CameraType.Scriptable then
            cam.CameraType = Enum.CameraType.Scriptable
        end
        -- Camera sits slightly behind local character looking AT head → crosshair center = head
        local my = getHRP()
        local camPos
        if my then
            camPos = my.Position + Vector3.new(0, 2.2, 0) - my.CFrame.LookVector * 0.5
        else
            camPos = cam.CFrame.Position
        end
        cam.CFrame = CFrame.lookAt(camPos, aim)
        cam.Focus = CFrame.new(aim)
    end)

    moveCursorToWorld(aim)
    fireMouse(aim)
    fireMouse(aim)
    fireMouse(aim)
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

-- Body position: throttle hard so server replicates (spam = invisible on main)
local lastBodyLock = 0
local BODY_LOCK_INTERVAL = 0.18

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
            elseif d:IsA("Decal") or d:IsA("Texture") then
                if d.Transparency >= 1 then d.Transparency = 0 end
            end
        end
    end)
end

local function lockOnTarget(plr, behindDist, height)
    behindDist = behindDist or 6.0
    height = height or 2.5
    local my = getHRP()
    local their = getHRP(plr)
    if not my or not their then return false end

    if State.InVoid then State.InVoid = false end

    local head = nil
    pcall(function()
        local c = getChar(plr)
        if c then head = c:FindFirstChild("Head") end
    end)
    local lookAt = (head and head.Position) or (their.Position + Vector3.new(0, 1.5, 0))

    local back = -their.CFrame.LookVector
    if back.Magnitude < 0.05 then
        local d = my.Position - their.Position
        back = (d.Magnitude > 0.1) and d.Unit or Vector3.new(0, 0, 1)
    end

    local pos = their.Position + back * behindDist + Vector3.new(0, height, 0)
    if (pos - their.Position).Magnitude < 5.5 then
        pos = their.Position + back * 6 + Vector3.new(0, 2.5, 0)
    end

    local cf = CFrame.new(pos, lookAt)
    local now = tick()
    if (now - lastBodyLock) >= BODY_LOCK_INTERVAL then
        lastBodyLock = now
        ensureVisible()
        pcall(function()
            local char = getChar()
            -- unanchor everything so physics can replicate
            if char then
                for _, p in ipairs(char:GetDescendants()) do
                    if p:IsA("BasePart") then p.Anchored = false end
                end
            end
            if char and char.PivotTo then
                char:PivotTo(cf)
            end
            my.CFrame = cf
            my.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            my.AssemblyAngularVelocity = Vector3.zero
        end)
    end
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
    if not lockOnTarget(plr, 4.5, 3.0) then return end
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
    -- sit ON TOP of KO body (upright, no flip) and stomp
    pcall(function()
        my.AssemblyLinearVelocity = Vector3.zero
        my.AssemblyAngularVelocity = Vector3.zero
        local _, yRot, _ = their.CFrame:ToEulerAnglesYXZ()
        my.CFrame = CFrame.new(their.Position + Vector3.new(0, 2.8, 0)) * CFrame.Angles(0, yRot, 0)
        my.AssemblyLinearVelocity = Vector3.zero
    end)
    task.wait(0.02)
    local tool = equipCombat()
    activateTool(tool)
    if MainEvent then
        pcall(function() MainEvent:FireServer("Stomp") end)
        pcall(function() MainEvent:FireServer("Stomp", plr.Character) end)
        pcall(function() MainEvent:FireServer("Stomp", plr) end)
    end
    -- second press for reliability
    task.wait(0.05)
    pcall(function()
        my.CFrame = CFrame.new(their.Position + Vector3.new(0, 2.6, 0))
        my.AssemblyLinearVelocity = Vector3.zero
    end)
    activateTool(tool)
    if MainEvent then
        pcall(function() MainEvent:FireServer("Stomp") end)
    end
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
    setCamlock(plr, 1.5)

    local gun = equipGun()
    if not gun then return end
    muteGunSounds()

    -- soft reload only, stay on target
    if needsReload(gun) then
        softReload(gun)
        task.wait(0.08)
        gun = equipGun()
        if not gun then return end
    end

    -- force an immediate body snap once, then throttled updates
    lastBodyLock = 0
    lockOnTarget(plr, 6.0, 2.5)
    aimAt(plr)
    task.wait(0.05)

    for i = 1, 10 do
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
        -- above + behind (~5–6 studs back, ~4 up), aim head
        lockOnTarget(plr, 5.5 + (i % 3) * 0.25, 2.3 + (i % 2) * 0.2)
        local aim = aimAt(plr)
        if aim then
            fireMouse(aim)
            fireMouse(aim)
        end
        -- only Activate the tool — do NOT FireServer("Shoot") (causes error_sum on Hood Customs)
        activateTool(gun)
        task.wait(0.04)
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
        -- pre-aim ABOVE + BEHIND, looking at head
        lockOnTarget(plr, 6.0, 2.5)
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
    State.Tracking = false
    setCamlock(plr, 0)
    notify("LoopKill ON " .. plr.Name)
end

local function cmdUnLoopKill()
    State.LoopKill = nil
    clearCamlock()
    if not IsOwner then State.Tracking = true end
    notify("LoopKill OFF")
end

local function carryStep()
    if IsOwner or not State.Carrying then return end
    local victim = findPlayer(State.Carrying)
    if not victim then
        State.Carrying = nil
        return
    end
    local vHRP = getHRP(victim)
    local my = getHRP()
    if not vHRP or not my then return end

    -- hold body in front of alt
    pcall(function()
        vHRP.CFrame = my.CFrame * CFrame.new(0, 0.5, -2.2)
        vHRP.AssemblyLinearVelocity = Vector3.zero
        vHRP.AssemblyAngularVelocity = Vector3.zero
    end)
    if MainEvent then
        pcall(function() MainEvent:FireServer("Grabbing", true) end)
        pcall(function() MainEvent:FireServer("Grabbing") end)
    end

    -- walk toward owner
    local owner = getOwner()
    local oHRP = owner and getHRP(owner)
    if oHRP then
        local dist = (oHRP.Position - my.Position).Magnitude
        if dist > 6 then
            pcall(function()
                my.CFrame = CFrame.new(my.Position:Lerp(oHRP.Position + Vector3.new(0, 0, 3), 0.35), oHRP.Position)
                my.AssemblyLinearVelocity = Vector3.zero
            end)
        else
            -- at owner — keep holding until drop
            pcall(function()
                my.CFrame = CFrame.new(oHRP.Position + oHRP.CFrame.LookVector * 3 + Vector3.new(0, 0.5, 0), oHRP.Position)
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
        setCamlock(plr, 12)
        notify("Bring: knocking " .. plr.Name)

        local useGun = false
        if PreferredGun and PreferredGun ~= "" then
            local g = equipGun()
            useGun = g ~= nil
            State.Armed = useGun
        end

        for i = 1, 50 do
            if isKO(plr) then break end
            if not getChar(plr) then break end
            if useGun then shoot(plr) else punch(plr) end
            task.wait(0.05)
        end

        if not isKO(plr) then
            -- force a few more
            for _ = 1, 15 do
                if isKO(plr) then break end
                punch(plr)
                task.wait(0.05)
            end
        end

        if isKO(plr) then
            for _ = 1, 4 do
                stomp(plr)
                task.wait(0.1)
            end
            State.Carrying = plr.Name
            State.Tracking = false
            notify("Bring: carrying " .. plr.Name .. " → owner (use drop to release)")
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
    State.InVoid = false
    State.Tracking = not IsOwner
    State.KillAura = false
    State.StompAura = false
    State.BodyShield = false
    State.RageKA = false
    State.LoopKill = nil
    State.Carrying = nil
    State.TargetName = nil
    clearCamlock()
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
    print([[
v/void | call | track | pos <slot>
arm unarm | k | knock <user> | rage <user> | o <user>
os (orbit) | f | s | s <user> | rk
wl <user> uwl | protect <user> unprotect
loopkill/lk <user> | unloopkill/unlk
bring <user> | drop
l | e | a | fix | kick | r
]])
    notify("Help in F9")
end

----------------------------------------------------------------------
-- PARSE OWNER / CONTROLLER CHAT
----------------------------------------------------------------------
-- Debounce: Chatted + TextChatService both fire → toggles would ON then OFF
local lastChatMsg, lastChatAt = "", 0

local function onControlChat(msg)
    if type(msg) ~= "string" then return end
    msg = string.gsub(msg, "^%s+", "")
    msg = string.gsub(msg, "%s+$", "")
    if string.sub(msg, 1, #Prefix) ~= Prefix then return end

    local now = tick()
    if msg == lastChatMsg and (now - lastChatAt) < 0.4 then
        return -- duplicate from dual chat hooks
    end
    lastChatMsg = msg
    lastChatAt = now

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
    elseif cmd == "loopkill" or cmd == "lk" then cmdLoopKill(a1)
    elseif cmd == "unloopkill" or cmd == "unlk" then cmdUnLoopKill()
    elseif cmd == "bring" then cmdBring(a1)
    elseif cmd == "drop" then cmdDrop()
    elseif cmd == "l" then cmdTaunt(a1 == "off")
    elseif cmd == "e" then cmdEmote(a1)
    elseif cmd == "a" then cmdArmor()
    elseif cmd == "fix" then cmdFix()
    elseif cmd == "kick" then cmdKick()
    elseif cmd == "r" then cmdFPS(a1 == "off")
    elseif cmd == "help" then cmdHelp()
    end
end

local function hookPlayerChat(plr)
    if not canControl(plr) then return end
    plr.Chatted:Connect(onControlChat)
end

for _, plr in ipairs(Players:GetPlayers()) do
    hookPlayerChat(plr)
end
Players.PlayerAdded:Connect(hookPlayerChat)

-- Prefer TextChatService when available (modern chat); still hook Chatted with debounce
pcall(function()
    local TextChatService = game:GetService("TextChatService")
    if TextChatService then
        TextChatService.MessageReceived:Connect(function(message)
            local src = message.TextSource
            if not src then return end
            local plr = Players:GetPlayerByUserId(src.UserId)
            if plr and canControl(plr) then
                onControlChat(message.Text)
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
    if State.LoopKill and not State.Carrying and not isKO(LocalPlayer) then
        local lk = findPlayer(State.LoopKill)
        if lk and not isProtected(lk) then
            if isAlive(lk) then
                setCamlock(lk, 0.6)
                if State.Armed then shoot(lk) else punch(lk) end
            elseif isKO(lk) then
                stomp(lk)
            end
        end
    end

    local ka = State.KillAura or (State.RageKA and ownerDown)
    if ka and not State.LoopKill and not State.Carrying and not isKO(LocalPlayer) and tick() - lastKA > 0.08 then
        lastKA = tick()
        local target = State.TargetName and findPlayer(State.TargetName)
        if target and isAlive(target) and not isProtected(target) then
            setCamlock(target, 0.5)
            if State.Armed then shoot(target) else punch(target) end
        else
            local my = getHRP()
            if my then
                local best, bestD = nil, 30
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

print("[Stand] Main loaded |", IsOwner and "OWNER" or ("ALT slot " .. tostring(MySlot)), "| prefix", Prefix, "| owner", OwnerName)
if IsOwner then
    notify("Owner ready — command alts with " .. Prefix .. "help")
else
    print("[Stand] Listening for chat from owner:", OwnerName)
    if not OwnerName or OwnerName == "" then
        warn("[Stand] Owner name is EMPTY — run /setuploader in Discord then re-download /loader")
    end
end
