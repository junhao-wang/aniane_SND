--[[SND Metadata]]
author: Aniane
version: 1.1.0
description: Re-enter the Occult Crescent when you're booted, and spend your silver coins!
Caveat: THIS ONLY WORKS WITH RSR!! You will need to disable the following options under Auto -> AutoSwitch:
  -> Auto turn off when dead in PvE
  -> Auto turn off RSR when combat is over for more than:

Auto turn off in PvE being off means you will get right back to it when you're raised. YMMV with raisers in the area,
so you may de-level closer to the end of your instance timer. Don't worry. You'll re-level quickly on re-entry.
plugin_dependencies: vnavmesh, RotationSolver, BOCCHI
--[[End Metadata]]

--User Configurable Options
local spendSilver = true -- Set to false if you want to disable spending currency automatically
local selfRepair = true -- Set to false if you want to disable self-repairing automatically
local durabilityAmount = 5 --Durability to repair at
local ShouldAutoBuyDarkMatter = true -- Set to false if you want to disable auto-buying Dark Matter when self-repairing

--[[
    DO NOT TOUCH ANYTHING BELOW THIS UNLESS YOU KNOW WHAT YOU'RE DOING.
    THIS IS A SCRIPT FOR THE OCCULT CRESCENT AND IS NOT MEANT TO BE MODIFIED UNLESS YOU ARE FAMILIAR WITH LUA AND THE SND API.
    IF YOU DO NOT UNDERSTAND THE IMPLICATIONS OF CHANGING THESE VALUES, DO NOT MODIFY THEM.
  ]]

-- Imports
import("System.Numerics")

-- Constants
local OCCULT_CRESCENT = 1252
local PHANTOM_VILLAGE = 1278
local INSTANCE_ENTRY_NPC = "Jeffroy"
local ENTRY_NPC_POS = Vector3(-77.958374, 5, 15.396423)
local REENTER_DELAY = 10
local SILVER_DUMP_LIMIT = 9500

--Currency variables
local silverCount = Inventory.GetItemCount(45043)

-- Shop Config
local VENDOR_NAME = "Expedition Antiquarian"
local VENDOR_POS = Vector3(833.83, 72.73, -719.51)
local BaseAetheryte = Vector3(830.75, 72.98, -695.98)
local ShopItems = {
    { itemName = "Aetherspun Silver", menuIndex = 1, itemIndex = 5, price = 1200 },
}

--Repair module variables
local MENDER_NAME = "Expedition Supplier"
local MENDER_POS = Vector3(821.47, 72.73, -669.12)

-- Character Conditions
CharacterCondition = {
    dead = 2,
    mounted = 4,
    inCombat = 26,
    casting = 27,
    occupiedInEvent = 31,
    occupiedInQuestEvent = 32,
    occupied = 33,
    boundByDuty34 = 34,
    occupiedMateriaExtractionAndRepair = 39,
    betweenAreas = 45,
    jumping48 = 48,
    jumping61 = 61,
    occupiedSummoningBell = 50,
    betweenAreasForDuty = 51,
    boundByDuty56 = 56,
    mounting57 = 57,
    mounting64 = 64,
    beingMoved = 70,
    flying = 77
}

-- State Machine
local State = nil
local CharacterState = {}

-- Helper Functions
local function Sleep(seconds)
    yield('/wait ' .. tostring(seconds))
end

local function WaitForAddon(addonName, timeout)
    local elapsed = 0
    while (not Addons.GetAddon(addonName) or not Addons.GetAddon(addonName).Ready) and elapsed < timeout do
        Sleep(0.5)
        elapsed = elapsed + 0.5
    end
    return Addons.GetAddon(addonName) and Addons.GetAddon(addonName).Ready
end

local function TurnOnOCH()
    Dalamud.LogDebug("[OCM] Turning on OCH...")
    if not IllegalMode then
        IllegalMode = true
        yield("/ochillegal on")
        yield("/rsr manual")
    end
end

local function TurnOffOCH()
    --Dalamud.LogDebug("[OCM] Turning off OCH...")
    if IllegalMode then
        IllegalMode = false
        Dalamud.LogDebug("[OCM] Turning off BOCCHI Illegal Mode.")
        yield("/ochillegal off")
        Sleep(0.5)
        Dalamud.LogDebug("[OCM] Turning off RSR.")
        yield("/rsr off")
    end
    if IPC.vnavmesh.PathfindInProgress() or IPC.vnavmesh.IsRunning() then
        Dalamud.LogDebug("[OCM] Stopping pathfinding...")
        yield("/vnav stop")
    end
    if IPC.Lifestream.IsBusy() then
        Dalamud.LogDebug("[OCM] Stopping Lifestream...")
        yield("/li stop")
    end
