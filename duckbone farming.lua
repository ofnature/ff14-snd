-- ============================================================
-- [GIL_MISTWAKE] Mistwake Dungeon Gil Farming Loop
-- Version: 1.1.0
-- Requires: SomethingNeedDoing (Jaksuhn fork), AutoDuty,
--           vnavmesh, YesAlready, TextAdvance, Lifestream
-- ============================================================
-- LOOP OVERVIEW:
--   1. Run Mistwake via AutoDuty for X runs (configurable)
--   2. Teleport to your Grand Company city
--   3. Navigate to Personnel Officer -> Expert Delivery
--   4. Turn in loot filtered by blacklist/whitelist
--   5. Navigate to GC Merchant -> buy Duckbones until out of seals
--   6. Repeat from step 1 indefinitely until script is stopped
-- ============================================================

-- ============================================================
-- CONFIG
-- ============================================================
local CONFIG = {

    -- ── DUTY SETTINGS ─────────────────────────────────────────
    runs_per_cycle       = 5,
    autoduty_content_id  = 1017,   -- Mistwake patch 7.4
    duty_timeout         = 1800,   -- 30 min hard cap per run

    -- ── GRAND COMPANY ─────────────────────────────────────────
    -- 1 = Maelstrom (Limsa)  2 = Twin Adder (Gridania)  3 = Flames (Ul'dah)
    grand_company  = 1,
    seal_cap       = 90000,
    seal_reserve   = 1500,

    -- ── BUY ITEM ──────────────────────────────────────────────
    buy_item_name        = "Duckbone",
    buy_item_shop_index  = 0,      -- 0-based row in GCShop; verify in-game
    buy_item_seal_cost   = 200,

    -- ── GC TELEPORT & NAVIGATION ──────────────────────────────
    -- Maelstrom defaults — swap coords/names for your GC if needed
    gc_tp_name   = "Limsa Lominsa Lower Decks",
    gc_zone_id   = 129,

    gc_officer_x = -67.8,
    gc_officer_y =  21.4,
    gc_officer_z = -18.1,

    gc_shop_x    = -72.2,
    gc_shop_y    =  21.4,
    gc_shop_z    = -14.9,

    -- ── TIMING ────────────────────────────────────────────────
    interact_delay = 1.5,
    nav_stop_dist  = 3.0,
}

-- ============================================================
-- BLACKLIST / WHITELIST CONFIG
-- ============================================================
-- LIST_MODE:
--   "blacklist" = turn in EVERYTHING except items in ITEM_LIST
--   "whitelist" = ONLY turn in items that ARE in ITEM_LIST
--
-- Find item IDs by hovering an item and running: /snd echo {itemid}
-- Or run the dungeon once with an empty list — drop IDs print to log.
-- ============================================================

local LIST_MODE = "blacklist"   -- "blacklist" or "whitelist"

local ITEM_LIST = {
    -- FORMAT:  [itemID] = "descriptive name for logging",
    --
    -- BLACKLIST example (items to KEEP, never turn in):
    -- [44301] = "Mistwake Coat of Fending",
    -- [44305] = "Mistwake Circlet of Casting",
    --
    -- WHITELIST example (ONLY these get turned in):
    -- [44302] = "Mistwake Breeches of Fending",
    -- [44308] = "Mistwake Gauntlets of Maiming",
}

-- ============================================================
-- GC NPC NAMES
-- ============================================================
local GC_OFFICER_NAMES = {
    [1] = "Storm Personnel Officer",
    [2] = "Serpent Personnel Officer",
    [3] = "Flame Personnel Officer",
}
local GC_SHOP_NAMES = {
    [1] = "Storm Quartermaster",
    [2] = "Serpent Quartermaster",
    [3] = "Flame Quartermaster",
}

-- ============================================================
-- STATE
-- ============================================================
local total_runs_completed = 0
local total_cycles         = 0
local total_seals_earned   = 0
local total_duckbones      = 0
local script_start_time    = os.time()

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

local function Log(msg)
    LogInfo("[GIL_MISTWAKE] " .. tostring(msg))
end

local function Wait(s)
    yield("/wait " .. tostring(s))
end

local function WaitFor(addon, timeout)
    timeout = timeout or 10
    local t = 0
    while not IsAddonVisible(addon) and t < timeout do
        Wait(0.5)
        t = t + 0.5
    end
    if not IsAddonVisible(addon) then
        Log("WARN: " .. addon .. " not visible after " .. timeout .. "s")
        return false
    end
    while not IsAddonReady(addon) and t < timeout + 5 do
        Wait(0.3)
        t = t + 0.3
    end
    return IsAddonReady(addon)
end

local function CloseAddon(addon)
    if IsAddonVisible(addon) then
        yield("/callback " .. addon .. " true -1")
        Wait(0.8)
    end
end

local function IsInZone(zone_id)
    return GetZoneID() == zone_id
end

local function MoveToCoords(x, y, z, stop_dist)
    stop_dist = stop_dist or CONFIG.nav_stop_dist
    Log(string.format("Pathing to %.1f, %.1f, %.1f", x, y, z))
    PathfindAndMoveTo(x, y, z)
    local timeout = 60
    local elapsed = 0
    while (PathfindInProgress() or PathIsRunning()) and elapsed < timeout do
        if GetDistanceToPoint(x, y, z) <= stop_dist then
            PathStop()
            break
        end
        Wait(0.5)
        elapsed = elapsed + 0.5
    end
    PathStop()
    Wait(1)
end

local function TeleportTo(name, zone_id)
    if IsInZone(zone_id) then return true end
    Log("Teleporting to " .. name)
    yield("/tp " .. name)
    Wait(2)
    local t = 0
    while not IsInZone(zone_id) and t < 30 do
        Wait(1)
        t = t + 1
    end
    if not IsInZone(zone_id) then
        Log("ERROR: Teleport to " .. name .. " failed")
        return false
    end
    Wait(2)
    return true
end

local function GetCurrentSeals()
    return GetGrandCompanySeals() or 0
end

local function FormatTime(secs)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function PrintStats()
    local elapsed = os.time() - script_start_time
    Log("════════════════════════════════════")
    Log(string.format("  Cycles completed : %d", total_cycles))
    Log(string.format("  Total runs       : %d", total_runs_completed))
    Log(string.format("  Seals earned     : %d", total_seals_earned))
    Log(string.format("  Duckbones bought : %d", total_duckbones))
    Log(string.format("  Current seals    : %d", GetCurrentSeals()))
    Log(string.format("  Runtime          : %s", FormatTime(elapsed)))
    Log("════════════════════════════════════")
end

-- ============================================================
-- INVENTORY UTILITIES
-- ============================================================

local INVENTORY_BAGS = {0, 1, 2, 3}

local function SnapshotInventory()
    local snapshot = {}
    for _, bag in ipairs(INVENTORY_BAGS) do
        for slot = 0, 34 do
            local item = GetInventoryItem(bag, slot)
            if item and item.ItemId and item.ItemId ~= 0 then
                local id = item.ItemId
                snapshot[id] = (snapshot[id] or 0) + (item.Count or 1)
            end
        end
    end
    return snapshot
end

local function LogNewDrops(before, after)
    local any = false
    for id, count in pairs(after) do
        local gained = count - (before[id] or 0)
        if gained > 0 then
            local name = ITEM_LIST[id] or ("ItemID " .. id)
            Log(string.format("  DROP: %s x%d (ID: %d)", name, gained, id))
            any = true
        end
    end
    if not any then
        Log("  No new items detected in inventory this run.")
    end
end

local function ShouldTurnIn(item_id)
    local in_list = ITEM_LIST[item_id] ~= nil

    if LIST_MODE == "whitelist" then
        if in_list then
            Log(string.format("  [WHITELIST] Turning in item %d (%s)",
                item_id, ITEM_LIST[item_id]))
            return true
        else
            return false
        end
    elseif LIST_MODE == "blacklist" then
        if in_list then
            Log(string.format("  [BLACKLIST] Skipping protected item %d (%s)",
                item_id, ITEM_LIST[item_id]))
            return false
        else
            return true
        end
    end
    return true
end

local function GetDeliverableItems()
    local deliverable = {}
    for _, bag in ipairs(INVENTORY_BAGS) do
        for slot = 0, 34 do
            local item = GetInventoryItem(bag, slot)
            if item and item.ItemId and item.ItemId ~= 0 then
                if ShouldTurnIn(item.ItemId) then
                    table.insert(deliverable, {
                        id   = item.ItemId,
                        name = ITEM_LIST[item.ItemId] or ("ItemID " .. item.ItemId),
                        bag  = bag,
                        slot = slot,
                    })
                end
            end
        end
    end
    return deliverable
end

-- ============================================================
-- PHASE 1 — AUTODUTY DUNGEON RUNS
-- ============================================================

local function WaitForDutyComplete(timeout)
    Log("Waiting for duty to complete (timeout " .. timeout .. "s)...")
    local elapsed = 0
    Wait(15)
    while elapsed < timeout do
        if not GetCharacterCondition(34) then
            Log("Duty complete — run finished")
            return true
        end
        Wait(5)
        elapsed = elapsed + 5
        if elapsed % 60 == 0 then
            Log(string.format("  Still in duty... (%ds elapsed)", elapsed))
        end
    end
    Log("ERROR: Duty timeout reached (" .. timeout .. "s)")
    return false
end

local function RunDungeonCycle(num_runs)
    Log(string.format("=== DUNGEON PHASE: %d runs of Mistwake ===", num_runs))

    for run = 1, num_runs do
        Log(string.format("--- Run %d/%d (total: %d) ---",
            run, num_runs, total_runs_completed + 1))

        -- Wait if somehow already in a duty
        if GetCharacterCondition(34) then
            Log("WARN: Already in duty — waiting to clear...")
            local t = 0
            while GetCharacterCondition(34) and t < 600 do
                Wait(5) ; t = t + 5
            end
        end

        -- Snapshot inventory before run
        local snap_before = SnapshotInventory()

        -- Queue Mistwake via AutoDuty
        Log("Queuing Mistwake (content ID " .. CONFIG.autoduty_content_id .. ")")
        yield("/autoduty start " .. CONFIG.autoduty_content_id)
        Wait(5)

        -- Wait for duty to load
        local queue_timeout = 300
        local qt = 0
        while not GetCharacterCondition(34) and qt < queue_timeout do
            Wait(5) ; qt = qt + 5
        end
        if not GetCharacterCondition(34) then
            Log("ERROR: Never entered duty — skipping run")
            goto next_run
        end

        -- Wait for run to finish
        local ok = WaitForDutyComplete(CONFIG.duty_timeout)
        if not ok then
            Log("ERROR: Duty timed out — leaving")
            yield("/dutyleave")
            Wait(10)
        end

        -- Log what dropped
        Log("--- Loot this run ---")
        LogNewDrops(snap_before, SnapshotInventory())

        total_runs_completed = total_runs_completed + 1
        Log(string.format("Run %d complete | Total: %d | Seals: %d",
            run, total_runs_completed, GetCurrentSeals()))

        Wait(5)
        ::next_run::
    end

    Log(string.format("=== Dungeon phase done. %d total runs ===",
        total_runs_completed))
end

-- ============================================================
-- PHASE 2 — EXPERT DELIVERY
-- ============================================================

local function DoExpertDelivery()
    Log("=== EXPERT DELIVERY PHASE ===")
    Log(string.format("Mode: %s | List size: %d",
        LIST_MODE:upper(), (function()
            local n = 0
            for _ in pairs(ITEM_LIST) do n = n + 1 end
            return n
        end)()))

    local deliverable = GetDeliverableItems()
    if #deliverable == 0 then
        Log("No deliverable items found — skipping delivery phase")
        return
    end

    Log(string.format("Found %d item(s) eligible for delivery:", #deliverable))
    for _, item in ipairs(deliverable) do
        Log(string.format("  → %s (ID: %d)", item.name, item.id))
    end

    MoveToCoords(CONFIG.gc_officer_x, CONFIG.gc_officer_y, CONFIG.gc_officer_z)

    local npc = GC_OFFICER_NAMES[CONFIG.grand_company]
    yield("/target " .. npc)
    Wait(1)
    yield("/interact")
    Wait(CONFIG.interact_delay)

    if not WaitFor("SelectString", 10) then
        Log("ERROR: Personnel Officer menu did not open")
        return
    end

    yield("/callback SelectString true 1")   -- Expert Delivery
    Wait(CONFIG.interact_delay)

    if not WaitFor("GrandCompanySupplyList", 10) then
        Log("ERROR: Expert Delivery window did not open")
        CloseAddon("SelectString")
        return
    end

    Log("Expert Delivery window open. Processing items...")

    local items_turned_in = 0
    local items_skipped   = 0
    local seal_before     = GetCurrentSeals()
    local max_attempts    = 60
    local attempt         = 0
    local current_row     = 0
    local total_rows      = #deliverable

    while attempt < max_attempts do
        attempt = attempt + 1

        if not IsAddonVisible("GrandCompanySupplyList") then
            Log("Delivery window closed")
            break
        end

        if GetCurrentSeals() >= CONFIG.seal_cap - 100 then
            Log(string.format("Seals at cap (%d) — stopping delivery", GetCurrentSeals()))
            break
        end

        if current_row >= total_rows then
            Log("Reached end of item list")
            break
        end

        local item = deliverable[current_row + 1]
        if item == nil then break end

        if not ShouldTurnIn(item.id) then
            Log(string.format("Skipping row %d: %s", current_row, item.name))
            current_row = current_row + 1
            items_skipped = items_skipped + 1
        else
            yield("/callback GrandCompanySupplyList true 0 " .. current_row)
            Wait(CONFIG.interact_delay)

            if IsAddonVisible("SelectYesno") then
                yield("/callback SelectYesno true 0")
                Wait(CONFIG.interact_delay)
                items_turned_in = items_turned_in + 1
                Log(string.format("Delivered: %s | Seals now: %d",
                    item.name, GetCurrentSeals()))
                -- Rescan after each delivery since list shifts
                deliverable = GetDeliverableItems()
                current_row = items_skipped
                total_rows  = #deliverable + items_skipped
            else
                Log(string.format("WARN: No confirm for row %d — advancing", current_row))
                current_row = current_row + 1
            end
        end
    end

    CloseAddon("GrandCompanySupplyList")
    Wait(1)
    CloseAddon("SelectString")
    Wait(0.5)

    local seals_gained = GetCurrentSeals() - seal_before
    total_seals_earned = total_seals_earned + math.max(0, seals_gained)

    Log(string.format(
        "Delivery complete: %d turned in | %d skipped | +%d seals | Seals now: %d",
        items_turned_in, items_skipped, seals_gained, GetCurrentSeals()))
end

-- ============================================================
-- PHASE 3 — BUY DUCKBONES
-- ============================================================

local function BuyDuckbones()
    Log("=== BUY DUCKBONES PHASE ===")

    local seals_before = GetCurrentSeals()
    if seals_before <= CONFIG.seal_reserve then
        Log(string.format("Not enough seals (%d <= reserve %d) — skipping",
            seals_before, CONFIG.seal_reserve))
        return
    end

    MoveToCoords(CONFIG.gc_shop_x, CONFIG.gc_shop_y, CONFIG.gc_shop_z)

    local shop_npc = GC_SHOP_NAMES[CONFIG.grand_company]
    yield("/target " .. shop_npc)
    Wait(1)
    yield("/interact")
    Wait(CONFIG.interact_delay)

    if WaitFor("SelectString", 8) then
        yield("/callback SelectString true 0")   -- "Purchase Items"
        Wait(CONFIG.interact_delay)
    end

    if not WaitFor("GCShop", 10) then
        Log("ERROR: GC Shop window did not open")
        CloseAddon("SelectString")
        return
    end

    Log("GC Shop open. Buying Duckbones...")

    yield("/callback GCShop true 0")
    Wait(1)

    local bought = 0

    while true do
        local cur_seals = GetCurrentSeals()
        if cur_seals - CONFIG.buy_item_seal_cost < CONFIG.seal_reserve then
            Log(string.format("Seals too low for another purchase (%d) — done", cur_seals))
            break
        end

        yield("/callback GCShop true 0 " .. CONFIG.buy_item_shop_index)
        Wait(CONFIG.interact_delay)

        if IsAddonVisible("ShopExchangeDialog") then
            local max_qty = math.floor(
                (cur_seals - CONFIG.seal_reserve) / CONFIG.buy_item_seal_cost
            )
            max_qty = math.max(1, math.min(max_qty, 99))
            yield("/callback ShopExchangeDialog true 0 " .. max_qty .. " 0")
            Wait(CONFIG.interact_delay)
            bought = bought + max_qty
            Log(string.format("Bought %d %s | Seals remaining: %d",
                max_qty, CONFIG.buy_item_name, GetCurrentSeals()))
            if GetCurrentSeals() - CONFIG.buy_item_seal_cost < CONFIG.seal_reserve then
                break
            end
        elseif IsAddonVisible("SelectYesno") then
            yield("/callback SelectYesno true 0")
            Wait(CONFIG.interact_delay)
            bought = bought + 1
        elseif IsAddonVisible("GCShop") then
            Log("WARN: Buy dialog did not appear. Check buy_item_shop_index in CONFIG.")
            break
        else
            Log("WARN: GCShop closed unexpectedly")
            break
        end
    end

    CloseAddon("GCShop")
    Wait(0.5)
    CloseAddon("SelectString")

    total_duckbones = total_duckbones + bought
    Log(string.format("Bought %d %s this cycle | Total: %d | Seals: %d",
        bought, CONFIG.buy_item_name, total_duckbones, GetCurrentSeals()))
end

-- ============================================================
-- MAIN LOOP
-- ============================================================

Log("╔══════════════════════════════════════╗")
Log("║   Mistwake Gil Farming Script v1.1   ║")
Log("╚══════════════════════════════════════╝")
Log(string.format("Config: %d runs/cycle | GC: %d | Mode: %s | Seal cap: %d",
    CONFIG.runs_per_cycle, CONFIG.grand_company,
    LIST_MODE:upper(), CONFIG.seal_cap))
Log("Script will loop until manually stopped.")
Log("")

if not HasPlugin("AutoDuty") then
    Log("FATAL: AutoDuty plugin not found!")
    return
end
if not HasPlugin("vnavmesh") then
    Log("FATAL: vnavmesh not found!")
    return
end

while true do
    total_cycles = total_cycles + 1
    Log(string.format("════ CYCLE %d START ════", total_cycles))

    local ok, err = pcall(RunDungeonCycle, CONFIG.runs_per_cycle)
    if not ok then
        Log("ERROR in dungeon phase: " .. tostring(err))
        if GetCharacterCondition(34) then
            yield("/dutyleave")
            Wait(15)
        end
    end

    local tp_ok = TeleportTo(CONFIG.gc_tp_name, CONFIG.gc_zone_id)
    if not tp_ok then
        Log("ERROR: Could not reach GC — retrying next cycle...")
        Wait(10)
        goto cycle_end
    end

    Wait(3)

    local del_ok, del_err = pcall(DoExpertDelivery)
    if not del_ok then
        Log("ERROR in delivery phase: " .. tostring(del_err))
    end

    local buy_ok, buy_err = pcall(BuyDuckbones)
    if not buy_ok then
        Log("ERROR in buy phase: " .. tostring(buy_err))
    end

    ::cycle_end::
    PrintStats()
    Log(string.format("════ CYCLE %d END ════", total_cycles))
    Wait(5)
end