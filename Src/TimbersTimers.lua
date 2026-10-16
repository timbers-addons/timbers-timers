-- Timber's Timers
-- Tracks short-term buffs/debuffs with countdown bars, grouped by target.

TimbersTimers = {}
local TT = TimbersTimers

-- ============================================================
-- CLIENT COMPATIBILITY
-- TBC Anniversary runs the pre-Cataclysm API; WoW: Forever runs the Midnight
-- (retail) engine, which dropped the aura globals and hands addons "secret"
-- values for some unit state.  This section is the only place that touches a
-- client-specific global; everything below calls these wrappers.
-- ============================================================
local UnitBuff_   = UnitBuff
local UnitDebuff_ = UnitDebuff
local GetAuraDataByIndex = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
local GetCombatLogEvent  = CombatLogGetCurrentEventInfo

-- A secret value can be held and passed on, but comparing, testing or doing
-- arithmetic on one errors.  Inside instances the engine hands them out for
-- unit state, and whether it does varies per call, so nothing is latched:
-- every value the addon is about to branch on is checked first.
local function compareString(value)
    return value == ""
end
function TT.IsReadable(...)
    local hasCheck = type(issecretvalue) == "function"
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if hasCheck then
            if issecretvalue(value) then return false end
        elseif not pcall(compareString, value) then
            return false
        end
    end
    return true
end

