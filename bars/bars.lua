local _imgui = require("imgui")
local ImGui = _imgui.ImGui
local vitals = game.Character.Weenie.Vitals
local acclient = require("acclient")

-- ACTIONQUEUE CONFIG
local genericActionOpts = ActionOptions.new()
---@diagnostic disable
genericActionOpts.MaxRetryCount = 0
genericActionOpts.TimeoutMilliseconds = 100
---@diagnostic enable
local genericActionCallback = function(e)
  if not e.Success then
    if e.Error ~= ActionError.ItemAlreadyWielded then
      print("Fail! " .. e.ErrorDetails)
    end
  end
end

local equipmentActionOpts = ActionOptions.new()
---@diagnostic disable
equipmentActionOpts.MaxRetryCount = 3
equipmentActionOpts.TimeoutMilliseconds = 250
---@diagnostic enable


local function stagger(count, opts)
  local staggered = ActionOptions.new()
  if opts then
    staggered.TimeoutMilliseconds = opts.TimeoutMilliseconds * count
    staggered.MaxRetryCount = opts.MaxRetryCount
    staggered.SkipChecks = opts.SkipChecks
  else
    staggered.TimeoutMilliseconds = genericActionOpts.TimeoutMilliseconds * count
    staggered.MaxRetryCount = genericActionOpts.MaxRetryCount
    staggered.SkipChecks = genericActionOpts.SkipChecks
  end
  return staggered
end

-- FUNCTIONS USED BY BARS
local function sortbag(bar, inscription, containerHolder, func)
  if bar.sortBag == nil or game.World.Exists(bar.sortBag) == false then
    for _, bag in ipairs(containerHolder.Containers) do
      game.Messages.Incoming.Item_SetAppraiseInfo.Until(function(e)
        if bag.Id == e.Data.ObjectId then
          if bag.Value(StringId.Inscription) == inscription then
            bar.sortBag = bag.Id
            SaveBarSettings(bar, "sortBag", bag.Id)
          end
          ---@diagnostic disable-next-line
          return true
        end
        ---@diagnostic disable-next-line
        return false
      end)

      bag.Appraise()
    end
  else
    func(bar)
  end
end

local function renderEvent(bar)                                                       -- used by floating combatTexts
  local currentTime = os.clock()
  local validEntries = {}                                                             -- Temporary list for valid entries
  local average = (bar.runningCount > 0) and (bar.runningSum / bar.runningCount) or 1 -- Avoid divide by zero

  -- Get the window's current size (content region)
  local windowSize = ImGui.GetContentRegionAvail()
  local lastEntry = nil
  local minSpacingX = 20

  -- Process and render each entry
  for i, entry in ipairs(bar.entries) do
    local elapsed = currentTime - entry.time
    if elapsed <= bar.settings.fadeDuration_num then
      -- Calculate alpha for fade effect
      local alpha = 1 - (elapsed / bar.settings.fadeDuration_num)
      local color = tonumber(
        string.format("%02X%06X", math.floor(alpha * 255),
          entry.positive and bar.settings.fontColorPositive_col3 or bar.settings.fontColorNegative_col3),
        16)

      -- Scale font based on value relative to the average
      if not entry.scale then
        entry.scale = string.sub(entry.text, -1) == "!" and entry.fontScaleCrit_flt or
            math.min(math.max((entry.value or average) / average, bar.settings.fontScaleMin_flt), bar.settings
              .fontScaleMax_flt)
      end
      ImGui.SetWindowFontScale(entry.scale)

      -- Calculate the floating distance based on elapsed time and window size
      local floatDistance = (elapsed / bar.settings.fadeDuration_num) * windowSize.Y -- Scale to the full window height

      -- Start the y position from the bottom of the window and move up
      entry.cursorPosY = windowSize.Y - floatDistance - ImGui.GetFontSize()

      if entry.cursorPosX == nil then
        -- Calculate horizontal position based on entry index
        entry.textSize = ImGui.CalcTextSize(entry.text)
        local baseX = (windowSize.X - entry.textSize.X) / 2 -- Center position
        entry.cursorPosX = baseX

        if lastEntry then
          local conflict = function()
            return (lastEntry.cursorPosY + lastEntry.textSize.Y - entry.cursorPosY) > 0 and
                (lastEntry.cursorPosX + lastEntry.textSize.X - entry.cursorPosX) > 0
          end
          if conflict() then
            entry.cursorPosX = baseX + lastEntry.textSize.X + minSpacingX
            if entry.cursorPosX + entry.textSize.X > windowSize.X or conflict() then
              entry.cursorPosX = lastEntry.cursorPosX - entry.textSize.X - minSpacingX
            end
          end
        end
      end

      -- Set the cursor position using SetCursorPos, relative to the window
      ImGui.SetCursorPos(Vector2.new(entry.cursorPosX, entry.cursorPosY))

      -- Render the text at the calculated position
      ImGui.PushStyleColor(_imgui.ImGuiCol.Text, color)
      ImGui.Text(entry.text)
      ImGui.PopStyleColor()

      -- Reset font scaling after rendering
      ImGui.SetWindowFontScale(1)

      -- Store the valid entry for the next render cycle
      table.insert(validEntries, entry)
    else
      -- Remove expired entry from running sum and count
      if entry.value and bar.runningCount > 10 then
        bar.runningSum = bar.runningSum - entry.value
        bar.runningCount = bar.runningCount - 1
      end
    end
    lastEntry = entry
  end

  -- Replace old entries with the valid ones
  bar.entries = validEntries
end