end

local function ReturnToBase()
    yield("/gaction Return")
    repeat
        Sleep(1)
    until not Svc.Condition[CharacterCondition.casting]
    repeat
        Sleep(1)
    until not Svc.Condition[CharacterCondition.betweenAreas]
end

function OnStop()
    Dalamud.LogDebug("[OCM] Stopping OCH Silver script...")
    TurnOffOCH()
    Dalamud.LogDebug("[OCM] Setting state to nil...")
    State = nil
    yield("/echo [OCM] Script stopped.")
end

-- State Implementations
IllegalMode = false
function CharacterState.ready()
    --Dalamud.LogDebug("[OCM] Checking conditions for state change...")
    while Svc.Condition[CharacterCondition.betweenAreas] do
        Sleep(0.1)
    end

    local inInstance = Svc.Condition[CharacterCondition.boundByDuty34] and Svc.ClientState.TerritoryType == OCCULT_CRESCENT
    local silverCount = Inventory.GetItemCount(45043)
    local itemsToRepair = Inventory.GetItemsInNeedOfRepairs(durabilityAmount)
    local needsRepair = false
    if type(itemsToRepair) == "number" then
        needsRepair = itemsToRepair ~= 0
    elseif type(itemsToRepair) == "table" then
        needsRepair = next(itemsToRepair) ~= nil
    end

    if not inInstance and Svc.ClientState.TerritoryType ~= PHANTOM_VILLAGE then
        State = CharacterState.zoneIn
        Dalamud.LogDebug("[OCM] State changed to zoneIn")
    elseif not inInstance and Svc.ClientState.TerritoryType == PHANTOM_VILLAGE then
        State = CharacterState.reenterInstance
        Dalamud.LogDebug("[OCM] State changed to reenterInstance")
    elseif needsRepair then
        Dalamud.LogDebug("[OCM] State changed to repair")
        State = CharacterState.repair
    elseif spendSilver and silverCount >= SILVER_DUMP_LIMIT then
        Dalamud.LogDebug("[OCM] State changed to dumpSilver")
        State = CharacterState.dumpSilver
    elseif not IllegalMode then
        Dalamud.LogDebug("[OCM] State changed to ready")
        TurnOnOCH()
    end
end

function CharacterState.zoneIn()
    local instanceEntryAddon = Addons.GetAddon("ContentsFinderConfirm")
    local SelectString = Addons.GetAddon("SelectString")
    local Talked = false
    if Svc.Condition[CharacterCondition.betweenAreas] then
        Sleep(3)
    elseif Svc.ClientState.TerritoryType == PHANTOM_VILLAGE then
        LogInfo("[OCM] Already in Phantom Village")
        if Vector3.Distance(Entity.Player.Position, ENTRY_NPC_POS) >= 7 then
            IPC.vnavmesh.PathfindAndMoveTo(ENTRY_NPC_POS, false)
        elseif IPC.vnavmesh.PathfindInProgress() or IPC.vnavmesh.PathIsRunning() then
            yield("/vnav stop")
        elseif Entity.GetEntityByName(INSTANCE_ENTRY_NPC) ~= INSTANCE_ENTRY_NPC then
            yield("/target " .. INSTANCE_ENTRY_NPC)
        elseif instanceEntryAddon and instanceEntryAddon.ready then
            yield("/callback ContentsFinderConfirm true 8")
            yield("/echo [OCM] Re-entry confirmed.")
        elseif SelectString and SelectString.ready then
            yield("/callback SelectString true 0")
        elseif not Talked then
            Talked = true
            yield("/interact")
        end
    elseif Svc.ClientState.TerritoryType ~=OCCULT_CRESCENT then
        yield("/li occult")
        repeat
            Sleep(1)
        until not IPC.Lifestream.IsBusy()
    elseif Svc.ClientState.TerritoryType == OCCULT_CRESCENT then
        if Player.Available then
            Talked = false
            TurnOnOCH()
        end
    end
    State = CharacterState.ready
end