-- COMBAT_LOG_EVENT_UNFILTERED is reserved for the Blizzard UI on the retail
-- (Midnight) engine.  Registering it raises ADDON_ACTION_FORBIDDEN and puts a
-- dialog in the user's face, and it cannot be probed for first -- asking is
-- the failure -- so it is gated on the client rather than tested.  Verified
-- refused on Forever 1.60.1, interface 16001, 2026-10-16; the other six events
-- this addon registers were all accepted.  Pre-Cataclysm clients are fine.
--
-- Two independent signals, because getting this wrong puts a dialog in the
-- user's face.  The pre-Cataclysm clients still expose the aura globals and
-- the Midnight engine removed them; separately, a client reporting itself as
-- mainline is on that engine too.  Either being true is enough.
--
-- The aura check is the one that actually catches Forever.  It reports
-- WOW_PROJECT_ID 18, not WOW_PROJECT_MAINLINE (1), seen in game on 1.60.1
-- interface 16001, 2026-10-16.  Do not reduce this to the project check: that
-- is what let the forbidden registration through in the first place.
TT.isMidnightEngine =
       (UnitBuff_ == nil and UnitDebuff_ == nil)
    or (WOW_PROJECT_ID ~= nil and WOW_PROJECT_MAINLINE ~= nil
        and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
TT.canUseCombatLog = not TT.isMidnightEngine

-- Group size and shape.  Present on every client we run on, but kept here
-- with fallbacks so a missing one degrades to "solo" instead of erroring in
-- the main chunk.
TT.IsInRaid = IsInRaid or function() return false end
TT.GetNumGroupMembers = GetNumGroupMembers or function() return 0 end

-- Addon metadata moved under C_AddOns on the retail engine.
local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
TT.version = (GetMetadata and GetMetadata("TimbersTimers", "Version")) or "unknown"

-- Aura lookup, player-cast auras only.  The positional globals were removed on
-- the retail engine; C_UnitAuras returns a table instead.  Both are flattened
-- to the five fields the addon uses so call sites read the same on every
-- client.
--
-- The PLAYER filter makes the client decide whether we cast the aura, so the
-- addon never reads the caster itself.  That matters inside instances, where
-- the Midnight engine is liable to hand back unit state as a secret value:
-- a caster we cannot compare would mean no bars at all, exactly where DoT
-- timers are worth having.
function TT.GetAura(unit, index, isDebuff)
    -- Spelled out rather than "isDebuff and x or y": that idiom falls through
    -- to the buff lookup on a client that has UnitBuff but not UnitDebuff.
    local legacy
    if isDebuff then legacy = UnitDebuff_ else legacy = UnitBuff_ end
    if legacy then
        local name, icon, count, _, duration, expiresAt = legacy(unit, index, "PLAYER")
        return name, icon, count, duration, expiresAt
    end
    if not GetAuraDataByIndex then return nil end
    local a = GetAuraDataByIndex(unit, index, isDebuff and "HARMFUL|PLAYER" or "HELPFUL|PLAYER")
    if not a then return nil end
    return a.name, a.icon, a.applications, a.duration, a.expirationTime
end

-- ============================================================
-- DEFAULTS
-- ============================================================
local DEFAULTS = {
    x             = 200,
    y             = -200,
    locked        = false,
    headerVisible = true,
}

-- ============================================================
-- CONFIGURATION
-- ============================================================
TT.config = {
    barWidth     = 220,
    barHeight    = 20,
    titleHeight  = 16,
    barSpacing   = 3,
    groupSpacing = 10,
    headerHeight = 14,
    headerGap    = 2,
    font         = "Fonts\\FRIZQT__.TTF",
    fontSize     = 11,
    headerSize   = 10,
    latency      = 0,
    tickColor    = { r=1,   g=1,   b=0,   a=0.9 },
    barBgColor   = { r=0.1, g=0.1, b=0.1, a=0.8 },
}

-- Spells with periodic ticks: name -> tick interval in seconds
TT.tickSpells = {
    ["Renew"]              = 3,
    ["Rejuvenation"]       = 3,
    ["Regrowth"]           = 3,
    ["Lifebloom"]          = 3,
    ["Corruption"]         = 3,
    ["Curse of Agony"]     = 2,
    ["Immolate"]           = 3,
    ["Moonfire"]           = 3,
    ["Vampiric Touch"]     = 3,
    ["Serpent Sting"]      = 3,
    ["Deadly Poison"]      = 3,
    ["Poison"]             = 3,
    ["Mind Flay"]          = 1,
    ["Shadow Word: Pain"]  = 3,
    ["Fireball"]           = 2,
}

-- Spells tracked regardless of the 120s duration cap
TT.forcedTrack = {
    ["Fear Ward"] = true,
}

-- Spells tracked on party/pet members (PoM jumps); all other spells are ignored for those units
TT.partySpells = {
    ["Prayer of Mending"] = true,
}

-- ============================================================
-- STATE
-- ============================================================
TT.tracked    = {}
TT.bars       = {}
TT.headers    = {}
TT.barPool    = {}
TT.headerPool = {}
TT.guidOrder  = {}

-- ============================================================
-- SLASH COMMANDS — registered before frame creation so a frame
-- error cannot block them.  /timberstimers and /tt only.
-- ============================================================
SLASH_TIMBERSTIMERS1 = "/timberstimers"
SLASH_TIMBERSTIMERS2 = "/tt"
SlashCmdList["TIMBERSTIMERS"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$") or ""
    local sv = TimbersTimersSV
    if not sv then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff99Timber's Timers|r: not initialized yet.")
        return
    end
    local function say(s) DEFAULT_CHAT_FRAME:AddMessage("|cff00ff99Timber's Timers|r: " .. s) end

    if     msg == "lock"   then sv.locked = true;  TT.frame:EnableMouse(false); say("Locked.")
    elseif msg == "unlock" then sv.locked = false; TT.frame:EnableMouse(true);  say("Unlocked.")
    elseif msg == "reset"  then
        sv.x, sv.y = DEFAULTS.x, DEFAULTS.y
        TT.frame:ClearAllPoints()
        TT.frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", sv.x, sv.y)
        say("Position reset.")
    elseif msg == "debug" then
        -- Reports what the addon believes about this client, so a wrong guess
        -- shows up here instead of as a blocked-action dialog.
        local iface = select(4, GetBuildInfo())
        say(("version %s, interface %s"):format(TT.version, tostring(iface)))
        say(("WOW_PROJECT_ID=%s mainline=%s -> midnight engine: %s")
            :format(tostring(WOW_PROJECT_ID), tostring(WOW_PROJECT_MAINLINE),
                    tostring(TT.isMidnightEngine)))
        say(("aura api: UnitBuff=%s GetAuraDataByIndex=%s"):format(
            type(UnitBuff_), type(GetAuraDataByIndex)))
        say("canUseCombatLog: " .. tostring(TT.canUseCombatLog))
        for _, e in ipairs({ "PLAYER_LOGIN", "UNIT_AURA", "PLAYER_TARGET_CHANGED",
                             "PLAYER_FOCUS_CHANGED", "PLAYER_ENTERING_WORLD",
                             "COMBAT_LOG_EVENT_UNFILTERED", "GROUP_ROSTER_UPDATE" }) do
            local ok, reg = pcall(TT.frame.IsEventRegistered, TT.frame, e)
            say(("  %-30s %s"):format(e, ok and tostring(reg) or "?"))
        end
    elseif msg == "show" then
        sv.headerVisible = true
        if TT.titleFrame then TT.titleFrame:Show() end
        say("Header shown.")
    elseif msg == "hide" then
        sv.headerVisible = false
        if TT.titleFrame then TT.titleFrame:Hide() end
        say("Header hidden.")
    else
        say("Commands: lock | unlock | reset | show | hide | debug")
    end
end

-- ============================================================
-- MAIN FRAME
-- Reuse existing named frame if WoW already has it in memory.
-- ============================================================
do
    local existing = _G["TimbersTimersFrame"]
    if existing then
        TT.frame = existing
    else
        TT.frame = CreateFrame("Frame", "TimbersTimersFrame", UIParent)
    end
end

TT.frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", DEFAULTS.x, DEFAULTS.y)
TT.frame:SetSize(TT.config.barWidth + TT.config.barHeight + 6, TT.config.titleHeight + 4)
TT.frame:SetMovable(true)
TT.frame:EnableMouse(true)
TT.frame:RegisterForDrag("LeftButton")

TT.frame:SetScript("OnDragStart", function(self)
    if not (TimbersTimersSV and TimbersTimersSV.locked) then self:StartMoving() end
end)
TT.frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    TT:SavePosition()
end)

TT.frame:RegisterEvent("PLAYER_LOGIN")
TT.frame:RegisterEvent("UNIT_AURA")
TT.frame:RegisterEvent("PLAYER_TARGET_CHANGED")
TT.frame:RegisterEvent("PLAYER_FOCUS_CHANGED")
TT.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
if TT.canUseCombatLog then
    TT.frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
end
TT.frame:RegisterEvent("GROUP_ROSTER_UPDATE")

TT.frame:SetScript("OnEvent", function(self, event, ...)
    if     event == "PLAYER_LOGIN"               then TT:OnLoad()
    elseif event == "PLAYER_ENTERING_WORLD"      then TT:OnLoad(); TT:RefreshAll()
    elseif event == "UNIT_AURA"                  then TT:OnUnitAura(...)
    elseif event == "PLAYER_TARGET_CHANGED"      then TT:OnUnitScan("target")
    elseif event == "PLAYER_FOCUS_CHANGED"       then TT:OnUnitScan("focus")
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then TT:OnCombatLog()
    -- Roster changes only rebuild the scan list.  This fires repeatedly while
    -- a raid forms, and a full rescan each time would be a burst; the sweep
    -- picks the new members up within SWEEP_INTERVAL.
    elseif event == "GROUP_ROSTER_UPDATE"        then TT:RebuildGroupUnits()
    end
end)

TT.frame:SetScript("OnUpdate", function(self, elapsed) TT:OnUpdate(elapsed) end)

-- ============================================================
-- INIT
-- ============================================================
function TT:OnLoad()
    if TT.loaded then return end
    TT.loaded = true
    if not TimbersTimersSV then TimbersTimersSV = {} end
    local sv = TimbersTimersSV
    for k, v in pairs(DEFAULTS) do
        if sv[k] == nil then sv[k] = v end
    end

    self.frame:ClearAllPoints()
    self.frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", sv.x, sv.y)
    self.frame:Show()
    if sv.locked then self.frame:EnableMouse(false) end

    -- Title bar (built here so frame-API errors don't break slash commands)
    if not self.titleFrame then
        local cfg = self.config
        local t = CreateFrame("Frame", nil, self.frame)
        t:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 0)
        t:SetWidth(self.frame:GetWidth())
        t:SetHeight(cfg.titleHeight)

        local bg = t:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture("Interface\\Buttons\\WHITE8x8")
        bg:SetVertexColor(0.05, 0.05, 0.05, 0.85)

        local lbl = t:CreateFontString(nil, "OVERLAY")
        lbl:SetAllPoints()
        lbl:SetFont(cfg.font, 10, "OUTLINE")
        lbl:SetJustifyH("CENTER")
        lbl:SetText("|cff00ff99Timber's Timers|r")

        self.titleFrame = t
    end

    if sv.headerVisible then self.titleFrame:Show() else self.titleFrame:Hide() end

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff00ff99Timber's Timers|r " .. TT.version
            .. " loaded.  /tt  lock|unlock|reset|show|hide|debug"
    )