local function renderBuffs(bar)
  local buffs = {}

  ---@param enchantment Enchantment
  for _, enchantment in ipairs(game.Character.ActiveEnchantments()) do
    ---@type Spell
    local spell = game.Character.SpellBook.Get(enchantment.SpellId)

    local entry = {}
    entry.ClientReceivedAt = enchantment.ClientReceivedAt
    entry.Duration = enchantment.Duration
    entry.StartTime = enchantment.StartTime
    if entry.Duration > -1 then
      entry.ExpiresAt = (entry.ClientReceivedAt + TimeSpan.FromSeconds(entry.StartTime + entry.Duration) - DateTime.UtcNow)
          .TotalSeconds
    else
      entry.ExpiresAt = 999999
    end

    if bar.displayCriteria(enchantment, spell, entry) then
      entry.Name = spell.Name or "Unknown"
      entry.Id = spell.Id or "No spell.Id"
      entry.Level = ({ "I", "II", "III", "IV", "V", "VI", "VII", "VIII" })[spell.Level]

      entry.icon = spell.Icon or 9914

      local function hasFlag(object, flag)
        return (object.Flags + flag == object.Flags)
      end

      local statKey = spell.StatModKey
      if spell.StatModAttribute ~= AttributeId.Undef then
        entry.stat = tostring(AttributeId.Undef + statKey)
      elseif spell.StatModVital ~= Vital.Undef then
        entry.stat = tostring(Vital.Undef + statKey)
      elseif spell.StatModSkill ~= SkillId.Undef then
        entry.stat = tostring(SkillId.Undef + statKey)
      elseif spell.StatModIntProp ~= IntId.Undef then
        entry.stat = tostring(IntId.Undef + statKey)
      elseif spell.StatModFloatProp ~= FloatId.Undef then
        entry.stat = tostring(FloatId.Undef + statKey)
      else
        entry.stat = tostring(enchantment.Category)
      end

      if hasFlag(enchantment, EnchantmentFlags.Additive) then
        entry.printProp = enchantment.StatValue > 0 and ("+" .. enchantment.StatValue) or enchantment.StatValue
      elseif hasFlag(enchantment, EnchantmentFlags.Multiplicative) then
        local percent = enchantment.StatValue - 1
        entry.printProp = (percent > 0 and ("+" .. string.format("%.0d", percent * 100)) or string.format("%.0d", percent * 100)) ..
            "%%"
      end

      table.insert(buffs, entry)
    end
  end

  table.sort(buffs, function(a, b)
    return a.ClientReceivedAt < b.ClientReceivedAt
  end)

  local windowPos = ImGui.GetWindowPos() + Vector2.new(5, 5)
  local windowSize = ImGui.GetContentRegionAvail()
  local minX, minY
  local maxX, maxY
  local iconSize = Vector2.new(28, 28)
  local bufferRect_vec2 = Vector2.new(bar.settings.bufferRectX_num, bar.settings.bufferRectY_num)

  ImGui.BeginChild("ScrollableChild", ImGui.GetContentRegionAvail(), true)
  for i, buff in ipairs(buffs) do
    local cursorStartX, cursorStartY
    local expiryTimer = (buff.ClientReceivedAt + TimeSpan.FromSeconds(buff.StartTime + buff.Duration) - DateTime.UtcNow)
        .TotalSeconds
    local spellLevelSize_vec2 = ImGui.CalcTextSize(buff.Level)

    local reservedPerIconX = iconSize.X + bufferRect_vec2.X + bar.settings.iconSpacing_num
    local reservedPerIconY = iconSize.Y + bufferRect_vec2.Y + bar.settings.iconSpacing_num +
        ImGui.GetTextLineHeight() * 1.5
    if bar.settings.growAxis_str == "X" then
      if not bar.settings.growReverse then
        cursorStartX = windowPos.X + (i - 1) * reservedPerIconX
        cursorStartY = windowPos.Y + (bar.settings.growAlignmentFlip and windowSize.Y - reservedPerIconY or 0)
        if i > 1 and (cursorStartX + reservedPerIconX) > (windowPos.X + windowSize.X) then
          local iconsPerRow = math.floor(windowSize.X / reservedPerIconX)
          local rowOffset = 1
          while rowOffset < i and iconsPerRow * rowOffset < i do
            rowOffset = rowOffset + 1
          end
          cursorStartX = windowPos.X + math.floor((i - 1) - iconsPerRow * rowOffset + iconsPerRow) * reservedPerIconX
          cursorStartY = windowPos.Y + (bar.settings.growAlignmentFlip and windowSize.Y - reservedPerIconY or 0) +
              (bar.settings.growAlignmentFlip and -rowOffset + 1 or rowOffset - 1) * reservedPerIconY
        end
      else --reverse X
        cursorStartX = windowPos.X + windowSize.X - i * reservedPerIconX
        cursorStartY = windowPos.Y + (bar.settings.growAlignmentFlip and windowSize.Y - reservedPerIconY or 0)
        if i > 1 and cursorStartX < windowPos.X then
          local iconsPerRow = math.floor(windowSize.X / reservedPerIconX)
          local rowOffset = 1
          while rowOffset < i and iconsPerRow * rowOffset < i do
            rowOffset = rowOffset + 1
          end
          cursorStartX = windowPos.X + windowSize.X - math.floor(i - iconsPerRow * rowOffset + iconsPerRow) *
              reservedPerIconX
          cursorStartY = windowPos.Y + (bar.settings.growAlignmentFlip and windowSize.Y - reservedPerIconY or 0) +
              (bar.settings.growAlignmentFlip and -rowOffset + 1 or rowOffset - 1) * reservedPerIconY
        end
      end
    elseif bar.settings.growAxis_str == "Y" then --growAxis Y
      if not bar.settings.growReverse then
        cursorStartX = windowPos.X + (bar.settings.growAlignmentFlip and windowSize.X - reservedPerIconX or 0)
        cursorStartY = windowPos.Y + (i - 1) * reservedPerIconY
        if i > 1 and (cursorStartY + reservedPerIconY) > (windowPos.Y + windowSize.Y) then
          local iconsPerCol = math.floor(windowSize.Y / reservedPerIconY)
          local colOffset = 1
          while colOffset < i and iconsPerCol * colOffset < i do
            colOffset = colOffset + 1
          end
          cursorStartX = windowPos.X + (bar.settings.growAlignmentFlip and windowSize.X - reservedPerIconX or 0) +
              (bar.settings.growAlignmentFlip and -colOffset + 1 or colOffset - 1) * reservedPerIconX
          cursorStartY = windowPos.Y + math.floor((i - 1) - iconsPerCol * colOffset + iconsPerCol) * reservedPerIconY
        end
      else -- reverse Y
        cursorStartX = windowPos.X + (bar.settings.growAlignmentFlip and windowSize.X - reservedPerIconX or 0)
        cursorStartY = windowPos.Y + windowSize.Y - i * reservedPerIconY
        if i > 1 and cursorStartY < windowPos.Y then
          local iconsPerCol = math.floor(windowSize.Y / reservedPerIconY)
          local colOffset = 1
          while colOffset < i and iconsPerCol * colOffset < i do
            colOffset = colOffset + 1
          end
          cursorStartX = windowPos.X + (bar.settings.growAlignmentFlip and windowSize.X - reservedPerIconX or 0) +
              (bar.settings.growAlignmentFlip and -colOffset + 1 or colOffset - 1) * reservedPerIconX
          cursorStartY = windowPos.Y + windowSize.Y - math.floor(i - iconsPerCol * colOffset + iconsPerCol) *
              reservedPerIconY
        end
      end
    end

    if not minX or minX > cursorStartX then
      minX = cursorStartX
    end
    if not minY or minY > cursorStartY then
      minY = cursorStartY
    end
    if not maxX or maxX < cursorStartX then
      maxX = cursorStartX
    end
    if not maxY or maxY < cursorStartY then
      maxY = cursorStartY
    end

    local cursorStart = Vector2.new(cursorStartX, cursorStartY)
    ImGui.GetWindowDrawList().AddRectFilled(cursorStart,
      cursorStart + iconSize + bufferRect_vec2 + Vector2.new(0, ImGui.GetTextLineHeight() + spellLevelSize_vec2.Y / 2),
      0xAA000000)

    ImGui.SetCursorScreenPos(cursorStart + bufferRect_vec2 / 2 + Vector2.new(0, spellLevelSize_vec2.Y / 2)) --+Vector2.new(expirySize.X>iconSize.X and (iconSize.X-expirySize.X)/2 or 0,0))
    ImGui.TextureButton("##buff" .. buff.Id, GetOrCreateTexture(buff.icon), iconSize)
    if ImGui.IsItemHovered() then
      ImGui.BeginTooltip()

      ImGui.Text(buff.Name)
      ImGui.Text(buff.stat)
      ImGui.SameLine()
      ImGui.PushStyleColor(_imgui.ImGuiCol.Text, 0xFF00FF00)
      ImGui.Text(" " .. buff.printProp)
      ImGui.PopStyleColor()

      ImGui.EndTooltip()
    end
    if bar.settings.spellLevelDisplay and buff.Level then
      ImGui.SetCursorScreenPos(cursorStart +
        Vector2.new(bufferRect_vec2.X / 2 + iconSize.X / 2 - spellLevelSize_vec2.X / 2, 0)) --Vector2.new(0,spellLevelSize.Y/2))--Vector2.new(0,spellLevelSize.Y))
      ImGui.PushStyleColor(_imgui.ImGuiCol.Text, bar.settings.spellLevelColor_col4)
      ImGui.Text(buff.Level)
      ImGui.PopStyleColor()
    end

    local expiryTextSize = ImGui.CalcTextSize(bar.formatSeconds(expiryTimer))
    ImGui.SetCursorScreenPos(cursorStart +
      Vector2.new(bufferRect_vec2.X / 2 + iconSize.X / 2 - expiryTextSize.X / 2,
        iconSize.Y + bufferRect_vec2.Y / 2 + spellLevelSize_vec2.Y / 2))
    ImGui.Text(bar.formatSeconds(expiryTimer))
  end
  ImGui.EndChild()
  if bar.settings.buffBorder and minX and minY and maxX and maxY then
    ImGui.GetWindowDrawList().AddRect(Vector2.new(minX - 3, minY - 3),
      Vector2.new(maxX + 3 + iconSize.X + bufferRect_vec2.X,
        maxY + 3 + iconSize.Y + bufferRect_vec2.Y + ImGui.GetTextLineHeight() * 1.5),
      bar.settings.buffBorderColor_col4 or 0x99000099, 0,
      0, bar.settings.buffBorderThickness_num or 2)
  end
end

-- INITIALIZATION STUFF FOR TO BE ABLE TO SEE PARENT
-- Create the bars table with a metatable
local bars = setmetatable({}, {
  -- When adding new entries, ensure parent and index by name
  __newindex = function(t, k, v)
    if type(v) == "table" and v.name then
      rawset(t, v.name, v) -- Index the bar by its name
      v.parent = t         -- Set the parent reference
    end
    rawset(t, k, v)        -- Add to the array
  end,

  -- Initialize with multiple entries
  __call = function(t, initialValues)
    for _, v in ipairs(initialValues) do
      table.insert(t, v) -- Triggers __newindex
    end
  end
})

