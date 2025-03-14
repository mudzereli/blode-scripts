local _imgui = require("imgui")
local ImGui = _imgui.ImGui
local views = require("utilitybelt.views")
local acclient = require("acclient")
local targetHudConfig = config.targetHudConfig

-------------------------------------------------
--- IMGUI for TARGETHUD
-------------------------------------------------
-- Set HUD properties.
local targetHud = views.Huds.CreateHud("Selection")
targetHud.Visible = false
targetHud.ShowInBar = true
targetHud.WindowSettings = targetHudConfig.windowSettings or targetHud.WindowSettings 

targetHud.OnHide.Add(function()
  targetHide = true
  targetHud.Visible = false
  saveSettings()
end)
targetHud.OnShow.Add(function()
  targetHide = false
  targetHud.Visible = true
  saveSettings()
end)

local firstUse = true
local targetPrerender = function()
  local zeroVector = Vector2.new(0, 0)
  ImGui.PushStyleVar(_imgui.ImGuiStyleVar.WindowMinSize, Vector2.new(1, ImGui.GetFontSize()))
  ImGui.PushStyleVar(_imgui.ImGuiStyleVar.WindowPadding, zeroVector)
  ImGui.PushStyleVar(_imgui.ImGuiStyleVar.FramePadding, zeroVector)
  ImGui.PushStyleVar(_imgui.ImGuiStyleVar.ItemSpacing, zeroVector)
  ImGui.PushStyleVar(_imgui.ImGuiStyleVar.ItemInnerSpacing, zeroVector)
  if firstUse then
    ImGui.SetNextWindowSize(targetSize or Vector2.new(200, 30))
    ImGui.SetNextWindowPos(targetPosition or Vector2.new(100 + (1 * 10), (1 - 1) * (30 + 10)))
    firstUse = false
  end

  -- Set flags to disable all unnecessary decorations.
  if ImGui.GetIO().KeyCtrl then
    targetHud.WindowSettings =
        _imgui.ImGuiWindowFlags.NoScrollbar
  else
    targetHud.WindowSettings =
        _imgui.ImGuiWindowFlags.NoTitleBar +
        _imgui.ImGuiWindowFlags.NoScrollbar + -- Prevent scrollbars explicitly.
        _imgui.ImGuiWindowFlags.NoMove +      -- Prevent moving unless Ctrl is pressed.
        _imgui.ImGuiWindowFlags.NoResize +     -- Prevent resizing unless Ctrl is pressed.
        ---@diagnostic disable-next-line
        (targetHudConfig.windowSettings or 0)
        
  end
end

-- Render directly into the parent HUD window using BeginChild to anchor progress bars.
local targetRender
targetRender = function()
  if not target or not game.World.Selected or target.id ~= game.World.Selected.Id then
    ImGui.PopStyleVar(5)
    targetHud.OnPreRender.Remove(targetPrerender)
    targetHud.OnRender.Remove(targetRender)
    return
  end
  if ImGui.BeginChild("targetHud", Vector2.new(0, 0), false, targetHud.WindowSettings) then
    local fontScale = targetHudConfig.fontScale or 1
    ImGui.SetWindowFontScale(fontScale)

    for _, style in ipairs(targetHudConfig.stylevar or {}) do
      ImGui.PushStyleVar(style[1], style[2])
    end
    for _,color in ipairs(targetHudConfig.styleColor or {}) do
      ImGui.PushStyleColor(color[1],color[2])
    end

    ImGui.PushStyleColor(_imgui.ImGuiCol.PlotHistogram, targetHudConfig.color)

    -- Render the progress bar inside the HUD without default text.
    local progressBarSize = Vector2.new(ImGui.GetContentRegionAvail().X, ImGui.GetContentRegionAvail().Y)
    --print(progressBarSize)
    local progressFraction = target.hp / 1 
    local progressBarStartPos = ImGui.GetCursorScreenPos()   -- Save the starting position of the progress bar
    ImGui.ProgressBar(progressFraction, progressBarSize, "") -- Render bar without default text

    -- Calculate and render custom text based on alignment setting
    targetHudConfig.text(progressBarStartPos,progressBarSize)

    ImGui.PopStyleColor() -- Ensure this matches PushStyleColor()
    
    for _,__ in ipairs(targetHudConfig.styleColor or {}) do
      ImGui.PopStyleColor()
    end
    for _, __ in ipairs(targetHudConfig.stylevar or {}) do
      ImGui.PopStyleVar()
    end


    -- Save position/size when Ctrl is pressed.
    if ImGui.GetIO().KeyCtrl then
      local currentPos = ImGui.GetWindowPos() - Vector2.new(0, ImGui.GetFontSize())
      local currentContentSize = ImGui.GetWindowSize() - Vector2.new(0, -ImGui.GetFontSize())

      if currentPos.X ~= (targetPosition and targetPosition.X or -1) or
          currentPos.Y ~= (targetPosition and targetPosition.Y or -1) or
          currentContentSize.X ~= (targetSize and targetSize.X or -1) or
          currentContentSize.Y ~= (targetSize and targetSize.Y or -1) then
        targetPosition = currentPos
        targetSize = Vector2.new(currentContentSize.X, currentContentSize.Y)

        saveSettings()
      end
    end
  end

  ImGui.EndChild()
  ImGui.PopStyleVar(5) --WindowMinSize,WindowPadding,FramePadding,ItemSpacing,ItemInnerSpacing
end

local lastMob
game.World.OnObjectSelected.Add(function(objSelectionEvent)
  targetHud.OnPreRender.Remove(targetPrerender)
  targetHud.OnRender.Remove(targetRender)
  if lastMob and game.World.Exists(lastMob.id) then
    local coords=nil
    if game.World.Exists(lastMob.id) then coords=acclient.Movement.GetPhysicsCoordinates(lastMob.id) end
    if coords and (acclient.Coordinates.Me.DistanceTo(coords)<(config.maxDistanceForVisibility or math.huge)) and (lastMob and lastMob.hp~=0) then
      lastMob.redbar.Visible = true
      lastMob.hpbar.Visible = true
    end
  end
  if wobjects_hp[objSelectionEvent.ObjectId]~=nil then
    targetHud.OnPreRender.Add(targetPrerender)
    targetHud.OnRender.Add(targetRender)
    targetHud.Visible = true
    target=wobjects_hp[objSelectionEvent.ObjectId]

    if targetHudConfig.hideSelectionHp then
      lastMob=wobjects_hp[objSelectionEvent.ObjectId]
      target.hpText.Visible=false
      target.redbar.Visible=false
      target.hpbar.Visible=false
    end
  end
end)

return targetHud