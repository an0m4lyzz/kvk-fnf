-- [K]vk | Funky Friday V2.1 | Frame Spike Recovery
-- Cached note types, lag-aware crossing, isolated scriptable inputs.
-- This reduces script-induced stutters; it cannot prevent Roblox/device hitches.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
for _, previousName in ipairs({"KvkFunkyV21", "KvkFunkyV2", "KvkFFAutoplay"}) do
    local old = playerGui:FindFirstChild(previousName)
    if old then
        local shutdown = old:FindFirstChild("Shutdown")
        if shutdown and shutdown:IsA("BindableEvent") then
            pcall(function() shutdown:Fire() end)
        end
        old:Destroy()
    end
end

local CONFIG = {
    OffsetMs = 0,               -- positive = early, negative = late
    TapSeconds = 0.035,
    HoldPadding = 0.065,
    MinTapInterval = 0.018,
    HazardGuardMs = 105,
    SpeedDefault = 753.7,
    MaxLanes = 9,
    -- Trigger slightly before the receptor so one delayed frame is less costly.
    -- Leave OffsetMs at zero initially; its + / - UI remains available.
    EarlyLeadMs = 24,
    BaseLateMs = 48,
    MaxRecoveryLateMs = 155,
    SpikeThresholdMs = 48,
    RecoveryPaddingMs = 20,
    IdleReleaseSeconds = 12,
    PruneEverySeconds = 0.25,
    StatusEverySeconds = 0.45,
}

local NORMAL = {
    ["117288521503268"] = true,
    ["123422112508811"] = true,
    ["88056379261795"] = true,
    ["72815517484624"] = true,
}
local HAZARD = {
    ["103483801062498"] = true,
    ["88530467220950"] = true,
    ["109130876544260"] = true,
    ["120222801097284"] = true,
    ["101951481332606"] = true,
}
local SUSTAIN = "128586003623228"

local gui = Instance.new("ScreenGui")
gui.Name = "KvkFunkyV21"
gui.ResetOnSpawn = false
gui.DisplayOrder = 1002
gui.Parent = playerGui

local shutdown = Instance.new("BindableEvent")
shutdown.Name = "Shutdown"
shutdown.Parent = gui

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(340, 344)
panel.Position = UDim2.new(1, -10, 0, 70)
panel.AnchorPoint = Vector2.new(1, 0)
panel.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
panel.BorderSizePixel = 0
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 11)

local header = Instance.new("TextLabel")
header.Position = UDim2.fromOffset(10, 5)
header.Size = UDim2.new(1, -95, 0, 30)
header.BackgroundTransparency = 1
header.Font = Enum.Font.GothamBold
header.TextSize = 14
header.TextColor3 = Color3.fromRGB(235, 240, 255)
header.TextXAlignment = Enum.TextXAlignment.Left
header.Active = true
header.Text = "[K]vk | FUNKY FRIDAY V2.1"
header.Parent = panel

local function makeButton(label, x, y, w)
    local b = Instance.new("TextButton")
    b.Position = UDim2.fromOffset(x, y)
    b.Size = UDim2.fromOffset(w, 32)
    b.BackgroundColor3 = Color3.fromRGB(48, 63, 87)
    b.TextColor3 = Color3.fromRGB(245, 247, 255)
    b.TextSize = 11
    b.Font = Enum.Font.GothamBold
    b.Text = label
    b.BorderSizePixel = 0
    b.Parent = panel
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

local toggle = makeButton("AUTO: OFF", 9, 41, 102)
local sideButton = makeButton("SIDE: AUTO", 117, 41, 104)
local stopButton = makeButton("STOP", 227, 41, 104)
local minusButton = makeButton("-5 ms", 9, 80, 76)
local plusButton = makeButton("+5 ms", 91, 80, 76)
local resetButton = makeButton("OFFSET 0", 173, 80, 87)
local closeButton = makeButton("X", 266, 80, 65)

local info = Instance.new("TextLabel")
info.Position = UDim2.fromOffset(12, 119)
info.Size = UDim2.new(1, -24, 0, 119)
info.BackgroundTransparency = 1
info.Font = Enum.Font.Code
info.TextSize = 11
info.TextColor3 = Color3.fromRGB(171, 231, 196)
info.TextXAlignment = Enum.TextXAlignment.Left
info.TextYAlignment = Enum.TextYAlignment.Top
info.TextWrapped = true
info.Parent = panel