end

function TT:SavePosition()
    if not TimbersTimersSV then return end
    TimbersTimersSV.x = self.frame:GetLeft()
    TimbersTimersSV.y = self.frame:GetTop() - UIParent:GetHeight()
end

-- ============================================================
-- AURA SCANNING
-- ============================================================
local function collectAuras(unit, filter, auras, isDebuff, limit)
    for i = 1, limit do
        local name, icon, count, duration, expiresAt = TT.GetAura(unit, i, isDebuff)
        -- A secret value here would error on the tests below, so the aura is
        -- skipped.  The scan continues: later indices may be readable.
        if TT.IsReadable(name, count, duration, expiresAt) then
            if not name then break end
            if not filter or filter[name] then
                local inRange = duration and duration > 0 and (duration <= 120 or TT.forcedTrack[name])
                if inRange then
                    auras[name] = {
                        name         = name,
                        icon         = icon,
                        duration     = duration,
                        expiresAt    = expiresAt,
                        count        = count,
                        isDebuff     = isDebuff,
                        tickInterval = TT.tickSpells[name],
                    }
                end
            end
        end
    end
end

-- filter: optional set of spell names; when provided only those spells are tracked
function TT:ScanUnit(unit, filter)
    local auras = {}

    collectAuras(unit, filter, auras, true,  40)
    collectAuras(unit, filter, auras, false, 32)

    return auras
