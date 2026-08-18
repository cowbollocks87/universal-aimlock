local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

local repo = "https://raw.githubusercontent.com/mstudio45/LinoriaLib/main/"
local Library = loadstring(game:HttpGet(repo .. "Library.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()

local Options = Library.Options
local Toggles = Library.Toggles

local Cfg = {
    AimlockEnabled = false,
    BindMode = "Hold",
    InputType = "Keyboard",
    FOV = 150,
    Smoothing = 50,
    BoneTarget = "Head",
    WallCheck = true,
    TeamCheck = true,
    FOVCircleVisible = true,
    FOVCircleColor = Color3.fromRGB(255, 255, 255),
    FOVCircleTransparency = 0.2,
    ESPEnabled = true,
    ESPMode = "Standard",
    ESPHighlights = true,
    HighlightMode = "AlwaysOnTop",
    ESPTracers = true,
    ESPNames = true,
    ESPDistance = true,
    NameType = "Display",
    ESPColor = Color3.fromRGB(255, 255, 255),
    ESPLockedColor = Color3.fromRGB(255, 80, 80),
    TracerColor = Color3.fromRGB(255, 255, 255),
    NameColor = Color3.fromRGB(255, 255, 255),
    AimFilterMode = "Blacklist",
    AimFilterList = {},
    ESPFilterMode = "Blacklist",
    ESPFilterList = {},
    AimTeamFilterMode = "Blacklist",
    AimTeamFilterList = {},
    ESPTeamFilterMode = "Blacklist",
    ESPTeamFilterList = {},
    OffsetEnabled = false,
    OffsetX = 0,
    OffsetY = 0,
    OffsetZ = 0,
    SmartEnabled = false,
    SmartMode = "Manual",
    ManualSpeed = 500,
    GravityCompensation = false,
    CalibratedSpeed = nil,
    CalibSamples = {},
}

local Unloaded = false
local LockedTarget = nil
local LockedBone = nil
local ESPObjects = {}
local Connections = {}
local CalibActive = false
local CalibNewPartConn = nil
local CalibScanConn = nil
local CalibStatusLabel = nil
local CalibTelemetry = nil
local SmartStatusLabel = nil
local LastCharParts = {}
local THROW_VELOCITY_MIN = 40
local OffsetToggleLocked = false

local LastTelemetry = {
    path = "",
    part = "",
    speed = 0,
    method = "",
    samples = 0,
    avg = 0,
}

local function getTeamColor(player)
    if player.Team then
        return player.Team.TeamColor.Color
    end
    return nil
end

local function updateTelemetryLabel()
    if not CalibTelemetry then return end
    if not CalibActive and LastTelemetry.path == "" then
        CalibTelemetry:SetText("No data yet — start calibration and fire.")
        return
    end
    local lines = {}
    table.insert(lines, CalibActive and "● LISTENING" or "◼ STOPPED")
    if LastTelemetry.path ~= "" then
        table.insert(lines, "Path: " .. LastTelemetry.path)
        table.insert(lines, "Part: " .. LastTelemetry.part)
        table.insert(lines, "Method: " .. LastTelemetry.method)
        table.insert(lines, "Speed: " .. math.round(LastTelemetry.speed) .. " st/s")
        if LastTelemetry.samples > 0 then
            table.insert(lines, "Samples: " .. LastTelemetry.samples)
            table.insert(lines, "Avg: " .. math.round(LastTelemetry.avg) .. " st/s")
        end
    end
    if LockedTarget then
        local char = LockedTarget.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then
            local v = hrp.AssemblyLinearVelocity
            table.insert(lines, string.format("TargetVel: (%.1f, %.1f, %.1f) | %.1f st/s", v.X, v.Y, v.Z, v.Magnitude))
        end
    end
    CalibTelemetry:SetText(table.concat(lines, "\n"))
end

local function recordTelemetry(path, partName, speed, method)
    LastTelemetry.path = path
    LastTelemetry.part = partName
    LastTelemetry.speed = speed
    LastTelemetry.method = method
    local count = #Cfg.CalibSamples
    LastTelemetry.samples = count
    if count > 0 then
        local sum = 0
        for _, v in ipairs(Cfg.CalibSamples) do sum = sum + v end
        LastTelemetry.avg = sum / count
    else
        LastTelemetry.avg = speed
    end
    updateTelemetryLabel()
end

local function measureSpeed(part)
    local posA = part.Position
    local t0 = tick()
    RunService.Heartbeat:Wait()
    RunService.Heartbeat:Wait()
    if not part.Parent then return nil, "" end
    local posB = part.Position
    local dt = tick() - t0
    if dt <= 0 then return nil, "" end
    local deltaVec = posB - posA
    local deltaSpeed = deltaVec.Magnitude / dt
    local alv = part.AssemblyLinearVelocity
    local alvHoriz = Vector2.new(alv.X, alv.Z).Magnitude
    if deltaSpeed >= alvHoriz then
        return deltaSpeed, "PosDelta"
    else
        return alvHoriz, "ALV"
    end
end

local function getBarrelPosition()
    local char = LocalPlayer.Character
    if not char then return nil end
    local tool = char:FindFirstChildOfClass("Tool")
    if tool then
        local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildOfClass("BasePart")
        if handle then return handle.Position end
    end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    return hrp and hrp.Position or nil
end

local function isPlayerCharPart(part)
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character and part:IsDescendantOf(player.Character) then
            return true
        end
    end
    return false
end

local function getRepresentativePart(model)
    if model.PrimaryPart then return model.PrimaryPart end
    for _, desc in ipairs(model:GetDescendants()) do
        if desc:IsA("BasePart") then return desc end
    end
    return nil
end

local function updateCalibStatus()
    if not CalibStatusLabel then return end
    local mode = Cfg.SmartMode
    if mode == "Manual" then
        CalibStatusLabel:SetText("Mode: Manual | Speed: " .. Cfg.ManualSpeed .. " st/s")
    elseif mode == "Single" then
        if Cfg.CalibratedSpeed then
            CalibStatusLabel:SetText("Calibrated: " .. math.round(Cfg.CalibratedSpeed) .. " st/s")
        else
            CalibStatusLabel:SetText(CalibActive and "Listening — throw or fire..." or "Not calibrated")
        end
    elseif mode == "Average" then
        local count = #Cfg.CalibSamples
        if count == 0 then
            CalibStatusLabel:SetText(CalibActive and "Listening — throw or fire..." or "No samples yet")
        else
            local sum = 0
            for _, v in ipairs(Cfg.CalibSamples) do sum = sum + v end
            local avg = math.round(sum / count)
            Cfg.CalibratedSpeed = avg
            CalibStatusLabel:SetText(
                "Samples: " .. count ..
                " | Avg: " .. avg .. " st/s" ..
                " | Last: " .. math.round(Cfg.CalibSamples[#Cfg.CalibSamples]) .. " st/s" ..
                (CalibActive and " | Listening..." or " | Done")
            )
        end
    end
    if SmartStatusLabel then
        if not Cfg.SmartEnabled then
            SmartStatusLabel:SetText("Smart Aimlock: OFF")
        else
            local speed = Cfg.SmartMode == "Manual" and Cfg.ManualSpeed or Cfg.CalibratedSpeed
            if speed then
                SmartStatusLabel:SetText(
                    "Smart: ON | " .. Cfg.SmartMode ..
                    " | " .. math.round(speed) .. " st/s" ..
                    (Cfg.GravityCompensation and " | Gravity ON" or " | Gravity OFF")
                )
            else
                SmartStatusLabel:SetText("Smart: ON | Not calibrated yet")
            end
        end
    end
    updateTelemetryLabel()
end

local stopCalibration

local function onProjectileDetected(speed, path, partName, method)
    if not CalibActive then return end
    if speed < THROW_VELOCITY_MIN then return end
    recordTelemetry(path, partName, speed, method)
    if Cfg.SmartMode == "Single" then
        Cfg.CalibratedSpeed = speed
        stopCalibration()
        Library:Notify(
            "Calibrated via " .. path .. " (" .. method .. ")\n" ..
            "Part: " .. partName .. "\n" ..
            "Speed: " .. math.round(speed) .. " st/s", 5
        )
    elseif Cfg.SmartMode == "Average" then
        table.insert(Cfg.CalibSamples, speed)
        updateCalibStatus()
        Library:Notify("Sample " .. #Cfg.CalibSamples .. " [" .. method .. "]: " .. math.round(speed) .. " st/s", 2)
    end
end

local function startNewPartListener()
    if CalibNewPartConn then CalibNewPartConn:Disconnect() end
    CalibNewPartConn = workspace.ChildAdded:Connect(function(child)
        if not CalibActive then return end
        local barrelPos = getBarrelPosition()
        if not barrelPos then return end
        local part, path, partLabel
        if child:IsA("BasePart") then
            if (child.Position - barrelPos).Magnitude > 25 then return end
            if isPlayerCharPart(child) then return end
            part = child
            path = "PATH1-New"
            partLabel = child.Name
        elseif child:IsA("Model") then
            if (child:GetPivot().Position - barrelPos).Magnitude > 25 then return end
            local p = getRepresentativePart(child)
            if not p then return end
            if isPlayerCharPart(p) then return end
            part = p
            path = "PATH1-Model"
            partLabel = child.Name .. "." .. p.Name
        else
            return
        end
        local speed, method = measureSpeed(part)
        if not speed then return end
        if not part.Parent then return end
        onProjectileDetected(speed, path, partLabel, method)
    end)
end

local function getLocalCharParts()
    local result = {}
    local char = LocalPlayer.Character
    if not char then return result end
    for _, desc in ipairs(char:GetDescendants()) do
        if desc:IsA("BasePart") then result[desc] = true end
    end
    return result
end

local function startCharDetachScan()
    if CalibScanConn then CalibScanConn:Disconnect() end
    LastCharParts = getLocalCharParts()
    CalibScanConn = RunService.Heartbeat:Connect(function()
        if not CalibActive then return end
        local currentCharParts = getLocalCharParts()
        for part, _ in pairs(LastCharParts) do
            if not currentCharParts[part] then
                if part.Parent and part:IsDescendantOf(workspace) then
                    task.spawn(function()
                        local speed, method = measureSpeed(part)
                        if speed and part.Parent then
                            onProjectileDetected(speed, "PATH2-Detach", part.Name, method)
                        end
                    end)
                end
            end
        end
        LastCharParts = currentCharParts
    end)
end

stopCalibration = function()
    CalibActive = false
    if CalibNewPartConn then CalibNewPartConn:Disconnect(); CalibNewPartConn = nil end
    if CalibScanConn then CalibScanConn:Disconnect(); CalibScanConn = nil end
    LastCharParts = {}
    updateCalibStatus()
    updateTelemetryLabel()
end

local function startCalibration()
    CalibActive = true
    LastCharParts = getLocalCharParts()
    startNewPartListener()
    startCharDetachScan()
    updateCalibStatus()
    updateTelemetryLabel()
end

local function getSmartAimPosition(bonePos, targetChar)
    local speed = Cfg.SmartMode == "Manual" and Cfg.ManualSpeed or Cfg.CalibratedSpeed
    if not speed or speed <= 0 then return bonePos end
    local hrp = targetChar:FindFirstChild("HumanoidRootPart")
    if not hrp then return bonePos end
    local targetVel = hrp.AssemblyLinearVelocity
    local dist = (hrp.Position - Camera.CFrame.Position).Magnitude
    local travelTime = dist / speed
    local leadPos = bonePos + targetVel * travelTime
    if Cfg.GravityCompensation then
        leadPos = leadPos + Vector3.new(0, 0.5 * workspace.Gravity * travelTime * travelTime, 0)
    end
    return leadPos
end

local function applyOffset(bonePos, targetChar)
    if not Cfg.OffsetEnabled then return bonePos end
    if Cfg.OffsetX == 0 and Cfg.OffsetY == 0 and Cfg.OffsetZ == 0 then return bonePos end
    local hrp = targetChar:FindFirstChild("HumanoidRootPart")
    if not hrp then return bonePos end
    return bonePos
        + hrp.CFrame.RightVector * Cfg.OffsetX
        + Vector3.new(0, 1, 0) * Cfg.OffsetY
        + hrp.CFrame.LookVector * Cfg.OffsetZ
end

local function getAimPosition(bonePos, targetChar)
    if Cfg.SmartEnabled then
        return getSmartAimPosition(bonePos, targetChar)
    else
        return applyOffset(bonePos, targetChar)
    end
end

local function resolvePlayerInput(input)
    input = input:match("^%s*(.-)%s*$"):lower()
    if input == "" then return "none", nil end
    local matches = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        if player.Name:lower():find(input, 1, true) or player.DisplayName:lower():find(input, 1, true) then
            if player.Name:lower() == input then return "ok", player end
            table.insert(matches, player)
        end
    end
    if #matches == 0 then return "none", nil end
    if #matches == 1 then return "ok", matches[1] end
    return "ambiguous", matches
end

local function resolveTeamInput(input)
    input = input:match("^%s*(.-)%s*$"):lower()
    if input == "" then return "none", nil end
    local teams = game:GetService("Teams")
    local matches = {}
    for _, team in ipairs(teams:GetTeams()) do
        local name = team.Name:lower()
        if name:find(input, 1, true) then
            if name == input then return "ok", team.Name end
            table.insert(matches, team.Name)
        end
    end
    if #matches == 0 then return "none", nil end
    if #matches == 1 then return "ok", matches[1] end
    return "ambiguous", matches
end

local function inList(list, value)
    for _, n in ipairs(list) do if n == value then return true end end
    return false
end

local function addToList(list, value)
    if not inList(list, value) then table.insert(list, value); return true end
    return false
end

local function removeFromList(list, value)
    for i, n in ipairs(list) do
        if n == value then table.remove(list, i); return true end
    end
    return false
end

local function passesAimFilter(player)
    local inL = inList(Cfg.AimFilterList, player.Name)
    return Cfg.AimFilterMode == "Blacklist" and not inL or Cfg.AimFilterMode == "Whitelist" and inL
end

local function passesESPFilter(player)
    local inL = inList(Cfg.ESPFilterList, player.Name)
    return Cfg.ESPFilterMode == "Blacklist" and not inL or Cfg.ESPFilterMode == "Whitelist" and inL
end

local function passesAimTeamFilter(player)
    if not player.Team then return Cfg.AimTeamFilterMode == "Blacklist" end
    local inL = inList(Cfg.AimTeamFilterList, player.Team.Name)
    return Cfg.AimTeamFilterMode == "Blacklist" and not inL or Cfg.AimTeamFilterMode == "Whitelist" and inL
end

local function passesESPTeamFilter(player)
    if not player.Team then return Cfg.ESPTeamFilterMode == "Blacklist" end
    local inL = inList(Cfg.ESPTeamFilterList, player.Team.Name)
    return Cfg.ESPTeamFilterMode == "Blacklist" and not inL or Cfg.ESPTeamFilterMode == "Whitelist" and inL
end

local AimFilterLabel = nil
local ESPFilterLabel = nil
local AimTeamFilterLabel = nil
local ESPTeamFilterLabel = nil

local function refreshAimFilterDisplay()
    if not AimFilterLabel then return end
    AimFilterLabel:SetText(#Cfg.AimFilterList == 0 and "(empty)" or table.concat(Cfg.AimFilterList, "\n"))
end

local function refreshESPFilterDisplay()
    if not ESPFilterLabel then return end
    ESPFilterLabel:SetText(#Cfg.ESPFilterList == 0 and "(empty)" or table.concat(Cfg.ESPFilterList, "\n"))
end

local function refreshAimTeamFilterDisplay()
    if not AimTeamFilterLabel then return end
    AimTeamFilterLabel:SetText(#Cfg.AimTeamFilterList == 0 and "(empty)" or table.concat(Cfg.AimTeamFilterList, "\n"))
end

local function refreshESPTeamFilterDisplay()
    if not ESPTeamFilterLabel then return end
    ESPTeamFilterLabel:SetText(#Cfg.ESPTeamFilterList == 0 and "(empty)" or table.concat(Cfg.ESPTeamFilterList, "\n"))
end

local function smartAdd(input, list, refresh)
    local status, result = resolvePlayerInput(input)
    if status == "none" then
        Library:Notify("No player found: " .. input, 3)
    elseif status == "ambiguous" then
        local names = {}
        for _, p in ipairs(result) do
            table.insert(names, p.Name .. " (" .. p.DisplayName .. ")")
        end
        Library:Notify("Ambiguous:\n" .. table.concat(names, "\n"), 6)
    elseif status == "ok" then
        if addToList(list, result.Name) then
            Library:Notify("Added: " .. result.Name, 3)
            refresh()
        else
            Library:Notify(result.Name .. " already in list.", 2)
        end
    end
end

local function smartRemove(input, list, refresh)
    local status, result = resolvePlayerInput(input)
    if status == "ok" and removeFromList(list, result.Name) then
        Library:Notify("Removed: " .. result.Name, 3)
        refresh()
        return
    end
    local raw = input:match("^%s*(.-)%s*$")
    if removeFromList(list, raw) then
        Library:Notify("Removed: " .. raw, 3)
        refresh()
    else
        Library:Notify("Not in list: " .. raw, 2)
    end
end

local function smartAddTeam(input, list, refresh)
    local status, result = resolveTeamInput(input)
    if status == "none" then
        local raw = input:match("^%s*(.-)%s*$")
        if raw ~= "" then
            if addToList(list, raw) then
                Library:Notify("Added team: " .. raw, 3)
                refresh()
            else
                Library:Notify(raw .. " already in list.", 2)
            end
        else
            Library:Notify("No team found: " .. input, 3)
        end
    elseif status == "ambiguous" then
        Library:Notify("Ambiguous:\n" .. table.concat(result, "\n"), 6)
    elseif status == "ok" then
        if addToList(list, result) then
            Library:Notify("Added team: " .. result, 3)
            refresh()
        else
            Library:Notify(result .. " already in list.", 2)
        end
    end
end

local function smartRemoveTeam(input, list, refresh)
    local status, result = resolveTeamInput(input)
    if status == "ok" and removeFromList(list, result) then
        Library:Notify("Removed team: " .. result, 3)
        refresh()
        return
    end
    local raw = input:match("^%s*(.-)%s*$")
    if removeFromList(list, raw) then
        Library:Notify("Removed team: " .. raw, 3)
        refresh()
    else
        Library:Notify("Not in list: " .. raw, 2)
    end
end

local function trackConn(conn)
    table.insert(Connections, conn)
    return conn
end

local function darken(color, factor)
    factor = factor or 0.55
    return Color3.fromRGB(
        math.clamp(math.floor(color.R * 255 * factor), 0, 255),
        math.clamp(math.floor(color.G * 255 * factor), 0, 255),
        math.clamp(math.floor(color.B * 255 * factor), 0, 255)
    )
end

local function getCenter()
    return Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
end

local function screenDist(sp)
    local c = getCenter()
    return (Vector2.new(sp.X, sp.Y) - c).Magnitude
end

local function isAlive(player)
    local char = player.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    return hum ~= nil and hum.Health > 0
end

local function sameTeam(player)
    if not Cfg.TeamCheck then return false end
    return player.Team ~= nil and player.Team == LocalPlayer.Team
end

local function getTorso(char)
    return char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
end

local function resolveBone(char)
    if Cfg.BoneTarget == "Random" then
        local isR15 = char:FindFirstChild("UpperTorso") ~= nil
        local pool = isR15
            and {char:FindFirstChild("Head"), char:FindFirstChild("UpperTorso"), char:FindFirstChild("HumanoidRootPart")}
            or {char:FindFirstChild("Head"), char:FindFirstChild("Torso"), char:FindFirstChild("HumanoidRootPart")}
        local valid = {}
        for _, part in ipairs(pool) do
            if part then table.insert(valid, part) end
        end
        if #valid == 0 then return nil end
        return valid[math.random(1, #valid)]
    elseif Cfg.BoneTarget == "Torso" then
        return getTorso(char)
    else
        return char:FindFirstChild(Cfg.BoneTarget)
    end
end

local function wallCheck(targetPart)
    if not Cfg.WallCheck then return true end
    local localChar = LocalPlayer.Character
    if not localChar then return false end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {localChar}
    local result = workspace:Raycast(Camera.CFrame.Position, targetPart.Position - Camera.CFrame.Position, params)
    if not result then return true end
    return result.Instance ~= nil and result.Instance:IsDescendantOf(targetPart.Parent)
end

local function getBestTarget()
    local best, bestDist = nil, math.huge
    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        if not isAlive(player) then continue end
        if sameTeam(player) then continue end
        if not passesAimFilter(player) then continue end
        if not passesAimTeamFilter(player) then continue end
        local char = player.Character
        local checkPart = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
        if not checkPart then continue end
        local sp, onScreen = Camera:WorldToViewportPoint(checkPart.Position)
        if not onScreen then continue end
        local dist = screenDist(sp)
        if dist > Cfg.FOV then continue end
        if not wallCheck(checkPart) then continue end
        if dist < bestDist then bestDist = dist; best = player end
    end
    return best
end

local function doAimlock()
    if not LockedTarget or not LockedBone then return end
    if not isAlive(LockedTarget) then
        LockedTarget = nil; LockedBone = nil; return
    end
    if not LockedBone.Parent then
        LockedBone = resolveBone(LockedTarget.Character)
        if not LockedBone then return end
    end
    if not wallCheck(LockedBone) then return end
    local aimPos = getAimPosition(LockedBone.Position, LockedTarget.Character)
    local alpha = math.clamp(Cfg.Smoothing / 100, 0.01, 1.0)
    local mouseMag = UserInputService:GetMouseDelta().Magnitude
    local breakThreshold = Cfg.Smoothing == 100 and math.huge or 5 + (Cfg.Smoothing / 100) * 150
    if mouseMag > breakThreshold then
        alpha = alpha * math.clamp(breakThreshold / mouseMag, 0, 1)
    end
    if alpha < 0.002 then return end
    Camera.CFrame = Camera.CFrame:Lerp(CFrame.new(Camera.CFrame.Position, aimPos), alpha)
end

local function aimlockShouldFire()
    if not Cfg.AimlockEnabled then return false end
    return Options["AimlockKey"] and Options["AimlockKey"]:GetState() or false
end

local FOVCircle = Drawing.new("Circle")
FOVCircle.NumSides = 64
FOVCircle.Filled = false
FOVCircle.Thickness = 1.5
FOVCircle.Visible = false

local function updateFOVCircle()
    FOVCircle.Visible = Cfg.FOVCircleVisible
    FOVCircle.Radius = Cfg.FOV
    FOVCircle.Color = Cfg.FOVCircleColor
    FOVCircle.Transparency = Cfg.FOVCircleTransparency
    FOVCircle.Position = getCenter()
end

local function makeESP(player)
    if ESPObjects[player] then return end
    local hl = Instance.new("Highlight")
    hl.FillTransparency = 0.5
    hl.OutlineTransparency = 0
    hl.Enabled = false
    hl.Parent = gethui()
    local tracer = Drawing.new("Line")
    tracer.Thickness = 1.5
    tracer.Visible = false
    local nameText = Drawing.new("Text")
    nameText.Size = 14
    nameText.Font = Drawing.Fonts.UI
    nameText.Outline = true
    nameText.OutlineColor = Color3.fromRGB(0, 0, 0)
    nameText.Center = true
    nameText.Visible = false
    ESPObjects[player] = {highlight = hl, tracer = tracer, nameText = nameText}
end

local function removeESP(player)
    local obj = ESPObjects[player]
    if not obj then return end
    obj.highlight:Destroy()
    obj.tracer:Remove()
    obj.nameText:Remove()
    ESPObjects[player] = nil
end

local function getDisplayName(player)
    if Cfg.NameType == "Display" then return player.DisplayName
    elseif Cfg.NameType == "Username" then return player.Name
    else return player.DisplayName .. " (@" .. player.Name .. ")" end
end

local function buildNameLabel(player, distStuds)
    local label = getDisplayName(player)
    if Cfg.ESPDistance then
        label = label .. "\n" .. math.round(distStuds) .. " studs"
    end
    return label
end

local function getESPColor(player, isLocked)
    if isLocked then return Cfg.ESPLockedColor end
    if Cfg.ESPMode == "Team" then return getTeamColor(player) or Cfg.ESPColor end
    return Cfg.ESPColor
end

local function getESPTracerColor(player, isLocked)
    if isLocked then return Cfg.ESPLockedColor end
    if Cfg.ESPMode == "Team" then return getTeamColor(player) or Cfg.TracerColor end
    return Cfg.TracerColor
end

local function getESPNameColor(player, isLocked)
    if isLocked then return Cfg.ESPLockedColor end
    if Cfg.ESPMode == "Team" then return getTeamColor(player) or Cfg.NameColor end
    return Cfg.NameColor
end

local function updateESP()
    local camPos = Camera.CFrame.Position
    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local obj = ESPObjects[player]
        if not obj then continue end
        local isLocked = LockedTarget == player
        local show = Cfg.ESPEnabled and isAlive(player) and passesESPFilter(player) and passesESPTeamFilter(player)
        local fill = getESPColor(player, isLocked)

        obj.highlight.FillColor = fill
        obj.highlight.OutlineColor = darken(fill)
        obj.highlight.DepthMode = Cfg.HighlightMode == "AlwaysOnTop"
            and Enum.HighlightDepthMode.AlwaysOnTop
            or Enum.HighlightDepthMode.Occluded

        if Cfg.ESPHighlights and show then
            local char = player.Character
            if char then
                obj.highlight.Adornee = char
                obj.highlight.Enabled = true
            else
                obj.highlight.Enabled = false
            end
        else
            obj.highlight.Enabled = false
        end

        if Cfg.ESPTracers and show then
            local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                local sp, on = Camera:WorldToViewportPoint(hrp.Position)
                if on then
                    local c = getCenter()
                    obj.tracer.From = Vector2.new(c.X, Camera.ViewportSize.Y)
                    obj.tracer.To = Vector2.new(sp.X, sp.Y)
                    obj.tracer.Color = getESPTracerColor(player, isLocked)
                    obj.tracer.Visible = true
                else
                    obj.tracer.Visible = false
                end
            else
                obj.tracer.Visible = false
            end
        else
            obj.tracer.Visible = false
        end

        if (Cfg.ESPNames or Cfg.ESPDistance) and show then
            local char = player.Character
            local head = char and char:FindFirstChild("Head")
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if head and hrp then
                local sp, on = Camera:WorldToViewportPoint(head.Position + Vector3.new(0, 1.8, 0))
                if on then
                    local distStuds = (hrp.Position - camPos).Magnitude
                    obj.nameText.Text = buildNameLabel(player, distStuds)
                    obj.nameText.Color = getESPNameColor(player, isLocked)
                    obj.nameText.Position = Vector2.new(sp.X, sp.Y)
                    obj.nameText.Visible = true
                else
                    obj.nameText.Visible = false
                end
            else
                obj.nameText.Visible = false
            end
        else
            obj.nameText.Visible = false
        end
    end
end

local function onPlayerAdded(player)
    if player == LocalPlayer then return end
    makeESP(player)
    trackConn(player.CharacterAdded:Connect(function()
        task.wait(0.5)
        local obj = ESPObjects[player]
        if obj and player.Character then obj.highlight.Adornee = player.Character end
        if LockedTarget == player then LockedBone = nil end
    end))
end

for _, p in ipairs(Players:GetPlayers()) do onPlayerAdded(p) end
trackConn(Players.PlayerAdded:Connect(onPlayerAdded))
trackConn(Players.PlayerRemoving:Connect(function(player)
    if LockedTarget == player then LockedTarget = nil; LockedBone = nil end
    removeESP(player)
end))

trackConn(RunService.RenderStepped:Connect(function()
    if Unloaded then return end
    local shouldAim = aimlockShouldFire()
    if shouldAim then
        if not LockedTarget or not isAlive(LockedTarget) then
            LockedTarget = getBestTarget()
            LockedBone = LockedTarget and resolveBone(LockedTarget.Character) or nil
        end
        doAimlock()
    else
        if LockedTarget then LockedTarget = nil; LockedBone = nil end
    end
    updateESP()
    updateFOVCircle()
    if LockedTarget then updateTelemetryLabel() end
end))

Library.ShowCustomCursor = true
Library.NotifySide = "Right"

local Window = Library:CreateWindow({
    Title = "Aimlock Suite",
    Center = true,
    AutoShow = true,
    Resizable = true,
    ShowCustomCursor = true,
    UnlockMouseWhileOpen = true,
    TabPadding = 8,
    MenuFadeTime = 0.2,
})

local Tabs = {
    Aimlock = Window:AddTab("Aimlock"),
    Smart = Window:AddTab("Smart [BETA]"),
    ESP = Window:AddTab("ESP"),
    AimFilter = Window:AddTab("Aim Filter"),
    ESPFilter = Window:AddTab("ESP Filter"),
    Settings = Window:AddTab("Settings"),
}

local function addSliderWithInput(groupbox, idx, sliderOpts, onChanged)
    groupbox:AddSlider(idx, sliderOpts)
    Options[idx]:OnChanged(onChanged)
    local inputIdx = idx .. "_Input"
    groupbox:AddInput(inputIdx, {
        Text = "Value",
        Placeholder = tostring(sliderOpts.Default),
        Numeric = true,
        Finished = true,
    })
    Options[inputIdx]:OnChanged(function()
        local raw = tonumber(Options[inputIdx].Value)
        if not raw then return end
        local clamped = math.clamp(raw, sliderOpts.Min, sliderOpts.Max)
        local r = sliderOpts.Rounding or 0
        local factor = 10 ^ r
        clamped = math.floor(clamped * factor + 0.5) / factor
        Options[idx]:SetValue(clamped)
    end)
end

local AimBox = Tabs.Aimlock:AddLeftGroupbox("Aimlock")

AimBox:AddToggle("AimlockEnabled", {Text = "Enable Aimlock", Default = false})
Toggles.AimlockEnabled:OnChanged(function()
    Cfg.AimlockEnabled = Toggles.AimlockEnabled.Value
    if not Cfg.AimlockEnabled then LockedTarget = nil; LockedBone = nil end
end)

addSliderWithInput(AimBox, "FOVRadius", {
    Text = "FOV Radius", Default = 150, Min = 10, Max = 500, Rounding = 0,
}, function() Cfg.FOV = Options.FOVRadius.Value end)

addSliderWithInput(AimBox, "Smoothing", {
    Text = "Smoothing", Default = 50, Min = 1, Max = 100, Rounding = 0, Suffix = "%",
    Tooltip = "1% = floaty, breaks away easily | 100% = instant snap",
}, function() Cfg.Smoothing = Options.Smoothing.Value end)

AimBox:AddDropdown("BoneTarget", {
    Text = "Bone Target", Default = "Head",
    Values = {"Head", "Torso (Auto)", "HumanoidRootPart", "Random"},
})
Options.BoneTarget:OnChanged(function()
    local v = Options.BoneTarget.Value
    Cfg.BoneTarget = (v == "Torso (Auto)") and "Torso" or v
    LockedBone = nil
end)

AimBox:AddToggle("WallCheck", {Text = "Wall Check", Default = true})
Toggles.WallCheck:OnChanged(function() Cfg.WallCheck = Toggles.WallCheck.Value end)

AimBox:AddToggle("TeamCheck", {Text = "Team Check", Default = true})
Toggles.TeamCheck:OnChanged(function() Cfg.TeamCheck = Toggles.TeamCheck.Value end)

local BindBox = Tabs.Aimlock:AddRightGroupbox("Keybind")

BindBox:AddDropdown("BindMode", {Text = "Bind Mode", Default = "Hold", Values = {"Hold", "Toggle"}})
Options.BindMode:OnChanged(function()
    Cfg.BindMode = Options.BindMode.Value
    if Options["AimlockKey"] then
        Options["AimlockKey"]:SetValue({Options["AimlockKey"].Value, Cfg.BindMode})
    end
    LockedTarget = nil; LockedBone = nil
end)

BindBox:AddDropdown("InputType", {
    Text = "Input Type", Default = "Keyboard", Values = {"Keyboard", "MB1", "MB2"},
    Tooltip = "Keyboard = any key | MB1 = left mouse | MB2 = right mouse",
})
Options.InputType:OnChanged(function()
    Cfg.InputType = Options.InputType.Value
    local keyStr = Cfg.InputType == "MB1" and "MB1"
        or Cfg.InputType == "MB2" and "MB2"
        or (Options["AimlockKey"] and Options["AimlockKey"].Value or "Q")
    if Options["AimlockKey"] then
        Options["AimlockKey"]:SetValue({keyStr, Cfg.BindMode})
    end
end)

BindBox:AddLabel("Aimlock Key"):AddKeyPicker("AimlockKey", {
    Default = "Q", Mode = "Hold", Text = "Aimlock", NoUI = false, SyncToggleState = false,
})

local FOVBox = Tabs.Aimlock:AddRightGroupbox("FOV Circle")

FOVBox:AddToggle("FOVCircleVisible", {Text = "Show FOV Circle", Default = true})
Toggles.FOVCircleVisible:OnChanged(function() Cfg.FOVCircleVisible = Toggles.FOVCircleVisible.Value end)

addSliderWithInput(FOVBox, "FOVCircleTransparency", {
    Text = "Transparency", Default = 20, Min = 0, Max = 100, Rounding = 0, Suffix = "%",
}, function() Cfg.FOVCircleTransparency = Options.FOVCircleTransparency.Value / 100 end)

FOVBox:AddLabel("Circle Color"):AddColorPicker("FOVCircleColor", {
    Default = Cfg.FOVCircleColor, Title = "FOV Circle Color",
})
Options.FOVCircleColor:OnChanged(function() Cfg.FOVCircleColor = Options.FOVCircleColor.Value end)

local SmartBox = Tabs.Smart:AddLeftGroupbox("Smart Aimlock")

SmartStatusLabel = SmartBox:AddLabel("Smart Aimlock: OFF", true)

SmartBox:AddToggle("SmartEnabled", {
    Text = "Enable Smart Aimlock", Default = false,
    Tooltip = "Leads moving targets. Use Gravity Compensation only for pure physics projectiles.",
})
Toggles.SmartEnabled:OnChanged(function()
    Cfg.SmartEnabled = Toggles.SmartEnabled.Value
    if Cfg.SmartEnabled and Cfg.OffsetEnabled then
        OffsetToggleLocked = true
        Cfg.OffsetEnabled = false
        Toggles.OffsetEnabled:SetValue(false)
        OffsetToggleLocked = false
    end
    updateCalibStatus()
end)

SmartBox:AddToggle("GravityCompensation", {
    Text = "Gravity Compensation", Default = false,
    Tooltip = "ON = pure physics projectiles (cannonballs, real arrows)\nOFF = CFrame-driven (knives, spears the game steers itself)",
})
Toggles.GravityCompensation:OnChanged(function()
    Cfg.GravityCompensation = Toggles.GravityCompensation.Value
    updateCalibStatus()
end)

SmartBox:AddDropdown("SmartMode", {
    Text = "Calibration Mode", Default = "Manual",
    Values = {"Manual", "Single", "Average"},
    Tooltip = "Manual = speed slider | Single = one throw | Average = multiple throws",
})
Options.SmartMode:OnChanged(function()
    Cfg.SmartMode = Options.SmartMode.Value
    stopCalibration()
    updateCalibStatus()
end)

addSliderWithInput(SmartBox, "ManualSpeed", {
    Text = "Projectile Speed", Default = 500, Min = 50, Max = 5000, Rounding = 0, Suffix = " st/s",
    Tooltip = "Manual mode only. Arrows/spears: 100–400 | Bullets: 1000–3000",
}, function()
    Cfg.ManualSpeed = Options.ManualSpeed.Value
    updateCalibStatus()
end)

SmartBox:AddDivider()

SmartBox:AddButton({
    Text = "Start Calibration",
    Tooltip = "Detects new parts AND CFrame-driven parts. Full 3D speed measurement.",
    Func = function()
        if Cfg.SmartMode == "Manual" then
            Library:Notify("Switch to Single or Average mode to calibrate.", 3)
            return
        end
        if Cfg.SmartMode == "Average" then Cfg.CalibSamples = {} end
        startCalibration()
        Library:Notify("Calibration active — throw or fire your weapon.", 3)
    end,
})

SmartBox:AddButton({
    Text = "Stop / Finalize",
    Tooltip = "Lock in the calibrated speed",
    Func = function()
        stopCalibration()
        Library:Notify("Calibration finalized.", 2)
    end,
})

SmartBox:AddButton({
    Text = "Reset Calibration",
    Func = function()
        Cfg.CalibratedSpeed = nil
        Cfg.CalibSamples = {}
        LastTelemetry.path = ""
        LastTelemetry.part = ""
        LastTelemetry.speed = 0
        LastTelemetry.method = ""
        LastTelemetry.samples = 0
        LastTelemetry.avg = 0
        stopCalibration()
        Library:Notify("Calibration reset.", 2)
    end,
})

CalibStatusLabel = SmartBox:AddLabel("Mode: Manual | Speed: 500 st/s", true)

local TelemetryBox = Tabs.Smart:AddLeftGroupbox("Live Telemetry")
CalibTelemetry = TelemetryBox:AddLabel("No data yet — start calibration and fire.", true)

local OffsetBox = Tabs.Smart:AddRightGroupbox("Aimlock Offset")

OffsetBox:AddToggle("OffsetEnabled", {
    Text = "Enable Offset", Default = false,
    Tooltip = "Disabled automatically when Smart Aimlock is on",
})
Toggles.OffsetEnabled:OnChanged(function()
    if OffsetToggleLocked then return end
    if Toggles.SmartEnabled.Value then
        OffsetToggleLocked = true
        Toggles.OffsetEnabled:SetValue(false)
        OffsetToggleLocked = false
        Library:Notify("Disable Smart Aimlock first to use Offset.", 3)
        return
    end
    Cfg.OffsetEnabled = Toggles.OffsetEnabled.Value
end)

OffsetBox:AddDivider()

addSliderWithInput(OffsetBox, "OffsetX", {
    Text = "X — Right / Left", Default = 0, Min = -75, Max = 75, Rounding = 1, Suffix = " st",
    Tooltip = "+ = target's right | – = target's left",
}, function() Cfg.OffsetX = Options.OffsetX.Value end)
OffsetBox:AddButton({Text = "Reset X", Func = function() Options.OffsetX:SetValue(0) end})

OffsetBox:AddDivider()

addSliderWithInput(OffsetBox, "OffsetY", {
    Text = "Y — Up / Down", Default = 0, Min = -75, Max = 75, Rounding = 1, Suffix = " st",
    Tooltip = "+ = up | – = down",
}, function() Cfg.OffsetY = Options.OffsetY.Value end)
OffsetBox:AddButton({Text = "Reset Y", Func = function() Options.OffsetY:SetValue(0) end})

OffsetBox:AddDivider()

addSliderWithInput(OffsetBox, "OffsetZ", {
    Text = "Z — Forward / Back", Default = 0, Min = -75, Max = 75, Rounding = 1, Suffix = " st",
    Tooltip = "+ = in front of target | – = behind target",
}, function() Cfg.OffsetZ = Options.OffsetZ.Value end)
OffsetBox:AddButton({Text = "Reset Z", Func = function() Options.OffsetZ:SetValue(0) end})

OffsetBox:AddDivider()

OffsetBox:AddButton({
    Text = "Reset All Offsets",
    Tooltip = "Resets X, Y, and Z to 0",
    Func = function()
        Options.OffsetX:SetValue(0)
        Options.OffsetY:SetValue(0)
        Options.OffsetZ:SetValue(0)
    end,
})

local ESPBox = Tabs.ESP:AddLeftGroupbox("ESP")

ESPBox:AddToggle("ESPEnabled", {Text = "Enable ESP", Default = true})
Toggles.ESPEnabled:OnChanged(function() Cfg.ESPEnabled = Toggles.ESPEnabled.Value end)

ESPBox:AddDropdown("ESPMode", {
    Text = "ESP Mode", Default = "Standard",
    Values = {"Standard", "Team"},
    Tooltip = "Standard = custom colors | Team = uses each player's team color",
})
Options.ESPMode:OnChanged(function() Cfg.ESPMode = Options.ESPMode.Value end)

ESPBox:AddToggle("ESPHighlights", {Text = "Highlights", Default = true})
Toggles.ESPHighlights:OnChanged(function() Cfg.ESPHighlights = Toggles.ESPHighlights.Value end)

ESPBox:AddDropdown("HighlightMode", {
    Text = "Highlight Mode", Default = "AlwaysOnTop", Values = {"AlwaysOnTop", "Occluded"},
})
Options.HighlightMode:OnChanged(function() Cfg.HighlightMode = Options.HighlightMode.Value end)

ESPBox:AddToggle("ESPTracers", {Text = "Tracers", Default = true})
Toggles.ESPTracers:OnChanged(function() Cfg.ESPTracers = Toggles.ESPTracers.Value end)

ESPBox:AddToggle("ESPNames", {Text = "Names", Default = true})
Toggles.ESPNames:OnChanged(function() Cfg.ESPNames = Toggles.ESPNames.Value end)

ESPBox:AddToggle("ESPDistance", {Text = "Distance", Default = true})
Toggles.ESPDistance:OnChanged(function() Cfg.ESPDistance = Toggles.ESPDistance.Value end)

ESPBox:AddDropdown("NameType", {
    Text = "Name Type", Default = "Display", Values = {"Display", "Username", "Both"},
})
Options.NameType:OnChanged(function() Cfg.NameType = Options.NameType.Value end)

local ColorBox = Tabs.ESP:AddRightGroupbox("Colors")
ColorBox:AddLabel("(Used in Standard mode)", true)

ColorBox:AddLabel("ESP Color"):AddColorPicker("ESPColor", {Default = Cfg.ESPColor, Title = "ESP Color"})
Options.ESPColor:OnChanged(function() Cfg.ESPColor = Options.ESPColor.Value end)

ColorBox:AddLabel("Locked Target"):AddColorPicker("ESPLockedColor", {Default = Cfg.ESPLockedColor, Title = "Locked Target Color"})
Options.ESPLockedColor:OnChanged(function() Cfg.ESPLockedColor = Options.ESPLockedColor.Value end)

ColorBox:AddLabel("Tracer Color"):AddColorPicker("TracerColor", {Default = Cfg.TracerColor, Title = "Tracer Color"})
Options.TracerColor:OnChanged(function() Cfg.TracerColor = Options.TracerColor.Value end)

ColorBox:AddLabel("Name Color"):AddColorPicker("NameColor", {Default = Cfg.NameColor, Title = "Name Color"})
Options.NameColor:OnChanged(function() Cfg.NameColor = Options.NameColor.Value end)

local AimFLeft = Tabs.AimFilter:AddLeftGroupbox("Aimlock Player Filter")
local AimFRight = Tabs.AimFilter:AddRightGroupbox("Aimlock Team Filter")

AimFLeft:AddDropdown("AimFilterMode", {
    Text = "Filter Mode", Default = "Blacklist", Values = {"Blacklist", "Whitelist"},
    Tooltip = "Blacklist = target everyone except list | Whitelist = only target list",
})
Options.AimFilterMode:OnChanged(function() Cfg.AimFilterMode = Options.AimFilterMode.Value end)

AimFLeft:AddDivider()

local aimFilterInput = ""
AimFLeft:AddInput("AimFilterInput", {
    Text = "Player Name", Placeholder = "Partial name or username...", Numeric = false, Finished = false,
})
Options.AimFilterInput:OnChanged(function() aimFilterInput = Options.AimFilterInput.Value end)

AimFLeft:AddButton({Text = "Add Player",
    Func = function() smartAdd(aimFilterInput, Cfg.AimFilterList, refreshAimFilterDisplay) end})
AimFLeft:AddButton({Text = "Remove Player",
    Func = function() smartRemove(aimFilterInput, Cfg.AimFilterList, refreshAimFilterDisplay) end})
AimFLeft:AddButton({Text = "Clear Player List",
    Func = function()
        table.clear(Cfg.AimFilterList)
        refreshAimFilterDisplay()
        Library:Notify("Aimlock player filter cleared.", 2)
    end})

AimFilterLabel = AimFLeft:AddLabel("(empty)", true)

AimFRight:AddDropdown("AimTeamFilterMode", {
    Text = "Team Filter Mode", Default = "Blacklist", Values = {"Blacklist", "Whitelist"},
    Tooltip = "Blacklist = target all teams except list | Whitelist = only target listed teams",
})
Options.AimTeamFilterMode:OnChanged(function() Cfg.AimTeamFilterMode = Options.AimTeamFilterMode.Value end)

AimFRight:AddDivider()

local aimTeamFilterInput = ""
AimFRight:AddInput("AimTeamFilterInput", {
    Text = "Team Name", Placeholder = "Partial team name...", Numeric = false, Finished = false,
})
Options.AimTeamFilterInput:OnChanged(function() aimTeamFilterInput = Options.AimTeamFilterInput.Value end)

AimFRight:AddButton({Text = "Add Team",
    Func = function() smartAddTeam(aimTeamFilterInput, Cfg.AimTeamFilterList, refreshAimTeamFilterDisplay) end})
AimFRight:AddButton({Text = "Remove Team",
    Func = function() smartRemoveTeam(aimTeamFilterInput, Cfg.AimTeamFilterList, refreshAimTeamFilterDisplay) end})
AimFRight:AddButton({Text = "Clear Team List",
    Func = function()
        table.clear(Cfg.AimTeamFilterList)
        refreshAimTeamFilterDisplay()
        Library:Notify("Aimlock team filter cleared.", 2)
    end})

AimTeamFilterLabel = AimFRight:AddLabel("(empty)", true)

local ESPFLeft = Tabs.ESPFilter:AddLeftGroupbox("ESP Player Filter")
local ESPFRight = Tabs.ESPFilter:AddRightGroupbox("ESP Team Filter")

ESPFLeft:AddDropdown("ESPFilterMode", {
    Text = "Filter Mode", Default = "Blacklist", Values = {"Blacklist", "Whitelist"},
    Tooltip = "Blacklist = show everyone except list | Whitelist = only show list",
})
Options.ESPFilterMode:OnChanged(function() Cfg.ESPFilterMode = Options.ESPFilterMode.Value end)

ESPFLeft:AddDivider()

local espFilterInput = ""
ESPFLeft:AddInput("ESPFilterInput", {
    Text = "Player Name", Placeholder = "Partial name or username...", Numeric = false, Finished = false,
})
Options.ESPFilterInput:OnChanged(function() espFilterInput = Options.ESPFilterInput.Value end)

ESPFLeft:AddButton({Text = "Add Player",
    Func = function() smartAdd(espFilterInput, Cfg.ESPFilterList, refreshESPFilterDisplay) end})
ESPFLeft:AddButton({Text = "Remove Player",
    Func = function() smartRemove(espFilterInput, Cfg.ESPFilterList, refreshESPFilterDisplay) end})
ESPFLeft:AddButton({Text = "Clear Player List",
    Func = function()
        table.clear(Cfg.ESPFilterList)
        refreshESPFilterDisplay()
        Library:Notify("ESP player filter cleared.", 2)
    end})

ESPFilterLabel = ESPFLeft:AddLabel("(empty)", true)

ESPFRight:AddDropdown("ESPTeamFilterMode", {
    Text = "Team Filter Mode", Default = "Blacklist", Values = {"Blacklist", "Whitelist"},
    Tooltip = "Blacklist = show all teams except list | Whitelist = only show listed teams",
})
Options.ESPTeamFilterMode:OnChanged(function() Cfg.ESPTeamFilterMode = Options.ESPTeamFilterMode.Value end)

ESPFRight:AddDivider()

local espTeamFilterInput = ""
ESPFRight:AddInput("ESPTeamFilterInput", {
    Text = "Team Name", Placeholder = "Partial team name...", Numeric = false, Finished = false,
})
Options.ESPTeamFilterInput:OnChanged(function() espTeamFilterInput = Options.ESPTeamFilterInput.Value end)

ESPFRight:AddButton({Text = "Add Team",
    Func = function() smartAddTeam(espTeamFilterInput, Cfg.ESPTeamFilterList, refreshESPTeamFilterDisplay) end})
ESPFRight:AddButton({Text = "Remove Team",
    Func = function() smartRemoveTeam(espTeamFilterInput, Cfg.ESPTeamFilterList, refreshESPTeamFilterDisplay) end})
ESPFRight:AddButton({Text = "Clear Team List",
    Func = function()
        table.clear(Cfg.ESPTeamFilterList)
        refreshESPTeamFilterDisplay()
        Library:Notify("ESP team filter cleared.", 2)
    end})

ESPTeamFilterLabel = ESPFRight:AddLabel("(empty)", true)

local MenuGroup = Tabs.Settings:AddLeftGroupbox("Menu")

MenuGroup:AddLabel("Menu Key"):AddKeyPicker("MenuKeybind", {
    Default = "RightShift", NoUI = true, Text = "Toggle Menu",
})
Library.ToggleKeybind = Options.MenuKeybind

MenuGroup:AddToggle("ShowCursor", {Text = "Custom Cursor", Default = true})
Toggles.ShowCursor:OnChanged(function() Library.ShowCustomCursor = Toggles.ShowCursor.Value end)

MenuGroup:AddDivider()

MenuGroup:AddButton({
    Text = "Unload Script",
    Func = function() Library:Unload() end,
    Tooltip = "Removes all ESP, drawing objects, and disconnects everything.",
})

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({"MenuKeybind"})
ThemeManager:SetFolder("AimlockSuite")
SaveManager:SetFolder("AimlockSuite/configs")
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings)

SaveManager:LoadAutoloadConfig()

Library:OnUnload(function()
    Unloaded = true
    LockedTarget = nil; LockedBone = nil
    stopCalibration()
    for _, conn in ipairs(Connections) do conn:Disconnect() end
    table.clear(Connections)
    for player, _ in pairs(ESPObjects) do removeESP(player) end
    FOVCircle:Remove()
    Library.Unloaded = true
end)

updateCalibStatus()
updateTelemetryLabel()
Library:Notify("Aimlock Suite ready.", 4)