function CharacterState.reenterInstance()
    local instanceEntryAddon = Addons.GetAddon("ContentsFinderConfirm")
    yield("/echo [OCM] Detected exit from duty. Waiting " .. REENTER_DELAY .. " seconds before re-entry...")
    IllegalMode = false
    Sleep(REENTER_DELAY)

    local npc = Entity.GetEntityByName(INSTANCE_ENTRY_NPC)
    if not npc then
        yield("/echo [OCM] Could not find " .. INSTANCE_ENTRY_NPC .. ". Retrying in 10 seconds...")
        Sleep(10)
        return
    end

    yield("/target " .. INSTANCE_ENTRY_NPC)
    Sleep(1)
    yield("/interact")
    Sleep(1)

    if WaitForAddon("SelectString", 5) then
        Sleep(0.5)
        yield("/callback SelectString true 0")
        Sleep(0.5)
        yield("/callback SelectString true 0")
        Sleep(0.5)

        while not (instanceEntryAddon and instanceEntryAddon.Ready) do
            Sleep(2)
        end

        if instanceEntryAddon and instanceEntryAddon.Ready then
            yield("/callback ContentsFinderConfirm true 8")
            yield("/echo [OCM] Re-entry confirmed.")
        end

        while not Svc.Condition[CharacterCondition.boundByDuty34] do
            Sleep(1)
        end

        yield("/echo [OCM] Instance loaded.")

        Sleep(2.5) --safety sleep on re-entry
        State = CharacterState.ready
    else
        yield("/echo [OCM] Dialog options did not appear.")
        Sleep(5)
    end
end

function CharacterState.dumpSilver()
    local silverCount = Inventory.GetItemCount(45043)
    if silverCount < SILVER_DUMP_LIMIT then
        yield("/echo [OCM] Silver below threshold, returning to ready state.")
        State = CharacterState.ready
        return
    end

    TurnOffOCH()

    local shopAddon = Addons.GetAddon("ShopExchangeCurrency")
    local yesnoAddon = Addons.GetAddon("SelectYesno")
    local iconStringAddon = Addons.GetAddon("SelectIconString")
    local selectStringAddon = Addons.GetAddon("SelectString")
    local baseToShop = Vector3.Distance(BaseAetheryte, VENDOR_POS) + 50
    local distanceToShop = Vector3.Distance(Entity.Player.Position, VENDOR_POS)

    if distanceToShop > baseToShop then
        ReturnToBase()
    elseif distanceToShop > 7 then
        yield("/target " .. VENDOR_NAME)
        if not IPC.vnavmesh.PathfindInProgress() and not IPC.vnavmesh.IsRunning() then
            IPC.vnavmesh.PathfindAndMoveTo(VENDOR_POS, false)
        end
    end

    --Buy Aetherspun Silver
    if yesnoAddon and yesnoAddon.Ready then
        yield("/callback SelectYesno true 0")

        --Wait for the shopAddon to be ready
        while not shopAddon and shopAddon.Ready do
            Sleep(1)
        end

        while shopAddon and shopAddon.Ready do
            yield("/echo [OCM] Buying complete.")
            yield("/callback ShopExchangeCurrency true -1")
            State = CharacterState.ready
            return
        end
        State = CharacterState.ready
        return
    elseif shopAddon and shopAddon.Ready then
        while silverCount < SILVER_DUMP_LIMIT do
            yield("/echo [OCM] Silver below threshold, returning to ready state.")
            yield("/callback ShopExchangeCurrency true -1")
            State = CharacterState.ready
            return
        end
        local qty = math.floor(silverCount / ShopItems[1].price)
        yield("/echo [OCM] Purchasing " .. qty .. " " .. ShopItems[1].itemName)
        yield("/callback ShopExchangeCurrency true 0 " .. ShopItems[1].itemIndex .. " " .. qty .. " 0")
        State = CharacterState.ready
        return
    elseif iconStringAddon and iconStringAddon.Ready then
        yield("/callback SelectIconString true " .. ShopItems[1].menuIndex)
        State = CharacterState.ready
        return
    end

    yield("/interact")
    Sleep(1)

    State = CharacterState.ready
end