local logBox = Instance.new("TextLabel")
logBox.Position = UDim2.fromOffset(10, 238)
logBox.Size = UDim2.new(1, -20, 0, 62)
logBox.BackgroundColor3 = Color3.fromRGB(11, 15, 22)
logBox.TextColor3 = Color3.fromRGB(196, 209, 225)
logBox.Font = Enum.Font.Code
logBox.TextSize = 11
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.TextWrapped = true
logBox.Parent = panel
Instance.new("UICorner", logBox).CornerRadius = UDim.new(0, 5)

local copyButton = makeButton("COPY REPORT", 10, 306, 320)
local minimize = makeButton("MIN", 270, 5, 61)

local logs = {}
local connections = {}
local alive = true
local armed = false
local sideMode = "Auto"
local session = nil
local lastAttempt = 0
local lastStatus = 0
local minimized = false
local summary = {
    taps=0, holds=0, hazards=0, unknowns=0, guard=0, conflicts=0,
    press=0, release=0, errors=0, spikes=0, largestFrameMs=0,
    recovered=0, missedWindow=0, frames=0, classified=0,
}

local function log(message)
    message = tostring(message)
    logs[#logs + 1] = string.format("%.1f | %s", os.clock(), message)
    if #logs > 150 then table.remove(logs, 1) end
    local tail = {}
    for i = math.max(1, #logs - 2), #logs do
        tail[#tail + 1] = logs[i]
    end
    logBox.Text = table.concat(tail, "\n")
end

local function assetId(image)
    return tostring(image or ""):match("(%d+)$")
end

local function mainSprite(note)
    local fallback
    for _, child in ipairs(note:GetChildren()) do
        if child.Name == "LayeredSprite" then
            local sprite = child:FindFirstChild("1")
            if not sprite or not (sprite:IsA("ImageLabel") or sprite:IsA("ImageButton")) then
                sprite = child:FindFirstChildWhichIsA("ImageLabel", true)
            end
            if sprite then
                if math.abs(child.Size.Y.Scale - 1) < 0.025 then return sprite end
                fallback = fallback or sprite
            end
        end
    end
    return fallback
end

local function classify(note)
    local main = mainSprite(note)
    if not main then return "Unknown", 0 end
    local id = assetId(main.Image)
    if HAZARD[id] then return "Hazard", 0 end
    if not NORMAL[id] then return "Unknown", 0 end

    local sustainScale = 0
    local hasSustain = false
    for _, child in ipairs(note:GetChildren()) do
        if child.Name == "LayeredSprite" and child:IsA("GuiObject") then
            local y = child.Size.Y.Scale
            if math.abs(y - 1) > 0.025 then
                local body = child:FindFirstChild("1")
                local bodyId = body and body:IsA("ImageLabel") and assetId(body.Image)
                if bodyId == SUSTAIN then
                    hasSustain = true
                    sustainScale = math.max(sustainScale, math.abs(y))
                else
                    return "Unknown", 0
                end
            end
        end
    end
    if hasSustain then return "Hold", sustainScale end
    return "Tap", 0
end

local function objectPosition(obj)
    if obj:IsA("BasePart") then return obj.Position end
    if obj:IsA("Model") then return obj:GetPivot().Position end
    return nil
end

local function nearest(container, point)
    if not container then return nil end
    local chosen, closest
    for _, obj in ipairs(container:GetChildren()) do
        local ok, pos = pcall(objectPosition, obj)
        if ok and pos then
            local distance = (pos - point).Magnitude
            if not closest or distance < closest then
                chosen, closest = obj, distance
            end
        end
    end
    return chosen
end

local function detectSide()
    if sideMode ~= "Auto" then return sideMode end
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local map = workspace:FindFirstChild("Map")
    local stages = map and map:FindFirstChild("Stages")
    if not root or not stages then return nil end
    local stage = nearest(stages, root.Position)
    local node = nearest(stage and stage:FindFirstChild("Nodes"), root.Position)
    if not node then return nil end
    if node.Name:sub(1, 5) == "Left_" then return "Left" end
    if node.Name:sub(1, 6) == "Right_" then return "Right" end
    return nil
end

local function findLanes(side)
    local window = playerGui:FindFirstChild("Window")
    local gameView = window and window:FindFirstChild("Game")
    local fields = gameView and gameView:FindFirstChild("Fields")
    local field = fields and fields:FindFirstChild(side)
    local inner = field and field:FindFirstChild("Inner")
    if not inner then return nil, nil end
    local lanes = {}
    for _, child in ipairs(inner:GetChildren()) do
        local idx = tonumber(child.Name:match("^Lane(%d+)$"))
        if idx and idx <= CONFIG.MaxLanes then
            local receptor = child:FindFirstChild("Receptor")
            local notes = child:FindFirstChild("Notes")
            if receptor and notes and receptor:IsA("GuiObject") then
                lanes[#lanes + 1] = {index=idx, receptor=receptor, notes=notes}
            end
        end
    end
    table.sort(lanes, function(a,b) return a.index < b.index end)
    if #lanes == 0 then return nil, nil end
    return lanes, inner
end

local function centerY(obj)
    return obj.AbsolutePosition.Y + obj.AbsoluteSize.Y * 0.5
end

local function cleanupSession(reason)
    local s = session
    if not s then return end
    session = nil
    for _, connection in ipairs(s.connections) do
        connection:Disconnect()
    end
    for index, binding in pairs(s.bindings) do
        pcall(function() binding:Fire(false) end)
        pcall(function() binding:Destroy() end)
        s.held[index] = nil
    end
    if reason then log(reason) end
end

local function createSession(side, lanes, inner)
    local context = playerGui:FindFirstChild("VSRGContext")
    if not context or not context:IsA("InputContext") or not context.Enabled then
        return false
    end
    local s = {
        side=side, inner=inner, context=context,
        lanes=lanes, bindings={}, actions={}, connections={}, held={}, notes={},
        lastTap={}, speed=CONFIG.SpeedDefault, direction=-1, directionVotes=0,
        idleSince=os.clock(), lastFrame=os.clock(), frameNumber=0,
        lastPrune=os.clock()
    }
    for _, lane in ipairs(lanes) do
        local action = context:FindFirstChild("Lane" .. lane.index)
        if not action or not action:IsA("InputAction") or not action.Enabled
            or action.Type ~= Enum.InputActionType.Bool then
            for _, binding in pairs(s.bindings) do pcall(function() binding:Destroy() end) end
            return false
        end
        local ok, binding = pcall(function()
            local newBinding = Instance.new("InputBinding")
            newBinding.Name = "KvkV2Lane" .. lane.index
            newBinding.Type = Enum.InputBindingType.Scriptable
            newBinding.Parent = action
            return newBinding
        end)
        if not ok then
            for _, previous in pairs(s.bindings) do pcall(function() previous:Destroy() end) end
            log("Input setup error: " .. tostring(binding))
            return false
        end
        s.bindings[lane.index] = binding
        s.actions[lane.index] = action
        s.connections[#s.connections + 1] = action.Pressed:Connect(function()
            summary.press = summary.press + 1
        end)
        s.connections[#s.connections + 1] = action.Released:Connect(function()
            summary.release = summary.release + 1
        end)
    end
    session = s
    log(string.format("Attached to %s / %d lanes", side, #lanes))
    return true
end

local function fire(s, index, state)
    local binding = s.bindings[index]
    if not binding then return false end
    local ok, err = pcall(function() binding:Fire(state) end)
    if not ok then
        summary.errors = summary.errors + 1
        armed = false
        log("Input error: " .. tostring(err))
        cleanupSession("Stopped after input error")
        return false
    end
    return true
end

local function releaseDue(s, now)
    for index, held in pairs(s.held) do
        if held and now >= held.untilTime then
            if not fire(s, index, false) then return false end
            s.held[index] = nil
        end
    end
    return true
end

local function tryPress(s, lane, kind, sustain, note, now)
    local index = lane.index
    local current = s.held[index]
    if current and current.kind == "Hold" and now < current.untilTime then
        summary.conflicts = summary.conflicts + 1
        return false
    end
    if current then
        if not fire(s, index, false) then return false end
        s.held[index] = nil
    end
    if now - (s.lastTap[index] or -10) < CONFIG.MinTapInterval then
        summary.conflicts = summary.conflicts + 1
        return false
    end
    if not fire(s, index, true) then return false end
    local duration = CONFIG.TapSeconds
    if kind == "Hold" then
        local pixels = sustain * math.max(20, note.AbsoluteSize.Y)
        duration = math.clamp(pixels / s.speed + CONFIG.HoldPadding, 0.075, 8)
        summary.holds = summary.holds + 1
    else
        summary.taps = summary.taps + 1
    end
    s.lastTap[index] = now
    s.held[index] = {kind=kind, untilTime=now + duration}
    return true
end

local function stepSession(s, now)
    -- Every callback is counted so the report distinguishes game stalls from misses.
    -- Long frames do not trigger an expensive catch-up loop.
    local gapMs = math.max(0, (now - s.lastFrame) * 1000)
    s.lastFrame = now
    s.frameNumber = s.frameNumber + 1
    summary.frames = summary.frames + 1
    if gapMs > summary.largestFrameMs then summary.largestFrameMs = gapMs end

    local hadSpike = gapMs > CONFIG.SpikeThresholdMs
    if hadSpike then summary.spikes = summary.spikes + 1 end
    local lateLimitMs = hadSpike
        and math.min(CONFIG.MaxRecoveryLateMs, gapMs + CONFIG.RecoveryPaddingMs)
        or CONFIG.BaseLateMs
    local targetMs = CONFIG.OffsetMs + CONFIG.EarlyLeadMs

    if not s.context.Parent or not s.context.Enabled or not s.inner.Parent then
        cleanupSession("Song or input context changed")
        return
    end
    if not releaseDue(s, now) then return end

    local active = 0
    local speedSum, speedSamples = 0, 0
    local movementDirectionSum = 0

    for _, lane in ipairs(s.lanes) do
        if not lane.notes.Parent or not lane.receptor.Parent then
            cleanupSession("Chart lanes changed")
            return
        end

        local receptorY = centerY(lane.receptor)
        local items = {}
        for _, note in ipairs(lane.notes:GetChildren()) do
            if note:IsA("GuiObject") and note.Visible then
                active = active + 1
                local dy = centerY(note) - receptorY
                local record = s.notes[note]
                local elapsed = record and (now - record.time) or 0
                local movement = record and math.abs(dy - record.dy) or 0
                -- A long frame naturally moves a note hundreds of pixels.
                -- Do not mistake that for an object being recycled.
                local discontinuity = record
                    and movement > math.max(270, s.speed * elapsed * 2 + 65)
                local recycled = not record or record.name ~= note.Name or discontinuity

                if recycled then
                    -- Classify once per note appearance, not every render frame.
                    -- Preserve the initial hold length as its body later shrinks.
                    local kind, sustain = classify(note)
                    summary.classified = summary.classified + 1
                    record = {
                        name=note.Name, dy=dy, time=now, kind=kind,
                        sustain=sustain, handled=false, created=now,
                        previousT=nil,
                    }
                    s.notes[note] = record
                else
                    if elapsed >= 0.005 and elapsed <= 0.075 then
                        local v = (dy - record.dy) / elapsed
                        if math.abs(v) >= 140 and math.abs(v) <= 2400
                            and movement < math.max(130, elapsed * 2300) then
                            speedSum = speedSum + math.abs(v)
                            speedSamples = speedSamples + 1
                            movementDirectionSum = movementDirectionSum + (v > 0 and 1 or -1)
                        end
                    end
                end

                record.dy = dy
                record.time = now
                record.seenFrame = s.frameNumber
                items[#items + 1] = {
                    lane=lane, note=note, record=record,
                    dy=dy, kind=record.kind, sustain=record.sustain,
                }
            end
        end

        -- Normally only a few notes per lane. Keep chronological proximity
        -- to avoid dispatching a later tap before the nearer tap on dense charts.
        if #items > 1 then
            table.sort(items, function(a, b)
                return math.abs(a.dy) < math.abs(b.dy)
            end)
        end
        lane._current = items
    end

    if active > 0 then s.idleSince = now end
    if active == 0 and now - s.idleSince > CONFIG.IdleReleaseSeconds then
        cleanupSession("No notes; waiting for next chart")
        return
    end

    if speedSamples > 0 then
        local avg = speedSum / speedSamples
        -- Don't let a single noisy sample drastically change the prediction.
        if avg >= s.speed * 0.58 and avg <= s.speed * 1.65 then
            s.speed = math.clamp(s.speed * 0.95 + avg * 0.05, 180, 2300)
        end
        if movementDirectionSum ~= 0 then
            local observed = movementDirectionSum > 0 and 1 or -1
            s.directionVotes = math.clamp(s.directionVotes + observed, -7, 7)
            if s.directionVotes >= 5 then s.direction = 1 end
            if s.directionVotes <= -5 then s.direction = -1 end
        end
    end

    for _, lane in ipairs(s.lanes) do
        local items = lane._current
        local hazardNear = false
        for _, item in ipairs(items) do
            item.timeMs = -item.dy / (s.speed * s.direction) * 1000
            if item.kind == "Hazard" and math.abs(item.timeMs) <= CONFIG.HazardGuardMs then
                hazardNear = true
            end
        end
        for _, item in ipairs(items) do
            local record = item.record
            if not record.handled then
                local t = item.timeMs
                local prior = record.previousT
                local beforeReceptor = (item.dy * s.direction) < 0
                local inWindow = t <= targetMs and t >= -lateLimitMs
                local crossed = prior ~= nil and prior > targetMs and t <= targetMs
                -- Newly visible note already inside the strike window.
                -- Only act before the receptor or at most 20 ms past it.
                local fresh = prior == nil and t >= -20 and beforeReceptor
                local shouldHandle = inWindow and (crossed or fresh)

                if shouldHandle then
                    record.handled = true
                    if item.kind == "Hazard" then
                        summary.hazards = summary.hazards + 1
                    elseif item.kind == "Unknown" then
                        summary.unknowns = summary.unknowns + 1
                    elseif hazardNear then
                        summary.guard = summary.guard + 1
                    else
                        local hadInput = tryPress(s, lane, item.kind,
                            item.sustain, item.note, now)
                        if not session then return end
                        if hadInput and t < -CONFIG.BaseLateMs and hadSpike then
                            -- The input was attempted after a hitch. Actual
                            -- game judgment still must be verified separately.
                            summary.recovered = summary.recovered + 1
                        end
                    end
                elseif t < -lateLimitMs - 12 then
                    record.handled = true
                    summary.missedWindow = summary.missedWindow + 1
                end
                record.previousT = t
            end
        end
        lane._current = nil
    end

    -- Periodic pruning avoids building and scanning an allNotes table every frame.
    if now - s.lastPrune >= CONFIG.PruneEverySeconds then
        s.lastPrune = now
        for note, record in pairs(s.notes) do
            if record.seenFrame ~= s.frameNumber or not note.Parent then
                s.notes[note] = nil
            end
        end
    end
end

local function updatePanel()
    toggle.Text = armed and "AUTO: ON" or "AUTO: OFF"
    toggle.BackgroundColor3 = armed and Color3.fromRGB(33, 112, 76) or Color3.fromRGB(48, 63, 87)
    sideButton.Text = "SIDE: " .. sideMode:upper()
    resetButton.Text = string.format("%+d ms", CONFIG.OffsetMs)
    local s = session
    info.Text = table.concat({
        "Status: " .. (s and "PLAYING" or armed and "WAITING FOR SONG" or "OFF"),
        "Chart: " .. (s and (s.side .. "/" .. #s.lanes .. " lanes") or "none"),
        "Taps: " .. summary.taps .. "  Holds: " .. summary.holds,
        "Hazards: " .. summary.hazards .. "  Unknown: " .. summary.unknowns,
        "Guarded: " .. summary.guard .. "  Conflicts: " .. summary.conflicts,
        string.format("Speed: %.0f px/s  Spikes: %d  Max: %.0fms",
            s and s.speed or CONFIG.SpeedDefault, summary.spikes, summary.largestFrameMs),
        string.format("Input: %d/%d  Recovered: %d  Late: %d",
            summary.press, summary.release, summary.recovered, summary.missedWindow)
    }, "\n")
end

local function stop(why)
    armed = false
    cleanupSession(why or "Stopped")
    updatePanel()
end

connections[#connections + 1] = toggle.Activated:Connect(function()
    if armed then
        stop("Autoplay disabled")
    else
        armed = true
        log("Autoplay armed; waiting for a chart")
        updatePanel()
    end
end)
connections[#connections + 1] = stopButton.Activated:Connect(function()
    stop("Manual stop")
end)
connections[#connections + 1] = sideButton.Activated:Connect(function()
    if sideMode == "Auto" then sideMode = "Left"
    elseif sideMode == "Left" then sideMode = "Right"
    else sideMode = "Auto" end
    cleanupSession("Side changed; reattaching")
    updatePanel()
end)
connections[#connections + 1] = minusButton.Activated:Connect(function()
    CONFIG.OffsetMs = math.max(-75, CONFIG.OffsetMs - 5)
    updatePanel()
end)
connections[#connections + 1] = plusButton.Activated:Connect(function()
    CONFIG.OffsetMs = math.min(75, CONFIG.OffsetMs + 5)
    updatePanel()
end)
connections[#connections + 1] = resetButton.Activated:Connect(function()
    CONFIG.OffsetMs = 0
    updatePanel()
end)
connections[#connections + 1] = copyButton.Activated:Connect(function()
    local report = table.concat({
        "[K]vk FF V2.1 | " .. (session and session.side or "None"),
        "Taps=" .. summary.taps .. " Holds=" .. summary.holds,
        "Hazards=" .. summary.hazards .. " Unknown=" .. summary.unknowns,
        "Guard=" .. summary.guard .. " Conflicts=" .. summary.conflicts,
        "Pressed=" .. summary.press .. " Released=" .. summary.release,
        "Errors=" .. summary.errors .. " Offset=" .. CONFIG.OffsetMs .. "ms",
        "Frame spikes=" .. summary.spikes .. " LargestFrame=" ..
            string.format("%.1f", summary.largestFrameMs) .. "ms",
        "RecoveryInputs=" .. summary.recovered .. " MissedWindow=" ..
            summary.missedWindow .. " Classified=" .. summary.classified ..
            " Frames=" .. summary.frames,
        table.concat(logs, "\n")
    }, "\n")
    if type(setclipboard) == "function" then
        local ok = pcall(setclipboard, report)
        if ok then log("Report copied") return end
    end
    print(report)
    log("Report printed to console")
end)
connections[#connections + 1] = minimize.Activated:Connect(function()
    minimized = not minimized
    panel.Size = UDim2.fromOffset(340, minimized and 117 or 344)
    for _, obj in ipairs({info, logBox, copyButton}) do obj.Visible = not minimized end
    minimize.Text = minimized and "+" or "MIN"
end)

local dragging = false
local dragStart, positionStart, touch
connections[#connections + 1] = header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        positionStart = panel.Position
        touch = input.UserInputType == Enum.UserInputType.Touch and input or nil
    end
end)
connections[#connections + 1] = UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end
    if (touch and input == touch) or (not touch and input.UserInputType == Enum.UserInputType.MouseMovement) then
        local delta = input.Position - dragStart
        panel.Position = UDim2.new(positionStart.X.Scale, positionStart.X.Offset + delta.X,
            positionStart.Y.Scale, positionStart.Y.Offset + delta.Y)
    end
end)
connections[#connections + 1] = UserInputService.InputEnded:Connect(function(input)
    if (touch and input == touch) or (not touch and input.UserInputType == Enum.UserInputType.MouseButton1) then
        dragging = false
        touch = nil
    end
end)

local function destroy()
    if not alive then return end
    alive = false
    stop("Closed")
    for _, connection in ipairs(connections) do connection:Disconnect() end
    gui:Destroy()
end
connections[#connections + 1] = closeButton.Activated:Connect(destroy)
connections[#connections + 1] = shutdown.Event:Connect(destroy)

-- Run after the render-critical phase instead of blocking PreRender.
-- A short early lead compensates for observing the just-updated note positions.
connections[#connections + 1] = RunService.Heartbeat:Connect(function()
    if not alive then return end
    local now = os.clock()
    if armed then
        if not session then
            if now - lastAttempt > 0.45 then
                lastAttempt = now
                local side = detectSide()
                if side then
                    local lanes, inner = findLanes(side)
                    if lanes then
                        local visible = 0
                        for _, lane in ipairs(lanes) do
                            visible = visible + #lane.notes:GetChildren()
                        end
                        if visible > 0 then createSession(side, lanes, inner) end
                    end
                end
            end
        else
            local current = session
            local ok, err = pcall(stepSession, current, now)
            if not ok then
                summary.errors = summary.errors + 1
                stop("Runtime error: " .. tostring(err))
            end
        end
    end
    if now - lastStatus >= CONFIG.StatusEverySeconds then
        lastStatus = now
        updatePanel()
    end
end)

log("V2.1 ready | reduced per-frame work and spike recovery")
log("AUTO ON during solo song; death/unknown notes skipped")
log("No input changes until autoplay is enabled")
updatePanel()