end

-- ============================================================
-- EVENT HANDLERS
-- ============================================================
function TT:OnUnitAura(unit)
    if not TT.IsReadable(unit) then return end
    if unit == "player" or unit == "target" or unit == "focus"
    or unit == "pet"    or unit:match("^party%d$") or unit:match("^raid%d+$") then
        self:OnUnitScan(unit)
    elseif unit:match("^partypet%d$") or unit:match("^raidpet%d+$") then
        self:OnUnitScan(unit, TT.partySpells)
    end
end

function TT:OnCombatLog()
    if not GetCombatLogEvent then return end
    local _, subevent, _, _, _, _, _, destGUID = GetCombatLogEvent()
    if not TT.IsReadable(subevent, destGUID) then return end
    if subevent ~= "UNIT_DIED" then return end
    if destGUID and self.tracked[destGUID] then
        self:RemoveGUID(destGUID)
    end
end

function TT:OnUnitScan(unit, filter)
    local guid = UnitGUID(unit)
    if not TT.IsReadable(guid) or not guid then return end
    local name = UnitName(unit)
    if not TT.IsReadable(name) then name = nil end
    self:UpdateTrackedUnit(guid, name or guid, unit, filter)
end

-- The group unit tokens worth scanning, rebuilt when the roster changes
-- rather than every frame.  party and raid tokens never coexist: in a raid
-- party1-4 are nil, which is why raid groups showed nothing before.  In a
-- raid the player also appears as one of the raid units; scanning both is
-- harmless, since a rescan of the same GUID with the same auras is a no-op.
local MAX_RAID = 40