-- BARS -- ENSURE EACH BAR HAS A UNIQUE NAME OR IT'LL FUCK UP BAD
bars({
  {
    name           = "Health",
    type           = "progress",
    settings       = {
      enabled             = false,
      color_col4          = 0xAA0000AA,
      icon_hex            = 0x060069E9,
      textAlignment_combo = { 2, "left", "center", "right" },
    },
    windowSettings = _imgui.ImGuiWindowFlags.NoInputs + _imgui.ImGuiWindowFlags.NoBackground,
    styleVar       = {
      { _imgui.ImGuiStyleVar.FrameBorderSize, 2 }
    },
    styleColor     = {
      { _imgui.ImGuiCol.Border, 0xFFFFFFFF }
    },
    max            = function() return vitals[VitalId.Health].Max end,
    value          = function() return vitals[VitalId.Health].Current end,
    text           = function() return "  " .. vitals[VitalId.Health].Current .. " / " .. vitals[VitalId.Health].Max end

  },
  {
    name           = "Stamina",
    type           = "progress",
    settings       = {
      enabled             = false,
      color_col4          = 0xAA00AAAA,
      icon_hex            = 0x060069E8,
      textAlignment_combo = { 2, "left", "center", "right" },
    },
    windowSettings = _imgui.ImGuiWindowFlags.NoInputs + _imgui.ImGuiWindowFlags.NoBackground,
    styleVar       = {
      { _imgui.ImGuiStyleVar.FrameBorderSize, 2 }
    },
    styleColor     = {
      { _imgui.ImGuiCol.Border, 0xFFFFFFFF }
    },
    max            = function() return vitals[VitalId.Stamina].Max end,
    value          = function() return vitals[VitalId.Stamina].Current end,
    text           = function() return "  " .. vitals[VitalId.Stamina].Current .. " / " .. vitals[VitalId.Stamina].Max end
  },
  {
    name           = "Mana",
    type           = "progress",
    settings       = {
      enabled             = false,
      color_col4          = 0xAAAA0000,
      icon_hex            = 0x060069EA,
      textAlignment_combo = { 2, "left", "center", "right" },
    },
    windowSettings = _imgui.ImGuiWindowFlags.NoInputs + _imgui.ImGuiWindowFlags.NoBackground,
    styleVar       = {
      { _imgui.ImGuiStyleVar.FrameBorderSize, 2 }
    },
    styleColor     = {
      { _imgui.ImGuiCol.Border, 0xFFFFFFFF }
    },
    max            = function() return vitals[VitalId.Mana].Max end,
    value          = function() return vitals[VitalId.Mana].Current end,
    text           = function() return "  " .. vitals[VitalId.Mana].Current .. " / " .. vitals[VitalId.Mana].Max end
  },
  {
    name = "Distance",
    type = "text",
    settings = {
      enabled = false,
      fontScale_flt = 1.5,
      icon_hex = 0x060064E5,
      minDistance_num = 35,
      minDistance_col4 = 0xFF00FF00,
      range1_num = 50,
      range1_col4 = 0xFFFFFFFF,
      maxDistance_num = 60,
    },
    windowSettings = _imgui.ImGuiWindowFlags.NoInputs + _imgui.ImGuiWindowFlags.NoBackground,
    styleColor = {
      { _imgui.ImGuiCol.Text, function(bar)
        local dist = tonumber(bar:text())
        if not dist then
          return 0xFFFFFFFF -- will not show
        elseif dist > (bar.settings.maxDistance_num or 9999) then
          return 0xFFFFFFFF -- will not show
        elseif dist > (bar.settings.range1_num or 9999) then
          return bar.settings.range1_col4
        elseif dist >= (bar.settings.minDistance_num or 0) then
          return bar.settings.minDistance_col4 --AABBGGRR, so red
        else
          return 0xFFFFFFFF                    -- doesn't matter but need to return something
        end
      end }
    },
    text = function(bar)
      if game.World.Selected == nil or game.World.Selected.ObjectClass ~= ObjectClass.Monster then return "" end
      local dist = acclient.Coordinates.Me.DistanceTo(acclient.Movement.GetPhysicsCoordinates(game.World.Selected.Id))
      if not bar.settings.minDistance_num then
        bar.settings.minDistance_num = 0
      end
      if not bar.settings.maxDistance_num then
        bar.settings.maxDistance_num = 9999
      end
      return dist > bar.settings.minDistance_num and dist < bar.settings.maxDistance_num and string.format("%.0f", dist) or
      ""
    end
  },
  {
    name = "bag_salvageme",
    type = "button",
    settings = {
      enabled = false,
      icon_hex = 9914,
      label_str = " ",
    },
    init = function(bar) bar:func() end,
    func = function(bar)
      sortbag(bar, "salvageme", game.Character, function()
        if not game.Character.GetFirstInventory("Ust") then
          print("No UST!")
          return
        else
          game.Character.GetFirstInventory("Ust").Use(genericActionOpts, function(res)
            for _, itemId in ipairs(game.World.Get(bar.sortBag).AllItemIds) do
              game.Actions.SalvageAdd(itemId, genericActionOpts, genericActionCallback)
            end

            for _, exBar in ipairs(bar.parent) do
              if exBar.name == "sort_salvagebag" and exBar.sortBag then
                for _, itemId in ipairs(game.World.Get(exBar.sortBag).AllItemIds) do
                  game.Actions.SalvageAdd(itemId, genericActionOpts, genericActionCallback)
                end
                break
              end
            end
            local opts = ActionOptions.new()
            opts.SkipChecks = true
            ---@diagnostic disable-next-line
            opts.TimeoutMilliseconds = 100
            ---@diagnostic disable-next-line
            opts.MaxRetryCount = 0
            game.Actions.Salvage(opts, genericActionCallback)
          end)
        end
      end)
    end,
    rightclick = function(bar)
      bar.sortBag = nil
    end
  },

  {
    name = "sort_trophybag",
    type = "button",
    settings = {
      enabled = false,
      icon_hex = 0x060011F7,
      label_str = "T    \n\n",
    },
    init = function(bar) bar:func() end,
    func = function(bar)
      sortbag(bar, "trophies", game.Character,
        function() --left click
          local count = 1
          local function stash(item)
            if item.ContainerId ~= bar.sortBag and string.find(item.Value(StringId.Use), "A Trophy Collector or Trophy Smith may be interested in this.") then
              game.Actions.ObjectMove(item.Id, bar.sortBag, 0, false, stagger(count), genericActionCallback)
              count = count + 1
            end
          end
          for i, item in ipairs(game.Character.Inventory) do
            if item.HasAppraisalData == false and item.ObjectClass == ObjectClass.Misc then
              game.Messages.Incoming.Item_SetAppraiseInfo.Until(function(e)
                if item.Id == e.Data.ObjectId then
                  stash(item)
                  ---@diagnostic disable-next-line
                  return true
                end
              end)
              item.Appraise()
            else
              stash(item)
            end
          end
        end)
    end,
    rightclick = function(bar)
      bar.sortBag = nil
    end
  },
  {
    name = "sort_salvagebag",
    type = "button",
    settings = {
      enabled = false,
      icon_hex = 0x060011F7,
      label_str = "S    \n\n",
    },
    init = function(bar) bar:func() end,
    func = function(bar)
      sortbag(bar, "salvage", game.Character, function()
        local count = 1
        for i, item in ipairs(game.Character.Inventory) do
          local salvage = (item.ObjectClass == ObjectClass.Salvage)
          if salvage and item.ContainerId ~= bar.sortBag then
            game.Actions.ObjectMove(item.Id, bar.sortBag, 0, false, stagger(count), genericActionCallback)
            count = count + 1
          end
        end
      end)
    end,
    rightclick = function(bar)
      bar.sortBag = nil
    end
  },
  {
    name = "sort_gembag",
    type = "button",
    settings = {
      enabled = false,
      icon_hex = 0x060011F7,
      label_str = "G    \n\n",
    },
    init = function(bar) bar:func() end,
    func = function(bar)
      sortbag(bar, "gems", game.Character, function()
        local count = 1
        for i, item in ipairs(game.Character.Inventory) do
          local gem = (item.ObjectClass == ObjectClass.Gem)
          if gem and item.ContainerId ~= bar.sortBag then
            game.Actions.ObjectMove(item.Id, bar.sortBag, 0, false, stagger(count), genericActionCallback)
            count = count + 1
          end
        end
      end)
    end,
    rightclick = function(bar)
      bar.sortBag = nil
    end
  },
  {
    name = "sort_compbag",
    type = "button",
    settings = {
      enabled = false,
      icon_hex = 0x060011F7,
      label_str = "C    \n\n",
    },
    init = function(bar) bar:func() end,
    func = function(bar)
      sortbag(bar, "comps", game.Character, function()
        local count = 1
        for i, item in ipairs(game.Character.Inventory) do
          local comp = (item.ObjectClass == ObjectClass.SpellComponent) and not string.find(item.Name, "Pea")
          if comp and item.ContainerId ~= bar.sortBag then
            game.Actions.ObjectMove(item.Id, bar.sortBag, 0, false, stagger(count), genericActionCallback)
            count = count + 1
          end
        end
      end)
    end,
    rightclick = function(bar)
      bar.sortBag = nil
    end
  },
  {
    name = "sort_vendorbag",
    type = "button",
    settings = {
      enabled = false,
      icon_hex = 0x060011F7,
      label_str = "V    \n\n",
    },
    init = function(bar) bar:func() end,
    func = function(bar)
      sortbag(bar, "vendor", game.Character, function()
        local count = 1
        for i, item in ipairs(game.Character.Inventory) do
          local trash = (string.find(item.Name, "Mana Stone") or string.find(item.Name, "Scroll") or string.find(item.Name, "Lockpick")) and
              item.Burden <= 50 and item.Value(IntId.Value) >= 2000
          if trash and item.ContainerId ~= bar.sortBag then
            game.Actions.ObjectMove(item.Id, bar.sortBag, 0, false, stagger(count), genericActionCallback)
            count = count + 1
          end
        end
      end)
    end,
    rightclick = function(bar)
      bar.sortBag = nil
    end
  },
  {
    name = "attackpower",
    type = "button",
    settings = {
      enabled = false,
      icon_hex = 0x06006084,
      attackBar_pct = { 0.51, 0.01, 1 }
    },
    text = function(bar) return "AP=0.51" end,
    func = function(bar)
      game.Actions.InvokeChat("/vt setattackbar " .. bar.settings.attackBar_pct[1])
    end
  },
  {
    name = "bank_peas",
    type = "button",
    settings = {
      enabled = false,
      icon_hex = 0x06006727,
    },
    text = function(bar) return bar.sortBag and "Store Peas" or "Find Pea Bag" end,
    init = function(bar)
      if game.World.OpenContainer and game.World.OpenContainer.Container and game.World.OpenContainer.Container.Name == "Avaricious Golem" then
        bar.hud.Visible = true
      else
        bar.hud.Visible = false
      end
      game.Messages.Incoming.Item_OnViewContents.Add(function(e)
        local container = game.World.Get(e.Data.ObjectId)
        if container and container.Name == "Avaricious Golem" then
          bar.hud.Visible = true
        end
      end)
      game.Messages.Incoming.Item_StopViewingObjectContents.Add(function(e)
        local container = game.World.Get(e.Data.ObjectId)
        if container and container.Name == "Avaricious Golem" then
          bar.hud.Visible = false
        end
      end)
    end,
    func = function(bar)
      if not game.World.OpenContainer or not game.World.OpenContainer.Container or not game.World.OpenContainer.Container.Name == "Avaricious Golem" then
        bar.hud.Visible = false
        return
      end
      sortbag(bar, "peas", game.World.OpenContainer.Container, function()
        local count = 1
        for i, item in ipairs(game.Character.Inventory) do
          local pea = string.find(item.Name, "Pea")
          if pea and item.ObjectClass == ObjectClass.SpellComponent and item.ContainerId ~= bar.sortBag then
            game.Actions.ObjectMove(item.Id, bar.sortBag, 0, false, stagger(count), genericActionCallback)
            count = count + 1
          end
        end
      end)
    end,
    rightclick = function(bar)
      bar.sortBag = nil
    end
  },
  {
    name = "render_damageDealt",
    settings = {
      enabled = false,
      icon_hex = 0x060028FC,
      fontScaleMin_flt = 2,
      fontScaleMax_flt = 3,
      fontScaleCrit_flt = 4,
      fontColorPositive_col3 = 0xFFFFFF,
      fontColorNegative_col3 = 0x0000FF,
      fadeDuration_num = 2, -- How long the text stays on screen
      floatSpeed_num = 1,   -- Speed of the floating text
    },
    entries = {},           -- Table to store damages
    runningSum = 0,         -- Sum of all values (for average calculation)
    runningCount = 0,       -- Count of all values (for average calculation)

    init = function(bar)
      -- Set window properties
      bar.windowSettings =
          _imgui.ImGuiWindowFlags.NoInputs +
          _imgui.ImGuiWindowFlags.NoBackground

      ---@diagnostic disable:param-type-mismatch

      local function hpExtractor(e)
        ---@diagnostic disable:undefined-field
        ---@diagnostic disable:inject-field

        local damage = nil
        local crit = false
        if e.Data.Name ~= nil then
          damage = e.Data.DamageDone
        elseif (e.Data.Type == LogTextType.Magic or e.Data.Type == LogTextType.CombatSelf) then
          local r = Regex.new(
            "^(?<crit>Critical hit!  )?(?:[^!]+! )*(?:(?:You (?:eradicate|wither|twist|scar|hit|mangle|slash|cut|scratch|gore|impale|stab|nick|crush|smash|bash|graze|incinerate|burn|scorch|singe|freeze|frost|chill|numb|dissolve|corrode|sear|blister|blast|jolt|shock|spark) (?<mobName>.*?) for (?<damage>[\\d,]+) points (?:.*))|(?:With .*? you (?:drain|exhaust|siphon|deplete) (?<drainDamage>[\\d,]+) points of health from (?<magicMobName>.*?))\\.)$"
          )
          local m = r.Match(e.Data.Text)
          if (m.Success) then
            if m.Groups["crit"].Success then
              crit = true
            end
            if m.Groups["damage"].Success then
              damage = m.Groups["damage"].Value
            elseif m.Groups["drainDamage"].Value then
              damage = m.Groups["drainDamage"].Value
            end
          end
        end
        ---@diagnostic enable:undefined-field
        ---@diagnostic enable:inject-field
        if damage ~= nil then
          table.insert(bar.entries, {
            text = damage .. (crit and "!" or ""),
            value = math.abs(tonumber(damage or 0)), -- Store the absolute value for scaling
            positive = tonumber(damage) > 0,
            time = os.clock(),
          })
          -- Update the running sum and count
          bar.runningSum = bar.runningSum + math.abs(tonumber(damage or 0))
          bar.runningCount = bar.runningCount + 1
        end
      end

      game.Messages.Incoming.Combat_HandleAttackerNotificationEvent.Add(hpExtractor)
      game.Messages.Incoming.Communication_TextboxString.Add(hpExtractor)

      game.Messages.Incoming.Combat_HandleEvasionAttackerNotificationEvent.Add(function(e)
        table.insert(bar.entries, {
          text = "Evade",
          positive = false,
          time = os.clock(),
        })
      end)
      game.Messages.Incoming.Combat_HandleVictimNotificationEventOther.Add(function(e)
        if game.Character.Weenie.Vitals[VitalId.Health].Current ~= 0 then --initial lazy check it's not me who died. i do not think this would work
          table.insert(bar.entries, {
            text = "RIP",
            positive = false,
            time = os.clock()
          })
        end
      end)
      ---@diagnostic enable:param-type-mismatch
    end,

    render = renderEvent
  },
  {
    name = "render_damageTaken",
    settings = {
      enabled = false,
      icon_hex = 0x060028FD,
      fontScaleMin_flt = 2,
      fontScaleMax_flt = 3,
      fontColorPositive_col3 = 0x00FF00,
      fontColorNegative_col3 = 0x0000FF,
      fadeDuration_num = 2, -- How long the text stays on screen
      floatSpeed_num = 1,   -- Speed of the floating text
    },
    entries = {},           -- Table to store hp changes
    runningSum = 0,         -- Sum of all values (for average calculation)
    runningCount = 0,       -- Count of all values (for average calculation)

    init = function(bar)
      -- Set window properties
      bar.windowSettings =
          _imgui.ImGuiWindowFlags.NoInputs +
          _imgui.ImGuiWindowFlags.NoBackground

      -- Subscribe to stamina change events
      game.Character.OnVitalChanged.Add(function(changedVital)
        if changedVital.Type == VitalId.Health then
          local delta = changedVital.Value - changedVital.OldValue
          table.insert(bar.entries, {
            text = tostring(delta),
            value = math.abs(delta), -- Store the absolute value for scaling
            positive = delta > 0,
            time = os.clock(),
          })
          -- Update the running sum and count
          bar.runningSum = bar.runningSum + math.abs(delta)
          bar.runningCount = bar.runningCount + 1
        end
      end)
    end,

    render = renderEvent
  },
  {
    name = "^mobPointer",
    settings = {
      enabled = false,
      icon_hex = 0x060069F6
    },
    init = function(bar)
      bar.mobToSearch = bar.mobToSearch or ""

      bar.findMobByName = function(name)
        if name == "" then
          return nil
        end

        local matchingMob = nil
        local minDistance = math.huge

        for _, object in ipairs(game.World.GetLandscape()) do
          if string.find(string.lower(object.Name), string.lower(name)) then
            -- print("Found Mob: "..object.Name)
            local distance = acclient.Coordinates.Me.DistanceTo(acclient.Movement.GetPhysicsCoordinates(object.Id))
            if distance < minDistance and (matchingMob == nil or distance < matchingMob.Distance) then
              minDistance = distance
              matchingMob = {
                Id = object.Id,
                Name = object.Name,
                Distance = distance,
                Coordinates = acclient.Movement.GetPhysicsCoordinates(object.Id),
              }
              --  print("Matching Mob: "..matchingMob.Name.."("..matchingMob.Id.."): Distance="..distance)
            end
          end
        end
        return matchingMob
      end

      bar.renderArrowToMob = function(currentMob, distance)
        ---@diagnostic disable:undefined-field
        local angleToMob = math.rad(acclient.Coordinates.Me.HeadingTo(acclient.Movement.GetPhysicsCoordinates(currentMob.Id)))
        ---@diagnostic enable:undefined-field

        -- Get the relative heading: the difference between your current heading and the heading to the mob
        local relativeAngle = angleToMob - math.rad(acclient.Movement.Heading - 270)

        -- Normalize the angle to be between 0 and 2*pi (if necessary)
        if relativeAngle < 0 then
          relativeAngle = relativeAngle + 2 * math.pi
        elseif relativeAngle > 2 * math.pi then
          relativeAngle = relativeAngle - 2 * math.pi
        end

        -- Get window position and draw list
        local windowPos = ImGui.GetWindowPos()
        local drawList = ImGui.GetWindowDrawList()

        -- Get the window size
        local windowSize = ImGui.GetWindowSize()

        -- Estimate the height of previous elements (text and input)
        local previousElementsHeight = 50 -- Adjust this based on your actual UI layout

        -- Define the center of the remaining content area
        local centerX = windowPos.X + windowSize.X / 2
        local centerY = windowPos.Y + previousElementsHeight + (windowSize.Y - previousElementsHeight) / 2

        -- Calculate arrow dimensions based on available space
        local arrowLength = math.min(windowSize.Y - previousElementsHeight, windowSize.X) * 0.8
        local arrowWidth = arrowLength * 0.8

        -- Calculate arrow points
        local tipX = centerX + math.cos(relativeAngle) * (arrowLength / 2)
        local tipY = centerY + math.sin(relativeAngle) * (arrowLength / 2)

        local baseAngle1 = relativeAngle + math.pi * 5 / 6
        local baseAngle2 = relativeAngle - math.pi * 5 / 6
        local baseX1 = centerX + math.cos(baseAngle1) * (arrowWidth / 2)
        local baseY1 = centerY + math.sin(baseAngle1) * (arrowWidth / 2)
        local baseX2 = centerX + math.cos(baseAngle2) * (arrowWidth / 2)
        local baseY2 = centerY + math.sin(baseAngle2) * (arrowWidth / 2)
        
        -- Define the bounding box for the arrow
        local minX = math.min(tipX, baseX1, baseX2)
        local minY = math.min(tipY, baseY1, baseY2)
        local maxX = math.max(tipX, baseX1, baseX2)
        local maxY = math.max(tipY, baseY1, baseY2)

        -- Create an invisible button over the arrow area
        ImGui.SetCursorScreenPos(Vector2.new(minX, minY))
        ImGui.InvisibleButton("ArrowClick", Vector2.new(maxX - minX, maxY - minY))

        if ImGui.IsItemClicked() then
            game.Actions.ObjectSelect(currentMob.Id)
            --print("Arrow clicked! Target mob ID: " .. currentMob.Id)
        end

        -- Color interpolation
        local function interpolateColor(dist)
          local r, g = 255, 0  -- Start with red (255, 0, 0)

          if dist > 80 then
            dist = 80
          elseif dist < 5 then
            dist = 5
          end

          if dist > 40 then
            -- Fade from red to yellow (255,0,0 → 255,255,0)
            local factor = (dist - 40) / 40
            g = math.floor(255 * (1 - factor))  -- Increase green
          else
            -- Fade from yellow to green (255,255,0 → 0,255,0)
            local factor = dist / 40
            r = math.floor(255 * factor)  -- Decrease red
            g = 255
          end

          -- Convert RGB to 0xAARRGGBB (with full opacity)
          return 0xFF000000 + (r * 0x1) + (g * 0x100)
        end

        local arrowColor = interpolateColor(distance)

        -- Draw the arrow
        drawList.AddTriangleFilled(
          Vector2.new(tipX, tipY),
          Vector2.new(baseX1, baseY1),
          Vector2.new(baseX2, baseY2),
          arrowColor
        )

        -- Add an outline
        drawList.AddTriangle(
          Vector2.new(tipX, tipY),
          Vector2.new(baseX1, baseY1),
          Vector2.new(baseX2, baseY2),
          0xFFFFFFFF, -- White outline
          1.0         -- Line thickness
        )
      end

      game.World.OnObjectCreated.Add(function(e)
        if bar.mobToSearch and bar.mobToSearch ~= "" and string.find(string.lower(game.World.Get(e.ObjectId).Name), string.lower(bar.mobToSearch)) then
          if game.Character.InPortalSpace then
            game.Character.OnPortalSpaceExited.Once(function()
              bar.currentMob = bar.findMobByName(bar.mobToSearch)
            end)
          else
            sleep(100)
            bar.currentMob = bar.findMobByName(bar.mobToSearch)
          end
        end
      end)

      game.Messages.Incoming.Inventory_PickupEvent.Add(function(e)
        if bar.currentMob ~= nil and e.Data.ObjectId == bar.currentMob.Id then
          bar.currentMob = nil
        end
      end)

      game.World.OnObjectReleased.Add(function(e)
        ---@diagnostic disable-next-line
        if bar.currentMob and e.ObjectId == bar.currentMob.Id then
          bar.currentMob = bar.findMobByName(bar.mobToSearch)
        end
      end)
    end,
    render = function(bar)
      ImGui.Text("  ")
      ImGui.SameLine()

      -- Input box for mob name
      ImGui.PushItemWidth(-1)
      local inputChanged, newMobName = ImGui.InputText("###MobNameInput", bar.mobToSearch, 24,
        _imgui.ImGuiInputTextFlags.AutoSelectAll)
      ImGui.PopItemWidth()

      local isInputActive = ImGui.IsItemActive()

      -- Placeholder text
      if bar.mobToSearch == "" and not isInputActive then
        local inputPos = ImGui.GetItemRectMin()
        local textSize = ImGui.CalcTextSize("Mob Name")
        local textPos = Vector2.new(inputPos.X + 5, inputPos.Y + (ImGui.GetItemRectSize().Y - textSize.Y) * 0.5)

        ImGui.PushStyleColor(_imgui.ImGuiCol.Text, 0xFF888888)
        ImGui.SetCursorScreenPos(textPos)
        ImGui.Text("Mob Name")
        ImGui.PopStyleColor()
        ImGui.SetCursorPosY(ImGui.GetCursorPosY() - ImGui.GetTextLineHeight())
      end

      -- Check if Enter was pressed while the input box was focused
      if inputChanged and ImGui.IsKeyPressed(_imgui.ImGuiKey.Enter) then
        -- Update mobToSearch and find the mob when Enter is pressed
        bar.mobToSearch = newMobName or ""
        SaveBarSettings(bar, "mobToSearch", newMobName)
        bar.currentMob = bar.findMobByName(bar.mobToSearch)
      end

      -- Only add NewLine if the input is not active
      if not isInputActive and (bar.mobToSearch == nil or bar.mobToSearch == "") then
        ImGui.Text(" ")
      end

      if bar.currentMob then
        local distance = acclient.Coordinates.Me.DistanceTo(bar.currentMob.Coordinates)
        ImGui.Text(string.format("  %s (%.2f m)", bar.currentMob.Name,distance))
        bar.renderArrowToMob(bar.currentMob,distance)
      else
        ImGui.Text("  No matching mob detected")
      end
    end
  },
  {
    name = "BlueAetheria", --important, must be correctly capitalized for enum to work
    settings = {
      enabled = false,
      icon_hex = 0x0600679F,
      fontScale_flt = 2,
    },
    init = function(bar)
      if game.ServerName ~= "Daralet" then
        print(bar.name .. " disabled due to unusability when not on Daralet")
        bar.render = function() end
        return
      end
      local function scan()
        for _, item in ipairs(game.Character.Equipment) do
          bar.id = nil
          if item.Value(IntId.CurrentWieldedLocation) == EquipMask[bar.name] then
            bar.id = item.Id
            break
          end
        end
      end
      scan()
      ---@param cooldownChanged SharedCooldownsChangedEventArgs
      game.Character.OnSharedCooldownsChanged.Add(function(cooldownChanged)
        if bar.id and cooldownChanged.Cooldown.ObjectId == bar.id then
          bar.cooldown = cooldownChanged.Cooldown.ExpiresAt
        end
      end)
      game.Messages.Incoming.Qualities_UpdateInstanceID.Add(function(updateInstance)
        local objectId = updateInstance.Data.ObjectId
        local weenie = game.World.Get(objectId)
        if not weenie or weenie.Value(IntId.ValidLocations) ~= EquipMask[bar.name] then
          return
        elseif updateInstance.Data.Key == InstanceId.Container and updateInstance.Data.Value == game.CharacterId then
          sleep(333)
          scan()
        elseif (updateInstance.Data.Key == InstanceId.Wielder and updateInstance.Data.Value == 0) then
          sleep(333)
          scan()
        end
      end)
    end,
    render = function(bar)
      if bar.id and game.World.Exists(bar.id) then
        if bar.cooldown then
          local rem = (bar.cooldown - DateTime.UtcNow).TotalSeconds
          if rem > 0 then
            bar.settings.label_str = string.format("%.1f", rem)
          else
            bar.cooldown = nil
            bar.settings.label_str = nil
          end
        end
        local aetheria = game.World.Get(bar.id)
        local underlay = aetheria.Value(DataId.IconUnderlay)
        if underlay ~= 0 then
          local cursorPos = ImGui.GetCursorScreenPos()
          DrawIcon(bar, underlay)
          ImGui.SetCursorScreenPos(cursorPos)
        end
        local icon = aetheria.Value(DataId.Icon)
        DrawIcon(bar, icon)
      else
        if not DrawIcon(bar, 0x06006C0A) then
          ImGui.Text("Missing\nTexture!")
        end
      end
    end,
  },
  {
    name = "YellowAetheria", --important, must be correctly capitalized for enum to work
    settings = {
      enabled = false,
      icon_hex = 0x060067A2,
      fontScale_flt = 2
    },
    init = function(bar)
      if game.ServerName ~= "Daralet" then
        print(bar.name .. " disabled due to unusability when not on Daralet")
        bar.render = function() end
        return
      end
      local function scan()
        for _, item in ipairs(game.Character.Equipment) do
          bar.id = nil
          if item.Value(IntId.CurrentWieldedLocation) == EquipMask[bar.name] then
            bar.id = item.Id
            break
          end
        end
      end
      scan()
      game.Character.OnSharedCooldownsChanged.Add(function(cooldownChanged)
        if bar.id and cooldownChanged.Cooldown.ObjectId == bar.id then
          bar.cooldown = cooldownChanged.Cooldown.ExpiresAt
        end
      end)
      game.Messages.Incoming.Qualities_UpdateInstanceID.Add(function(updateInstance)
        local objectId = updateInstance.Data.ObjectId
        local weenie = game.World.Get(objectId)
        if not weenie or weenie.Value(IntId.ValidLocations) ~= EquipMask[bar.name] then
          return
        elseif updateInstance.Data.Key == InstanceId.Container and updateInstance.Data.Value == game.CharacterId then
          sleep(333)
          scan()
        elseif (updateInstance.Data.Key == InstanceId.Wielder and updateInstance.Data.Value == 0) then
          sleep(333)
          scan()
        end
      end)
    end,
    render = function(bar)
      if bar.id and game.World.Exists(bar.id) then
        if bar.cooldown then
          local rem = (bar.cooldown - DateTime.UtcNow).TotalSeconds
          if rem > 0 then
            bar.settings.label_str = string.format("%.1f", rem)
          else
            bar.cooldown = nil
            bar.settings.label_str = nil
          end
        end
        local aetheria = game.World.Get(bar.id)
        local underlay = aetheria.Value(DataId.IconUnderlay)
        if underlay ~= 0 then
          local cursorPos = ImGui.GetCursorScreenPos()
          DrawIcon(bar, underlay)
          ImGui.SetCursorScreenPos(cursorPos)
        end
        local icon = aetheria.Value(DataId.Icon)
        DrawIcon(bar, icon)
      else
        DrawIcon(bar, 0x06006C0A)
      end
    end,
  },
  {
    name = "equipmentManager",
    settings = {
      enabled = false,
      icon_hex = 0x060018FA,
    },
    styleVar = {
      { _imgui.ImGuiStyleVar.FramePadding, Vector2.new(2, 2) },
      { _imgui.ImGuiStyleVar.ItemSpacing,  Vector2.new(2, 2) }
    },
    shallowcopy = function(orig)
      local orig_type = type(orig)
      local copy
      if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
          copy[orig_key] = orig_value
        end
      else -- number, string, boolean, etc
        copy = orig
      end
      return copy
    end,
    init = function(bar)
      function table.contains(tbl, value)
        for _, v in pairs(tbl) do
          if v == value then
            return true
          end
        end
        return false
      end

      ---@param wo WorldObject
      bar.GetItemTypeUnderlay = function(wo)
        local underlay = wo.Value(DataId.IconUnderlay)
        if underlay ~= 0 then
          return underlay
        elseif wo.ObjectType == ObjectType.MeleeWeapon then
          return 0x060011CB
        elseif wo.ObjectType == ObjectType.Armor then
          return 0x060011CF
        elseif wo.ObjectType == ObjectType.Clothing then
          return 0x060011F3
        elseif wo.ObjectType == ObjectType.Container then
          return 0x060011CE
        elseif wo.ObjectType == ObjectType.Creature then
          return 0x060011D1
        elseif wo.ObjectType == ObjectType.Food then
          return 0x060011CC
        elseif wo.ObjectType == ObjectType.Gem then
          return 0x060011D3
        elseif wo.ObjectType == ObjectType.Jewelry then
          if wo.Value(IntId.SharedCooldown) > 0 then
            return 0x060011CF
          end
          return 0x060011D5
        elseif wo.ObjectType == ObjectType.Money then
          return 0x060011F4
        elseif wo.ObjectType == ObjectType.MissileWeapon then
          return 0x060011D2
        elseif wo.ObjectType == ObjectType.Useless then
          return 0x060011D0
        elseif wo.ObjectType == ObjectType.SpellComponents then
          return 0x060011CD
        elseif wo.ObjectType == ObjectType.Service then
          return 0x06005E23
        else
          return 0x060011D4
        end
      end

      bar.equipMask = {}
      table.insert(bar.equipMask, 1, "Necklace")
      table.insert(bar.equipMask, 2, "Trinket")
      table.insert(bar.equipMask, 3, "LeftBracelet")
      table.insert(bar.equipMask, 4, "LeftRing")
      table.insert(bar.equipMask, 5, "Shield")
      table.insert(bar.equipMask, 6, "None")
      table.insert(bar.equipMask, 7, "UpperArms")
      table.insert(bar.equipMask, 8, "LowerArms")
      table.insert(bar.equipMask, 9, "Hands")
      table.insert(bar.equipMask, 10, "None")
      table.insert(bar.equipMask, 11, "Head")
      table.insert(bar.equipMask, 12, "Chest")
      table.insert(bar.equipMask, 13, "Abdomen")
      table.insert(bar.equipMask, 14, "None")
      table.insert(bar.equipMask, 15, "None")
      table.insert(bar.equipMask, 16, "BlueAetheria")
      table.insert(bar.equipMask, 17, "None")
      table.insert(bar.equipMask, 18, "UpperLegs")
      table.insert(bar.equipMask, 19, "LowerLegs")
      table.insert(bar.equipMask, 20, "Feet")
      table.insert(bar.equipMask, 21, "YellowAetheria")
      table.insert(bar.equipMask, 22, "None")
      table.insert(bar.equipMask, 23, "RightBracelet")
      table.insert(bar.equipMask, 24, "RightRing")
      table.insert(bar.equipMask, 25, "Wand")
      table.insert(bar.equipMask, 26, "RedAetheria")
      table.insert(bar.equipMask, 27, "None") --?
      table.insert(bar.equipMask, 28, "ChestUnderwear")
      table.insert(bar.equipMask, 29, "UpperLegsUnderwear")
      table.insert(bar.equipMask, 30, "Ammunition")

      bar.slots = {}
      bar.rememberedSlots = {}

      bar.profiles = bar.profiles or {}

      bar.scan = function(bar)
        bar.slots = {}
        local filledSlots = bar.shallowcopy(bar.equipMask)
        for _, equipment in ipairs(game.Character.Equipment) do
          for i, slot in ipairs(bar.equipMask) do
            if slot ~= "None" and equipment.CurrentWieldedLocation + EquipMask[slot] == equipment.CurrentWieldedLocation then
              bar.slots[slot] = equipment
              filledSlots[i] = "FILLED"
            elseif i == 25 then
              if equipment.CurrentWieldedLocation + EquipMask["MeleeWeapon"] == equipment.CurrentWieldedLocation then
                bar.slots["MeleeWeapon"] = equipment
                filledSlots[i] = "FILLED"
              elseif equipment.CurrentWieldedLocation + EquipMask["MissileWeapon"] == equipment.CurrentWieldedLocation then
                bar.slots["MissileWeapon"] = equipment
                filledSlots[i] = "FILLED"
              end
            end
          end
        end
        for i, slot in ipairs(filledSlots) do
          if filledSlots[i] ~= "FILLED" then
            bar.slots[filledSlots[i]] = filledSlots[i]
          end
        end


        if bar.activeProfile then
          for slot, gear in pairs(bar.activeProfile.gear) do
            if (bar.slots[slot] == nil or bar.slots[slot].Id ~= gear) then
              bar.activeProfile = nil
              break
            end
          end
        end
      end
      bar:scan()

      ---@param updateInstance Qualities_UpdateInstanceID_S2C_EventArgs
      bar.watcher = function(updateInstance)
        local objectId = updateInstance.Data.ObjectId
        local weenie = game.World.Get(objectId)
        if not weenie then
          return
        elseif updateInstance.Data.Key == InstanceId.Container and updateInstance.Data.Value == game.CharacterId then
          for _ in game.ActionQueue.ImmediateQueue do
            return
          end
          for _ in game.ActionQueue.Queue do
            return
          end
          sleep(333)
          bar:scan()
        elseif (updateInstance.Data.Key == InstanceId.Wielder) then
          for _ in game.ActionQueue.ImmediateQueue do
            return
          end
          for _ in game.ActionQueue.Queue do
            return
          end
          sleep(333)
          bar:scan()
        end
      end
      game.Messages.Incoming.Qualities_UpdateInstanceID.Add(bar.watcher)
    end,
    resetRemembered = function(bar)
      bar.rememberedSlots = {}
    end,
    showGear = function(bar)
      local style = ImGui.GetStyle()
      local miscPadding = style.CellPadding + style.FramePadding + style.ItemSpacing + style.WindowPadding
      
      for _, profile in ipairs(bar.profiles) do
        if profile.name == bar.profileName then
          if not profile.gear then
            bar:resetRemembered()
          else
            bar.rememberedSlots = profile.gear
            local count=0
            bar.dontSave = bar.dontSave or bar.shallowcopy(profile.gear)
          end
        end
      end

      local windowPos = ImGui.GetWindowPos()
      local shiftStart = { 5, 1, 1, 2, 5, 5 }
      local contentSpace = ImGui.GetContentRegionAvail() -
          Vector2.new(0, ImGui.GetTextLineHeight() + miscPadding.Y) -- for buttons and inputbox
      local cellSize = Vector2.new(contentSpace.X / 6, contentSpace.Y / 5.5)
      local drawlist = ImGui.GetWindowDrawList()
      for x = 1, 6, 1 do
        for y = 1, 5, 1 do
          local index = (x - 1) * 5 + y
          local startX = windowPos.X + (x - 1) * cellSize.X
          local startY = windowPos.Y + (y - 1) * cellSize.Y + (y >= shiftStart[x] and cellSize.Y / 2 or 0)
          local start = Vector2.new(startX, startY)
          local slot = bar.equipMask[index]
          if index == 25 and bar.slots[slot] == nil then
            if bar.slots["MeleeWeapon"] ~= nil then
              slot = "MeleeWeapon"
            elseif bar.slots["MissileWeapon"] ~= nil then
              slot = "MissileWeapon"
            end
          end
          if slot ~= "None" then
            drawlist.AddRect(start, start + cellSize, 0xFFFFFFFF)
          end
          drawlist.AddRectFilled(start, start + cellSize, 0x88000000)

          local slottedItem = bar.slots[slot] or
            (slot == "MeleeWeapon" and (bar.slots["Wand"] or bar.slots["MissileWeapon"])) or
            (slot == "MissleWeapon" and (bar.slots["Wand"] or bar.slots["MeleeWeapon"]))
          
          if slottedItem and slottedItem ~= slot then
            ImGui.SetCursorScreenPos(start)
            DrawIcon(bar, bar.GetItemTypeUnderlay(slottedItem), cellSize, function()
              if bar.rememberedSlots[slot] == slottedItem.Id then
                if not (string.find(slot, "Ring") or string.find(slot, "Bracelet") or string.find(slot, "Weapon") or string.find(slot, "Shield")) then
                  for i, eqslot in ipairs(bar.equipMask) do
                    if eqslot ~= "None" and slottedItem.Value(IntId.ValidLocations) + EquipMask[eqslot] == slottedItem.Value(IntId.ValidLocations) then
                      bar.rememberedSlots[eqslot] = nil
                    end
                  end
                else
                  bar.rememberedSlots[slot] = nil
                end
              else
                if not (string.find(slot, "Ring") or string.find(slot, "Bracelet") or string.find(slot, "Weapon") or string.find(slot, "Shield")) then
                  for i, eqslot in ipairs(bar.equipMask) do
                    if eqslot ~= "None" and slottedItem.Value(IntId.ValidLocations) + EquipMask[eqslot] == slottedItem.Value(IntId.ValidLocations) then
                      bar.rememberedSlots[eqslot] = slottedItem.Id
                    end
                  end
                else
                  bar.rememberedSlots[slot] = slottedItem.Id
                end
              end
            end)
            ImGui.SetCursorScreenPos(start)
            DrawIcon(bar, bar.slots[slot].Value(DataId.Icon), cellSize)
            if bar.rememberedSlots[slot] == slottedItem.Id then
              drawlist.AddRectFilled(start, start + cellSize, 0x8800FF00)
            elseif (bar.rememberedSlots[slot] and slottedItem.Id ~= bar.rememberedSlots[slot]) or
                (({ Wand = true, MissileWeapon = true, MeleeWeapon = true })[slot] and 
                ((bar.rememberedSlots["Wand"] and bar.rememberedSlots["Wand"] ~= slottedItem.Id) or 
                (bar.rememberedSlots["MeleeWeapon"] and bar.rememberedSlots["MeleeWeapon"] ~= slottedItem.Id) or 
                (bar.rememberedSlots["MissileWeapon"] and bar.rememberedSlots["MissileWeapon"] ~= slottedItem.Id))) then
              drawlist.AddRectFilled(start, start + cellSize, 0x880000FF)
            end
          elseif bar.rememberedSlots[slot] and bar.rememberedSlots[slot] ~= slot then
            drawlist.AddRectFilled(start, start + cellSize, 0x880000FF)
          elseif slottedItem == slot and slot ~= "None" then
            ImGui.SetCursorScreenPos(start)
            local mouse = ImGui.GetMousePos()
            local isHovered = mouse.X >= start.X and mouse.X <= start.X + cellSize.X and
                mouse.Y >= start.Y and mouse.Y <= start.Y + cellSize.Y

            -- Handle input
            if isHovered and ImGui.IsMouseClicked(0) then
              if bar.rememberedSlots[slot] == slot then
                bar.rememberedSlots[slot] = nil
              else
                bar.rememberedSlots[slot] = slot
              end
            end

            if bar.rememberedSlots[slot] == slot then
              drawlist.AddRectFilled(start, start + cellSize, 0x8800FF00)
            elseif bar.rememberedSlots[slot] ~= nil then
              drawlist.AddRectFilled(start, start + cellSize, 0x880000FF)
            end
            ImGui.InvisibleButton("##" .. slot, cellSize)
          end
        end
      end
      ImGui.SetCursorScreenPos(windowPos + Vector2.new(0, cellSize.Y * 5.5))
      if ImGui.Button("Save Gear", Vector2.new(ImGui.GetWindowWidth() / 3 - miscPadding.X, ImGui.GetTextLineHeight()) + miscPadding) then
        for _, profile in ipairs(bar.profiles) do
          if profile.name == bar.profileName then
            bar.profiles[_] = nil
          end
        end
        local profile = { name = bar.profileName, gear = bar.rememberedSlots }
        table.insert(bar.profiles, profile)
        bar.activeProfile = profile
        SaveBarSettings(bar, "profiles", bar.profiles)
        bar.dontSave=nil
        bar:resetRemembered()
        bar.imguiReset = true
        bar.renderContext = "showProfilesCtx"
        bar.profileName = ""
        bar.render = bar.showProfiles
      end
      ImGui.SameLine()
      if ImGui.Button("Don't Save", Vector2.new(ImGui.GetWindowWidth() / 3 - miscPadding.X, ImGui.GetTextLineHeight()) + miscPadding) then
        for _, profile in ipairs(bar.profiles) do
          if profile.name == bar.profileName then
            profile.gear=bar.dontSave
          end
        end
        bar.dontSave=nil
        bar:resetRemembered()
        bar.imguiReset = true
        bar.renderContext = "showProfilesCtx"
        bar.profileName = ""
        bar.render = bar.showProfiles
      end
      ImGui.SameLine()
      if ImGui.Button("Delete", Vector2.new(ImGui.GetWindowWidth() / 3 - miscPadding.X, ImGui.GetTextLineHeight()) + miscPadding) then
        local profilesCopy = {}
        for _, profile in ipairs(bar.profiles) do
          if profile.name ~= bar.profileName then
            table.insert(profilesCopy, profile)
          end
        end
        bar.profiles = profilesCopy
        SaveBarSettings(bar, "profiles", bar.profiles)
        bar.dontSave=nil
        bar:resetRemembered()
        bar.imguiReset = true
        bar.renderContext = "showProfilesCtx"
        bar.profileName = ""
        bar.render = bar.showProfiles
      end
    end,
    showProfiles = function(bar)
      local windowSize = ImGui.GetContentRegionAvail()
      local style = ImGui.GetStyle()
      local miscPadding = style.CellPadding + style.FramePadding + style.ItemSpacing + style.WindowPadding

      ImGui.PushItemWidth(-1)
      local inputChanged
      inputChanged, bar.profileName = ImGui.InputText("##ProfileName", bar.profileName or "", 12,
        _imgui.ImGuiInputTextFlags.None)
      ImGui.PopItemWidth()

      local isInputActive = ImGui.IsItemActive()
      if bar.profileName == "" and not isInputActive then
        local inputPos = ImGui.GetItemRectMin()
        local textSize = ImGui.CalcTextSize("Profile Name")
        local textPos = Vector2.new(inputPos.X + 5, inputPos.Y + (ImGui.GetItemRectSize().Y - textSize.Y) * 0.5)

        ImGui.PushStyleColor(_imgui.ImGuiCol.Text, 0xFF888888)
        ImGui.SetCursorScreenPos(textPos)
        ImGui.Text("Profile Name")
        ImGui.PopStyleColor()
        ImGui.SetCursorPosY(ImGui.GetCursorPosY() - ImGui.GetTextLineHeight())
      end

      -- Only add NewLine if the input is not active
      if not isInputActive and (bar.profileName == "") then
        ImGui.NewLine()
      end

      ImGui.PushStyleColor(_imgui.ImGuiCol.Button, 0xFF333333)
      if ImGui.Button((bar.edit or "Create Profile") .. "##attemptNewProfile", Vector2.new(windowSize.X, ImGui.GetTextLineHeight()) + miscPadding) then
        if bar.profileName ~= "" then
          bar.imguiReset = true
          bar.renderContext = "showGearCtx"
          bar:scan()
          bar.render = bar.showGear
        else
          print("Invalid profile name")
        end
      end
      ImGui.PopStyleColor()

      bar.edit = "Create Profile"
      for _, profile in ipairs(bar.profiles) do
        if profile.name == bar.profileName then
          bar.edit = "Edit Profile"
          break
        end
      end

      for _, profile in ipairs(bar.profiles) do
        local screenPos = ImGui.GetCursorScreenPos()
        if ImGui.Button(profile.name .. "##profile" .. tostring(_), Vector2.new(windowSize.X, ImGui.GetTextLineHeight()) + miscPadding) then
          bar:scan()
          bar.activeProfile = profile
          local count = 1
          for slot, gearId in pairs(profile.gear) do
            if gearId ~= slot then
              local profileEquipment = game.World.Get(gearId)
              if profileEquipment ~= nil then
                local slotMask = EquipMask[slot]
                local wieldedItem = bar.slots[slot]
                if wieldedItem ~= nil and wieldedItem.Id ~= profileEquipment.Id then
                  if not (string.find(slot, "Ring") or string.find(slot, "Bracelet") or string.find(slot, "Weapon") or string.find(slot, "Shield")) then
                    for i, eqslot in ipairs(bar.equipMask) do
                      if eqslot ~= "None" and profileEquipment.Value(IntId.ValidLocations) + EquipMask[eqslot] == profileEquipment.Value(IntId.ValidLocations) then
                        if bar.slots[eqslot] ~= eqslot and bar.slots[eqslot].Id ~= profileEquipment.Id then
                          game.Actions.ObjectMove(bar.slots[eqslot].Id, game.CharacterId, 0, false,
                            stagger(count, equipmentActionOpts),
                            genericActionCallback)
                          count = count + 1
                        end
                      end
                    end
                  end

                  game.Actions.ObjectMove(profileEquipment.Id, game.CharacterId, 0, false, stagger(count),
                    function(objectMove)
                      if not objectMove.Success and objectMove.Error ~= ActionError.ItemAlreadyWielded then
                        print("Fail! " .. objectMove.ErrorDetails)
                      else
                        game.Actions.ObjectWield(profileEquipment.Id, slotMask, stagger(count, equipmentActionOpts),
                          genericActionCallback)
                      end
                    end)
                  count = count + 1
                else
                  game.Actions.ObjectWield(profileEquipment.Id, slotMask, stagger(count, equipmentActionOpts),
                    genericActionCallback)
                  count = count + 1
                end
              else
                print("Can't find " .. gearId .. " for slot " .. bar.equipMask[slot])
              end
            else
              local wieldedItem = bar.slots[slot]
              if wieldedItem ~= slot then
                game.Actions.ObjectMove(wieldedItem.Id, game.CharacterId, 0, false, stagger(count, equipmentActionOpts),
                  genericActionCallback)
                count = count + 1
              end
            end
          end
          game.Messages.Incoming.Qualities_UpdateInstanceID.Add(bar.watcher)
        end
        if ImGui.IsItemClicked(1) then
          bar.profileName = profile.name
          bar.imguiReset = true
          bar.renderContext = "showGearCtx"
          bar:scan()
          bar.render = bar.showGear
        end
        if bar.activeProfile == profile then
          ImGui.GetWindowDrawList().AddRect(screenPos + Vector2.new(1, 0),
            screenPos + Vector2.new(windowSize.X, ImGui.GetTextLineHeight() + miscPadding.Y) - Vector2.new(1, 0),
            0xFF00FF00)
        end
      end
    end,
    render = function(bar)
      bar.renderContext = "showProfilesCtx"
      SaveBarSettings(bar, "renderContext", bar.renderContext) --needed so size is saved separately
      bar.render = bar.showProfiles
    end
  },
  {
    name = "EnchantmentTracker",
    settings = {
      enabled = false,
      showItemBuffs = false,
      reverseSort = false,
      sortingOptions_combo = { 1, "Name", "Id", "Category", "StatModType", "ExpiresAt", "Level", "Power" }
    },
    init = function(bar)
      function bar.formatSeconds(seconds)
        local hours = math.floor(seconds / 3600)
        local minutes = math.floor((seconds % 3600) / 60)
        local remainingSeconds = seconds % 60
        if hours > 0 then
          return string.format("%02d:%02d", hours, minutes)
        else
          return string.format("%02d:%02d", minutes, remainingSeconds)
        end
      end
    end,

    render = function(bar)
      local activeSpells = {
        buffs = {},
        debuffs = {}
      }
      ---@param enchantment Enchantment
      for _, enchantment in ipairs(game.Character.ActiveEnchantments()) do
        ---@type Spell
        local spell = game.Character.SpellBook.Get(enchantment.SpellId)
        if bar.settings.showItemBuffs or enchantment.Duration ~= -1 then
          local entry = {}
          --entry.printProps = {}
          entry.Name = spell.Name or "Unknown"
          entry.Id = spell.Id or "No spell.Id"
          entry.Category = enchantment.Category or spell.Category or "No category"
          entry.StatModType = spell.StatModType
          entry.Level = spell.Level or "No spell.Level"
          entry.Power = enchantment.Power

          entry.ClientReceivedAt = enchantment.ClientReceivedAt
          entry.Duration = enchantment.Duration
          entry.StartTime = enchantment.StartTime
          if entry.Duration > -1 then
            entry.ExpiresAt = (entry.ClientReceivedAt + TimeSpan.FromSeconds(entry.StartTime + entry.Duration) - DateTime.UtcNow)
                .TotalSeconds
          else
            entry.ExpiresAt = 999999
          end

          entry.casterId = enchantment.CasterId
          entry.displayOrder = spell.DisplayOrder or 9999
          entry.isBuff = (SpellFlags.Beneficial + spell.Flags == spell.Flags)
          entry.icon = spell.Icon or 9914


          local function hasFlag(object, flag)
            return (object.Flags + flag == object.Flags)
          end


          local statKey = spell.StatModKey
          if spell.StatModAttribute ~= AttributeId.Undef then
            entry.stat = tostring(AttributeId.Undef + statKey)
          elseif spell.StatModVital ~= Vital.Undef then
            entry.stat = tostring(Vital.Undef + statKey)
          elseif spell.StatModSkill ~= SkillId.Undef then
            entry.stat = tostring(SkillId.Undef + statKey)
          elseif spell.StatModIntProp ~= IntId.Undef then
            entry.stat = tostring(IntId.Undef + statKey)
          elseif spell.StatModFloatProp ~= FloatId.Undef then
            entry.stat = tostring(FloatId.Undef + statKey)
          else
            entry.stat = tostring(enchantment.Category)
          end

          if hasFlag(enchantment, EnchantmentFlags.Additive) then
            entry.printProp = enchantment.StatValue > 0 and ("+" .. enchantment.StatValue) or enchantment.StatValue
          elseif hasFlag(enchantment, EnchantmentFlags.Multiplicative) then
            local percent = enchantment.StatValue - 1
            entry.printProp = (percent > 0 and ("+" .. string.format("%.0d", percent * 100)) or string.format("%.0d", percent * 100)) ..
                "%%"
          end


          local key
          if entry.isBuff then
            key = "buffs"
          else
            key = "debuffs"
          end

          local added = false
          for i, buffOrDebuff in ipairs(activeSpells[key]) do
            if buffOrDebuff.Category == entry.Category then
              if buffOrDebuff.Power == entry.Power and buffOrDebuff.ClientReceivedAt < entry.ClientReceivedAt then --
                activeSpells[key][i] = entry
                added = true
                break
              elseif buffOrDebuff.Power < entry.Power then
                activeSpells[key][i] = entry
                added = true
                break
              end
            end
          end
          if added == false then
            table.insert(activeSpells[key], entry)
          end
        end
      end

      local sortKey = bar.settings.sortingOptions_combo[bar.settings.sortingOptions_combo[1] + 1]
      for i, buffsOrDebuffs in pairs(activeSpells) do
        table.sort(buffsOrDebuffs, function(a, b)
          if bar.settings.reverseSort then
            return a[sortKey] > b[sortKey]
          else
            return a[sortKey] < b[sortKey]
          end
        end)
      end

      local checkboxSize = Vector2.new(24, 24)
      local windowSize = ImGui.GetWindowSize()
      local windowPos = ImGui.GetWindowPos()
      local reservedHeight = checkboxSize.Y + ImGui.GetStyle().ChildBorderSize * 2

      -- Calculate the available space for the table
      local availableSize = ImGui.GetContentRegionAvail()
      local tableSize = Vector2.new(availableSize.X, availableSize.Y - reservedHeight)

      -- Render the table
      if ImGui.BeginTable("Buffs | Debuffs", 2, _imgui.ImGuiTableFlags.SizingStretchSame + _imgui.ImGuiTableFlags.Resizable, tableSize) then
        -- Table logic (columns, rows, etc.)
        ImGui.TableSetupColumn(" Buffs", _imgui.ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn(" Debuffs", _imgui.ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableHeadersRow()

        for column, buffsOrDebuffs in ipairs({ activeSpells.buffs, activeSpells.debuffs }) do
          ImGui.TableNextColumn()

          -- Scrollable child
          local borderPadding = ImGui.GetStyle().FrameBorderSize * 2
          local columnWidth = ImGui.GetColumnWidth()
          local columnHeight = ImGui.GetContentRegionAvail().Y - reservedHeight - borderPadding

          ImGui.BeginChild("ScrollableColumn##" .. column, Vector2.new(columnWidth, columnHeight), true)
          for _, buffOrDebuff in ipairs(buffsOrDebuffs) do
            local cursorStart = ImGui.GetCursorScreenPos()
            local iconSize = Vector2.new(28, 28)
            local printProp = buffOrDebuff.printProp

            local expiryTimer
            local backgroundColor = ImGui.GetColorU32(_imgui.ImGuiCol.ChildBg)
            if buffOrDebuff.Duration > -1 then
              expiryTimer = (buffOrDebuff.ClientReceivedAt + TimeSpan.FromSeconds(buffOrDebuff.StartTime + buffOrDebuff.Duration) - DateTime.UtcNow)
                  .TotalSeconds
              ImGui.PushStyleColor(_imgui.ImGuiCol.PlotHistogram, buffOrDebuff.isBuff and 0xAA006600 or 0xAA000066)
              ImGui.PushStyleColor(_imgui.ImGuiCol.FrameBg, ImGui.GetColorU32(backgroundColor))
              ImGui.ProgressBar(expiryTimer / buffOrDebuff.Duration,
                Vector2.new(ImGui.GetColumnWidth(), iconSize.Y + ImGui.GetStyle().CellPadding.Y), "")
              ImGui.PopStyleColor(2)
            end

            ImGui.SetCursorScreenPos(cursorStart)
            ImGui.TextureButton("##" .. buffOrDebuff.Id, GetOrCreateTexture(buffOrDebuff.icon), iconSize)
            if ImGui.IsItemHovered() then
              if buffOrDebuff.casterId ~= game.CharacterId and buffOrDebuff.casterId ~= 0 and
                  buffOrDebuff.casterId ~= nil and game.World.Exists(buffOrDebuff.casterId) then
                ImGui.BeginTooltip()

                local caster = game.World.Get(buffOrDebuff.casterId)
                ImGui.Text("Granted by\n" .. caster.Name)
                ImGui.TextureButton("##" .. buffOrDebuff.Id - buffOrDebuff.casterId,
                  GetOrCreateTexture(caster.Value(DataId.Icon)), iconSize)
                ImGui.EndTooltip()
              end
            end

            local expiryTimerYAdjust
            if expiryTimer then
              ImGui.SetWindowFontScale(1)
              expiryTimerYAdjust = ImGui.GetFontSize() / 2
              ImGui.SetCursorScreenPos(ImGui.GetCursorScreenPos() + Vector2.new(3, 0))
              local cursorStartDurationText = ImGui.GetCursorScreenPos() - Vector2.new(3, expiryTimerYAdjust)
              local durationTextSize = ImGui.CalcTextSize(bar.formatSeconds(expiryTimer))
              ImGui.GetWindowDrawList().AddRectFilled(cursorStartDurationText,
                cursorStartDurationText + durationTextSize + Vector2.new(3, 0), 0xAA000000)
              ImGui.SetCursorScreenPos(ImGui.GetCursorScreenPos() - Vector2.new(0, expiryTimerYAdjust))
              ImGui.Text(bar.formatSeconds(expiryTimer))
              ImGui.SetWindowFontScale(bar.settings.fontScale_flt or 1)
            end

            local cursorPostIcon = cursorStart + Vector2.new(iconSize.X, 0)
            local visibleText = tostring(printProp):gsub("%%%%", "%%")
            local textSize = ImGui.CalcTextSize(visibleText)

            local cursorForName = Vector2.new(cursorPostIcon.X + 5,
              cursorPostIcon.Y + iconSize.Y / 2 - ImGui.GetFontSize() / 2)
            ImGui.SetCursorScreenPos(cursorForName)
            ImGui.PushClipRect(cursorForName,
              Vector2.new(cursorForName.X + ImGui.GetContentRegionAvail().X - textSize.X - 5,
                cursorForName.Y + iconSize.Y + ImGui.GetStyle().CellPadding.Y), true)
            ImGui.Text(buffOrDebuff.Name)
            ImGui.PopClipRect()

            local cursorForProp = Vector2.new(cursorStart.X + ImGui.GetContentRegionAvail().X - textSize.X,
              cursorStart.Y + iconSize.Y / 2 - ImGui.GetFontSize() / 2)
            ImGui.SetCursorScreenPos(cursorForProp)
            ImGui.PushStyleColor(_imgui.ImGuiCol.Text, buffOrDebuff.isBuff and 0xFF00FF00 or 0xFF0000FF)
            ImGui.Text(printProp)
            ImGui.PopStyleColor()

            ImGui.SetCursorScreenPos(Vector2.new(cursorStart.X,
              cursorStart.Y + iconSize.Y + ImGui.GetStyle().CellPadding.Y + (expiryTimerYAdjust or 0)))
          end
          ImGui.EndChild()
        end
        ImGui.EndTable()
      end

      local spacingBetweenLabelX = 5
      ImGui.PushStyleVar(_imgui.ImGuiStyleVar.ItemInnerSpacing, Vector2.new(spacingBetweenLabelX, 0))

      ImGui.SetCursorScreenPos(ImGui.GetCursorScreenPos() + Vector2.new(spacingBetweenLabelX, 3))

      local changed, checked = ImGui.Checkbox("Show Item Buffs     ##" .. bar.name, bar.settings.showItemBuffs)
      if changed then
        bar.settings.showItemBuffs = checked
      end

      ImGui.SameLine()
      ImGui.Text("Sort by ")

      ImGui.SameLine()
      ImGui.SetNextItemWidth(100)

      ---@diagnostic disable-next-line
      local sortOptions = { unpack(bar.settings.sortingOptions_combo, 2, #bar.settings.sortingOptions_combo) }
      local sortIndex = bar.settings.sortingOptions_combo[1] - 1
      local changed2, newIndex = ImGui.Combo("##sortOption", sortIndex, sortOptions,
        #bar.settings.sortingOptions_combo - 1)
      if changed2 then
        bar.settings.sortingOptions_combo[1] = newIndex + 1
        SaveBarSettings(bar, "settings.sortingOptions_combo", bar.settings.sortingOptions_combo)
      end

      ImGui.SameLine()
      ImGui.Text("     Desc ")

      ImGui.SameLine()
      local changed3, checked3 = ImGui.Checkbox("##" .. bar.name .. "_reverseSort", bar.settings.reverseSort)
      if changed3 then
        bar.settings.reverseSort = checked3
      end

      ImGui.PopStyleVar()
    end
  },
  {
    name = "buffs",
    settings = {
      enabled = false,
      icon_hex = 0x06005E6B,
      growAxis_str = "X",       -- "X" or "Y"
      growAlignmentFlip = true, -- uses same growAxis_str, but flips alignment to other side of window
      growReverse = true,
      bufferRectX_num = 10,
      bufferRectY_num = 5,
      iconSpacing_num = 10,
      expiryMaxSeconds_num = 9999,
      spellLevelDisplay = true,
      spellLevelColor_col4 = 0xBBBBBBBB,
      buffBorder = true,
      buffBorderColor_col4 = 0x99009900,
      buffBorderThickness_num = 2,
    },
    windowSettings = _imgui.ImGuiWindowFlags.NoInputs + _imgui.ImGuiWindowFlags.NoBackground,
    init = function(bar)
      bar.displayCriteria = function(enchantment, spell, entry)
        return ((enchantment.Duration ~= -1) and (SpellFlags.Beneficial + spell.Flags == spell.Flags) and ((not bar.settings.expiryMaxSeconds_num) or entry.ExpiresAt < bar.settings.expiryMaxSeconds_num))
      end

      bar.formatSeconds = function(seconds)
        local hours = math.floor(seconds / 3600)
        local minutes = math.floor((seconds % 3600) / 60)
        local remainingSeconds = seconds % 60
        if hours > 0 then
          return string.format("%02d:%02d", hours, minutes)
        elseif minutes > 0 then
          return string.format("%02d:%02d", minutes, remainingSeconds)
        else
          return string.format("%ds", remainingSeconds)
        end
      end
    end,
    render = renderBuffs
  },
  {
    name = "debuffs",
    settings = {
      enabled = false,
      icon_hex = 0x06005E6A,
      growAxis_str = "X",       -- "X" or "Y"
      growAlignmentFlip = true, -- uses same growAxis_str, but flips alignment to other side of window
      growReverse = false,
      bufferRectX_num = 10,
      bufferRectY_num = 5,
      iconSpacing_num = 10,
      expiryMaxSeconds_num = 9999,
      spellLevelDisplay = true,
      spellLevelColor_col4 = 0xBBBBBBBB,
      buffBorder = true,
      buffBorderColor_col4 = 0x99000099,
      buffBorderThickness_num = 2,
    },
    windowSettings = _imgui.ImGuiWindowFlags.NoInputs + _imgui.ImGuiWindowFlags.NoBackground,
    init = function(bar)
      bar.displayCriteria = function(enchantment, spell, entry)
        return ((enchantment.Duration ~= -1) and (not (SpellFlags.Beneficial + spell.Flags == spell.Flags)) and ((not bar.settings.expiryMaxSeconds_num) or entry.ExpiresAt < bar.settings.expiryMaxSeconds_num))
      end

      bar.formatSeconds = function(seconds)
        local hours = math.floor(seconds / 3600)
        local minutes = math.floor((seconds % 3600) / 60)
        local remainingSeconds = seconds % 60
        if hours > 0 then
          return string.format("%02d:%02d", hours, minutes)
        elseif minutes > 0 then
          return string.format("%02d:%02d", minutes, remainingSeconds)
        else
          return string.format("%ds", remainingSeconds)
        end
      end
    end,
    render = renderBuffs
  },
  { name = "HealkitCooldown", --important, must be correctly capitalized for enum to work
    settings = {
      enabled = false,
      icon_hex = 0x060032E5,
      fontScale_flt = 2,
    },
    init = function(bar)
      ---@param cooldownChanged SharedCooldownsChangedEventArgs
      game.Character.OnSharedCooldownsChanged.Add(function(cooldownChanged)
        local maybeKit=game.World.Get(cooldownChanged.Cooldown.ObjectId)

        if maybeKit and maybeKit.ObjectClass==ObjectClass.HealingKit then
          bar.cooldown = cooldownChanged.Cooldown.ExpiresAt
        end
      end)
    end,
    render = function(bar)
      if bar.cooldown then
        local rem = (bar.cooldown - DateTime.UtcNow).TotalSeconds
        if rem > 0 then
          bar.settings.label_str = string.format("%.1f", rem)
        else
          bar.cooldown = nil
          bar.settings.label_str = nil
        end
      end
      DrawIcon(bar,bar.settings.icon_hex)
    end
  },
})
return bars