function CharacterState.repair()
    local repairAddon = Addons.GetAddon("Repair")
    local yesnoAddon = Addons.GetAddon("SelectYesno")
    local shopAddon = Addons.GetAddon("Shop")
    local DarkMatterItemId = 33916
    local itemsToRepair = Inventory.GetItemsInNeedOfRepairs(durabilityAmount)

    --Turn off OCH before repairing
    Dalamud.LogDebug("[OCM] Repairing items...")

    TurnOffOCH()

    -- if occupied by repair, then just wait
    if Svc.Condition[CharacterCondition.occupiedMateriaExtractionAndRepair] then
        Dalamud.LogDebug("[OCM] Repairing...")
        Sleep(1)
        return
    end

    if yesnoAddon and yesnoAddon.Ready then
        yield("/callback SelectYesno true 0")
        return
    end

        if repairAddon and repairAddon.Ready then
        Dalamud.LogDebug("[OCM] Checking if repairs are needed...")
        local itemsToRepair = Inventory.GetItemsInNeedOfRepairs(durabilityAmount)
        local needsRepair = false
        if type(itemsToRepair) == "number" then
            needsRepair = itemsToRepair ~= 0
        elseif type(itemsToRepair) == "table" then
            needsRepair = next(itemsToRepair) ~= nil
        end
    
        if not needsRepair then
            yield("/callback Repair true -1") -- if you don't need repair anymore, close the menu
        else
            yield("/callback Repair true 0") -- select repair
        end
        return
    end

    if selfRepair then
        Dalamud.LogDebug("[OCM] Checking for Dark Matter...")
        if Inventory.GetItemCount(DarkMatterItemId) > 0 then
            Dalamud.LogDebug("[OCM] Dark Matter in inventory...")
            if shopAddon and shopAddon.Ready then
                yield("/callback Shop true -1")
                return
            end

            if (type(itemsToRepair) == "number" and itemsToRepair ~= 0) or (type(itemsToRepair) == "table" and next(itemsToRepair) ~= nil) then
                Dalamud.LogDebug("[OCM] Items in need of repair...")
                while not repairAddon.Ready do
                    Dalamud.LogDebug("[OCM] Opening repair menu...")
                    Actions.ExecuteGeneralAction(6)
                repeat
                    Sleep(0.1)
                    Dalamud.LogDebug("[OCM] Waiting for repair addon to be ready...")
                until repairAddon.Ready
                end
                State = CharacterState.ready
                Dalamud.LogDebug("[OCM] State Change: Ready")
            else
                State = CharacterState.ready
                Dalamud.LogDebug("[OCM] State Change: Ready")
            end
        elseif ShouldAutoBuyDarkMatter then
            local baseToMender = Vector3.Distance(BaseAetheryte, MENDER_POS) + 50
            local distanceToMender = Vector3.Distance(Entity.Player.Position, MENDER_POS)
            if distanceToMender > baseToMender then
                ReturnToBase()
                return
            elseif distanceToMender > 7 then
                yield("/target " .. MENDER_NAME)
                if not IPC.vnavmesh.PathfindInProgress() and not IPC.vnavmesh.IsRunning() then
                    IPC.vnavmesh.PathfindAndMoveTo(MENDER_POS, false)
                end
            else
                if not Svc.Condition[CharacterCondition.occupiedInQuestEvent] then
                    yield("/interact")
                elseif Addons.GetAddon("SelectIconString") then
                    yield("/callback SelectIconString true 0")
                elseif Addons.GetAddon("SelectYesno") then
                    yield("/callback SelectYesno true 0")
                elseif Addons.GetAddon("Shop") then
                    yield("/callback Shop true 0 10 99")
                end
            end
        else
            yield("/echo Out of Dark Matter and ShouldAutoBuyDarkMatter is false. Switching to mender.")
            SelfRepair = false
        end
    else
        if (type(itemsToRepair) == "number" and itemsToRepair ~= 0) or (type(itemsToRepair) == "table" and next(itemsToRepair) ~= nil) then
            local baseToMender = Vector3.Distance(BaseAetheryte, MENDER_POS) + 50
            local distanceToMender = Vector3.Distance(Entity.Player.Position, MENDER_POS)
            if distanceToMender > baseToMender then
                ReturnToBase()
                return
            elseif distanceToMender > 7 then
                if not IPC.vnavmesh.PathfindInProgress() and not IPC.vnavmesh.IsRunning() then
                    IPC.vnavmesh.PathfindAndMoveTo(MENDER_POS, false)
                end
            elseif Addons.GetAddon("SelectIconString") then
                yield("/callback SelectIconString true 1")
            else
                yield("/target "..MENDER_NAME)
                if not Svc.Condition[CharacterCondition.occupiedInQuestEvent] then
                    yield("/interact")
                end
            end
        else
            State = CharacterState.ready
            Dalamud.LogDebug("[OCM] State Change: Ready")
        end
    end
end

-- Startup
State = CharacterState.ready

-- Main loop
while true do
    while Svc.Condition[CharacterCondition.betweenAreas] do
        Sleep(1)
    end
    State()
    Sleep(1)
end