function TT:RebuildGroupUnits()
    local units = { { unit = "player" }, { unit = "pet" } }
    if TT.IsInRaid() then
        local n = math.min(tonumber(TT.GetNumGroupMembers()) or 0, MAX_RAID)
        for i = 1, n do
            units[#units + 1] = { unit = "raid"    .. i }
            units[#units + 1] = { unit = "raidpet" .. i, filter = TT.partySpells }
        end
    else
        for i = 1, 4 do
            units[#units + 1] = { unit = "party"    .. i }
            units[#units + 1] = { unit = "partypet" .. i, filter = TT.partySpells }
        end
    end
    self.groupUnits = units
end

function TT:RefreshAll()
    self:RebuildGroupUnits()
    self:OnUnitScan("target")
    self:OnUnitScan("focus")
    for _, u in ipairs(self.groupUnits) do
        self:OnUnitScan(u.unit, u.filter)
    end
end

function TT:UpdateTrackedUnit(guid, unitName, unit, filter)
    local auras = self:ScanUnit(unit, filter)
    if next(auras) == nil then
        if self.tracked[guid] then self:RemoveGUID(guid) end
        return
    end

    local existing = self.tracked[guid]
    if existing then
        -- Check if the aura set changed (spells added/removed). When it has
        -- not, the values are refreshed in place without a rebuild.
        local changed = false
        for k in pairs(auras) do
            if not existing.auras[k] then changed = true; break end
        end
        if not changed then
            for k in pairs(existing.auras) do
                if not auras[k] then changed = true; break end
            end
        end
        if not changed then
            -- Refresh expiry and count in place so bars stay smooth. OnUpdate
            -- reads the expiry every frame, so that needs nothing more, but
            -- the label is only written when it changes: a restacking aura
            -- (Lifebloom going 2 to 3, say) has to set it here or the bar
            -- keeps showing the old count.
            local barMap = self.bars[guid]
            for k, a in pairs(auras) do
                local current = existing.auras[k]
                current.expiresAt = a.expiresAt
                if current.count ~= a.count then
                    current.count = a.count
                    local bar = barMap and barMap[k]
                    if bar then self:SetBarLabel(bar, current) end
                end
            end
            existing.name = unitName
            return
        end
        existing.name  = unitName
        existing.auras = auras
    else
        self.tracked[guid] = { name = unitName, auras = auras }
        table.insert(self.guidOrder, guid)
    end
    self:RebuildBars()
end

-- Drops the unit from the tracked set only. SyncBars owns releasing frames,
-- so that happens in one place and a frame cannot reach the pool twice.
function TT:RemoveGUID(guid)
    self.tracked[guid] = nil
    for i, g in ipairs(self.guidOrder) do
        if g == guid then table.remove(self.guidOrder, i) break end
    end
    self:RebuildBars()
end

-- ============================================================
-- HEADER POOL
-- ============================================================
function TT:AcquireHeader()
    local h = table.remove(self.headerPool)
    if h then h:Show() return h end
    return self:CreateHeader()
end

function TT:ReleaseHeader(h)
    h:Hide()
    table.insert(self.headerPool, h)
end

function TT:CreateHeader()
    local cfg = self.config
    local h = self.frame:CreateFontString(nil, "OVERLAY")
    h:SetFont(cfg.font, cfg.headerSize, "OUTLINE")
    h:SetJustifyH("LEFT")
    h:SetTextColor(1, 0.82, 0, 1)
    h:SetHeight(cfg.headerHeight)
    h:SetWidth(cfg.barWidth)
    return h
end

-- ============================================================
-- BAR POOL
-- ============================================================
function TT:AcquireBar()
    local bar = table.remove(self.barPool)
    if bar then bar:Show() return bar end
    return self:CreateBar()
end

function TT:ReleaseBar(bar)
    bar:Hide()
    table.insert(self.barPool, bar)
end

function TT:CreateBar()
    local cfg = self.config
    local bar = CreateFrame("Frame", nil, self.frame)
    bar:SetSize(cfg.barWidth, cfg.barHeight)

    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bar.bg:SetVertexColor(cfg.barBgColor.r, cfg.barBgColor.g, cfg.barBgColor.b, cfg.barBgColor.a)

    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetPoint("LEFT", bar, "LEFT", 0, 0)
    bar.fill:SetHeight(cfg.barHeight)
    bar.fill:SetTexture("Interface\\AddOns\\TimbersTimers\\Media\\Textures\\Minimalist")

    bar.icon = bar:CreateTexture(nil, "OVERLAY")
    bar.icon:SetSize(cfg.barHeight, cfg.barHeight)
    bar.icon:SetPoint("RIGHT", bar, "LEFT", -2, 0)
    bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    bar.label = bar:CreateFontString(nil, "OVERLAY")
    bar.label:SetPoint("LEFT", bar, "LEFT", 4, 0)
    bar.label:SetFont(cfg.font, cfg.fontSize, "OUTLINE")
    bar.label:SetJustifyH("LEFT")
    bar.label:SetTextColor(1, 1, 1, 1)

    bar.timeText = bar:CreateFontString(nil, "OVERLAY")
    bar.timeText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    bar.timeText:SetFont(cfg.font, cfg.fontSize, "OUTLINE")
    bar.timeText:SetJustifyH("RIGHT")
    bar.timeText:SetTextColor(1, 1, 1, 1)

    bar.ticks = {}
    for i = 1, 20 do
        local t = bar:CreateTexture(nil, "OVERLAY")
        t:SetSize(2, cfg.barHeight)
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        t:SetVertexColor(cfg.tickColor.r, cfg.tickColor.g, cfg.tickColor.b, cfg.tickColor.a)
        t:Hide()
        bar.ticks[i] = t
    end

    return bar
end

-- ============================================================
-- LAYOUT
-- ============================================================
function TT:SetBarLabel(bar, aura)
    bar.label:SetText(aura.count and aura.count > 1
        and (aura.name .. " (" .. aura.count .. ")") or aura.name)
end

function TT:SetBarContent(bar, guid, spellKey, aura)
    bar.guid     = guid
    bar.spellKey = spellKey
    bar.aura     = aura
    self:SetBarLabel(bar, aura)
    bar.icon:SetTexture(aura.icon)
    bar.fill:SetVertexColor(aura.isDebuff and 0.78 or 0.12,
                            aura.isDebuff and 0.12 or 0.58,
                            0.12, 1)
end

-- Bring the bar and header frames in line with what is tracked, touching only
-- what actually changed.  A surviving bar keeps its frame, its icon and its
-- colour; all it needs is the new aura table, since UpdateTrackedUnit replaces
-- that wholesale when a unit's aura set changes and a stale one would make the
-- countdown read from the wrong expiry.
function TT:SyncBars()
    -- Units and auras that are gone. Clearing a key during pairs() is allowed.
    for guid, barMap in pairs(self.bars) do
        local data  = self.tracked[guid]
        local auras = data and data.auras
        if not auras or not next(auras) then
            for _, bar in pairs(barMap) do self:ReleaseBar(bar) end
            self.bars[guid] = nil
            if self.headers[guid] then
                self:ReleaseHeader(self.headers[guid])
                self.headers[guid] = nil
            end
        else
            for spellKey, bar in pairs(barMap) do
                if not auras[spellKey] then
                    self:ReleaseBar(bar)
                    barMap[spellKey] = nil
                end
            end
        end
    end

    -- Units and auras that are new.
    for guid, data in pairs(self.tracked) do
        if next(data.auras) then
            local barMap = self.bars[guid]
            if not barMap then
                barMap = {}
                self.bars[guid] = barMap
            end
            if not self.headers[guid] then
                self.headers[guid] = self:AcquireHeader()
            end
            self.headers[guid]:SetText(data.name)

            for spellKey, aura in pairs(data.auras) do
                local bar = barMap[spellKey]
                if not bar then
                    bar = self:AcquireBar()
                    barMap[spellKey] = bar
                    self:SetBarContent(bar, guid, spellKey, aura)
                else
                    if bar.aura.count ~= aura.count then self:SetBarLabel(bar, aura) end
                    bar.aura = aura
                end
            end
        end
    end
end

-- Position whatever survived.  Still walks every bar, because a group losing a
-- bar shifts everything below it, but moving a frame is far cheaper than
-- tearing it down and building it again.
function TT:LayoutBars()
    local cfg     = self.config
    local barLeft = cfg.barHeight + 4
    local yOffset = cfg.titleHeight + 4

    for _, guid in ipairs(self.guidOrder) do
        local header = self.headers[guid]
        local barMap = self.bars[guid]
        if header and barMap then
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", self.frame, "TOPLEFT", barLeft, -yOffset)
            yOffset = yOffset + cfg.headerHeight + cfg.headerGap

            for _, bar in pairs(barMap) do
                bar:ClearAllPoints()
                bar:SetPoint("TOPLEFT", self.frame, "TOPLEFT", barLeft, -yOffset)
                yOffset = yOffset + cfg.barHeight + cfg.barSpacing
            end
            yOffset = yOffset + cfg.groupSpacing
        end
    end

    -- Shrink/grow frame to exactly fit content so it doesn't block clicks below it
    self.frame:SetHeight(math.max(cfg.titleHeight + 4, yOffset))
end

function TT:RebuildBars()
    self:SyncBars()
    self:LayoutBars()
end

-- ============================================================
-- UPDATE LOOP (~20 Hz)
-- ============================================================
TT.updateThrottle = 0
TT.sweepCursor    = 0
TT.sweepIndex     = 0
local TICK           = 0.05
local SWEEP_INTERVAL = 5  -- seconds for one pass over the whole group

-- Safety net for UNIT_AURA events the client drops.  Rather than rescanning
-- the group in one burst, this walks it at a rate that covers the roster
-- exactly once per SWEEP_INTERVAL, so a full raid costs no more per frame
-- than a party does: the list gets longer, each unit's turn comes round
-- less often, and the per-tick work stays flat.
function TT:SweepGroup(elapsed)
    if not self.groupUnits then self:RebuildGroupUnits() end
    local units = self.groupUnits
    local n = #units
    if n == 0 then return end

    self.sweepCursor = self.sweepCursor + (n / SWEEP_INTERVAL) * elapsed
    local due = math.floor(self.sweepCursor)
    if due < 1 then return end
    self.sweepCursor = self.sweepCursor - due
    if due > n then due = n end  -- after a stall, one pass is enough

    for _ = 1, due do
        self.sweepIndex = self.sweepIndex % n + 1
        local u = units[self.sweepIndex]
        self:OnUnitScan(u.unit, u.filter)
    end
end

function TT:OnUpdate(elapsed)
    self.updateThrottle = self.updateThrottle + elapsed
    if self.updateThrottle < TICK then return end
    local sinceLastTick = self.updateThrottle
    self.updateThrottle = 0

    self:SweepGroup(sinceLastTick)

    local _, _, home = GetNetStats()
    self.config.latency = (home or 0) / 1000

    local now     = GetTime()
    local cfg     = self.config
    local expired = {}

    for guid, barMap in pairs(self.bars) do
        for spellKey, bar in pairs(barMap) do
            local remaining = bar.aura.expiresAt - now
            if remaining <= 0 then
                table.insert(expired, { guid = guid, spellKey = spellKey })
            else
                bar.fill:SetWidth(math.max(1, cfg.barWidth * (remaining / bar.aura.duration)))
                if remaining < 3 then
                    bar.timeText:SetTextColor(1, 0.3, 0.3, 1)
                else
                    bar.timeText:SetTextColor(1, 1, 1, 1)
                end
                bar.timeText:SetText(string.format("%.1f", remaining))
                self:UpdateTicks(bar, remaining, bar.aura)
            end
        end
    end

    -- Only the tracked set is edited here; SyncBars releases the frames.
    for _, e in ipairs(expired) do
        local guid, spellKey = e.guid, e.spellKey
        local data = self.tracked[guid]
        if data then
            data.auras[spellKey] = nil
            if next(data.auras) == nil then
                self.tracked[guid] = nil
                for i, g in ipairs(self.guidOrder) do
                    if g == guid then table.remove(self.guidOrder, i) break end
                end
            end
        end
    end
    if #expired > 0 then self:RebuildBars() end
end

-- ============================================================
-- TICK MARKS
-- ============================================================
function TT:UpdateTicks(bar, remaining, aura)
    for _, t in ipairs(bar.ticks) do t:Hide() end
    if not aura.tickInterval then return end

    local cfg      = self.config
    local lat      = cfg.latency
    local interval = aura.tickInterval
    local idx      = 1

    -- Static marks at every tick interval across the full duration; bar depletes through them
    local tickTime = interval
    while tickTime < aura.duration and idx <= #bar.ticks do
        local d = tickTime - lat
        if d > 0 then
            bar.ticks[idx]:ClearAllPoints()
            bar.ticks[idx]:SetPoint("CENTER", bar, "LEFT", cfg.barWidth * (d / aura.duration), 0)
            bar.ticks[idx]:Show()
            idx = idx + 1
        end
        tickTime = tickTime + interval
    end
end
